"""
AWS Lambda handler for acido secrets sharing service.

This module provides a OneTimeSecret-like service where secrets can be:
- Created with a generated UUID
- Retrieved and deleted (one-time access)

The service uses Azure KeyVault for secure secret storage.
Optional CloudFlare Turnstile support for bot protection.
"""

import os
import uuid
import traceback
from datetime import datetime, timezone
from acido.azure_utils.VaultManager import VaultManager
from acido.utils.lambda_utils import (
    parse_lambda_event,
    build_response,
    build_error_response,
    extract_http_method,
    extract_remote_ip
)
from acido.utils.crypto_utils import encrypt_secret, decrypt_secret, is_encrypted
from acido.utils.turnstile_utils import validate_turnstile


def _encrypt_with_secret_key(data: str) -> str:
    """
    Encrypt data using the SECRET_KEY environment variable.
    This provides an additional layer of system-level encryption.
    
    Args:
        data: The data to encrypt
        
    Returns:
        Encrypted data as string
    """
    secret_key = os.environ.get('SECRET_KEY')
    if not secret_key:
        raise ValueError('SECRET_KEY environment variable not set')
    return encrypt_secret(data, secret_key)


def _decrypt_with_secret_key(data: str) -> str:
    """
    Decrypt data using the SECRET_KEY environment variable.
    This removes the system-level encryption layer.
    
    Args:
        data: The encrypted data
        
    Returns:
        Decrypted data as string
    """
    secret_key = os.environ.get('SECRET_KEY')
    if not secret_key:
        raise ValueError('SECRET_KEY environment variable not set')
    return decrypt_secret(data, secret_key)


# CORS headers - origin is configurable via CORS_ORIGIN environment variable
CORS_HEADERS = {
    "Access-Control-Allow-Origin": os.environ.get("CORS_ORIGIN", "https://secrets.merabytes.com"),
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Content-Type": "application/json"
}


def _get_version():
    """Read version from VERSION file."""
    try:
        version_file = os.path.join(os.path.dirname(__file__), 'VERSION')
        with open(version_file, 'r') as f:
            return f.read().strip()
    except Exception:
        return 'unknown'


def _delete_secret_and_metadata(vault_manager, secret_uuid):
    """
    Delete a secret and all its associated metadata.
    
    Args:
        vault_manager: VaultManager instance
        secret_uuid: UUID of the secret to delete
    """
    vault_manager.delete_secret(secret_uuid)
    
    # Delete metadata if it exists
    try:
        vault_manager.delete_secret(f"{secret_uuid}-metadata")
    except Exception:
        pass
    
    # Delete expiration metadata if it exists
    try:
        vault_manager.delete_secret(f"{secret_uuid}-expires")
    except Exception:
        pass


def _check_expiration(vault_manager, secret_uuid):
    """
    Check if a secret has expired. Returns None if not expired or doesn't have expiration.
    
    Args:
        vault_manager: VaultManager instance
        secret_uuid: UUID of the secret to check
        
    Returns:
        dict with error response if expired, None otherwise
    """
    expires_key = f"{secret_uuid}-expires"
    try:
        expires_at_str = vault_manager.get_secret(expires_key)
        expires_at_unix = int(expires_at_str)
        expires_at = datetime.fromtimestamp(expires_at_unix, tz=timezone.utc)
        now = datetime.now(timezone.utc)
        
        if now >= expires_at:
            # Secret has expired - delete it and all metadata
            _delete_secret_and_metadata(vault_manager, secret_uuid)
            return build_response(410, {
                'error': 'Secret has expired and has been deleted',
                'expired_at': expires_at_unix
            }, CORS_HEADERS)
    except Exception:
        # No expiration metadata means secret doesn't expire
        pass
    
    return None


def _validate_expiration_time(expires_at):
    """
    Validate and parse expiration timestamp.
    
    Args:
        expires_at: UNIX timestamp (integer or string)
        
    Returns:
        tuple: (expiration_unix, error_response) - one will be None
    """
    if not expires_at:
        return None, None
    
    try:
        expiration_unix = int(expires_at)
        expiration_datetime = datetime.fromtimestamp(expiration_unix, tz=timezone.utc)
        
        # Ensure the expiration is in the future
        now = datetime.now(timezone.utc)
        if expiration_datetime <= now:
            return None, build_error_response(
                'expires_at must be in the future',
                headers=CORS_HEADERS
            )
        
        return expiration_unix, None
    except (ValueError, TypeError, OSError) as e:
        return None, build_error_response(
            f'Invalid expires_at format. Expected UNIX timestamp (integer): {str(e)}',
            headers=CORS_HEADERS
        )


def _handle_healthcheck():
    """Handle healthcheck action."""
    return build_response(200, {
        'status': 'healthy',
        'message': 'Lambda function is running',
        'version': _get_version()
    }, CORS_HEADERS)


def _encrypt_secret_layers(secret_value, password):
    """
    Apply encryption layers to secret value.
    
    Args:
        secret_value: Plain text secret
        password: Optional user password
        
    Returns:
        tuple: (encrypted_value, encryption_type, error_response)
    """
    encryption_type = "secret_key_encrypted"
    
    # First layer: Optional user password encryption
    if password:
        try:
            secret_value = encrypt_secret(secret_value, password)
            encryption_type = "secret_key_password_encrypted"
        except Exception as e:
            return None, None, build_response(500, {
                'error': f'Password encryption failed: {str(e)}'
            }, CORS_HEADERS)
    
    # Second layer: System-level SECRET_KEY encryption (always applied)
    try:
        secret_value = _encrypt_with_secret_key(secret_value)
    except Exception as e:
        return None, None, build_response(500, {
            'error': f'System encryption failed: {str(e)}'
        }, CORS_HEADERS)
    
    return secret_value, encryption_type, None


def _store_secret_with_metadata(vault_manager, secret_uuid, secret_value, encryption_type, expiration_unix):
    """
    Store secret and its metadata in vault.
    
    Args:
        vault_manager: VaultManager instance
        secret_uuid: UUID for the secret
        secret_value: Encrypted secret value
        encryption_type: Type of encryption applied
        expiration_unix: Optional expiration timestamp
    """
    vault_manager.set_secret(secret_uuid, secret_value)
    vault_manager.set_secret(f"{secret_uuid}-metadata", encryption_type)
    
    if expiration_unix:
        vault_manager.set_secret(f"{secret_uuid}-expires", str(expiration_unix))


def _handle_create_secret(event, vault_manager):
    """Handle secret creation action."""
    secret_value = event.get('secret')
    password = event.get('password')
    expires_at = event.get('expires_at')
    
    if not secret_value:
        return build_error_response('Missing required field: secret', headers=CORS_HEADERS)
    
    # Validate expiration time
    expiration_unix, error = _validate_expiration_time(expires_at)
    if error:
        return error
    
    # Generate UUID
    secret_uuid = str(uuid.uuid4())
    
    # Encrypt secret with multi-layer encryption
    encrypted_value, encryption_type, error = _encrypt_secret_layers(secret_value, password)
    if error:
        return error
    
    # Store secret and metadata
    _store_secret_with_metadata(vault_manager, secret_uuid, encrypted_value, encryption_type, expiration_unix)
    
    # Build response
    response_data = {
        'uuid': secret_uuid,
        'message': 'Secret created successfully'
    }
    if expiration_unix:
        response_data['expires_at'] = expiration_unix
    
    return build_response(201, response_data, CORS_HEADERS)


def _get_encryption_metadata(vault_manager, secret_uuid):
    """
    Get encryption metadata for a secret.
    
    Args:
        vault_manager: VaultManager instance
        secret_uuid: UUID of the secret
        
    Returns:
        Encryption type string or None
    """
    try:
        return vault_manager.get_secret(f"{secret_uuid}-metadata")
    except Exception:
        return None


def _decrypt_secret_layers(secret_value, encryption_type, password):
    """
    Decrypt secret based on encryption type.
    
    Args:
        secret_value: Encrypted secret
        encryption_type: Type of encryption applied
        password: Optional user password
        
    Returns:
        tuple: (decrypted_value, error_response)
    """
    # New encryption scheme with SECRET_KEY
    if encryption_type in ["secret_key_encrypted", "secret_key_password_encrypted"]:
        try:
            secret_value = _decrypt_with_secret_key(secret_value)
        except Exception as e:
            return None, build_response(500, {'error': f'System decryption failed: {str(e)}'}, CORS_HEADERS)
        
        # Decrypt with user password if needed
        if encryption_type == "secret_key_password_encrypted":
            if not password:
                return None, build_response(400, {'error': 'Password required for encrypted secret'}, CORS_HEADERS)
            try:
                secret_value = decrypt_secret(secret_value, password)
            except ValueError as e:
                return None, build_response(400, {'error': f'Decryption failed: {str(e)}'}, CORS_HEADERS)
    
    # Legacy encryption scheme
    elif encryption_type == "encrypted":
        if not password:
            return None, build_response(400, {'error': 'Password required for encrypted secret'}, CORS_HEADERS)
        try:
            secret_value = decrypt_secret(secret_value, password)
        except ValueError as e:
            return None, build_response(400, {'error': f'Decryption failed: {str(e)}'}, CORS_HEADERS)
    
    elif encryption_type == "plaintext":
        pass  # No decryption needed
    
    # Unknown metadata - use heuristic
    else:
        if is_encrypted(secret_value):
            if not password:
                return None, build_response(400, {'error': 'Password required for encrypted secret'}, CORS_HEADERS)
            try:
                secret_value = decrypt_secret(secret_value, password)
            except ValueError as e:
                return None, build_response(400, {'error': f'Decryption failed: {str(e)}'}, CORS_HEADERS)
    
    return secret_value, None


def _handle_retrieve_secret(event, vault_manager):
    """Handle secret retrieval and deletion action."""
    secret_uuid = event.get('uuid')
    password = event.get('password')
    
    if not secret_uuid:
        return build_error_response('Missing required field: uuid', headers=CORS_HEADERS)
    
    # Check if secret exists
    if not vault_manager.secret_exists(secret_uuid):
        return build_response(404, {'error': 'Secret not found or already accessed'}, CORS_HEADERS)
    
    # Check expiration
    expiration_error = _check_expiration(vault_manager, secret_uuid)
    if expiration_error:
        return expiration_error
    
    # Get encryption metadata and secret value
    encryption_type = _get_encryption_metadata(vault_manager, secret_uuid)
    secret_value = vault_manager.get_secret(secret_uuid)
    
    # Decrypt secret
    decrypted_value, error = _decrypt_secret_layers(secret_value, encryption_type, password)
    if error:
        return error
    
    # Delete secret and all metadata (one-time access)
    _delete_secret_and_metadata(vault_manager, secret_uuid)
    
    return build_response(200, {
        'secret': decrypted_value,
        'message': 'Secret retrieved and deleted successfully'
    }, CORS_HEADERS)


def _get_expiration_info(vault_manager, secret_uuid):
    """
    Get expiration information for a secret.
    
    Args:
        vault_manager: VaultManager instance
        secret_uuid: UUID of the secret
        
    Returns:
        UNIX timestamp or None
    """
    try:
        expires_at_str = vault_manager.get_secret(f"{secret_uuid}-expires")
        return int(expires_at_str)
    except Exception:
        return None


def _check_password_requirement(vault_manager, secret_uuid):
    """
    Check if secret requires a password for decryption.
    
    Args:
        vault_manager: VaultManager instance
        secret_uuid: UUID of the secret
        
    Returns:
        bool: True if password is required
    """
    metadata_value = _get_encryption_metadata(vault_manager, secret_uuid)
    
    if metadata_value in ["encrypted", "secret_key_password_encrypted"]:
        return True
    elif metadata_value in ["plaintext", "secret_key_encrypted"]:
        return False
    
    # Fallback to heuristic for backward compatibility
    try:
        secret_value = vault_manager.get_secret(secret_uuid)
        return is_encrypted(secret_value)
    except Exception:
        return False


def _handle_check_secret(event, vault_manager):
    """Handle checking if a secret is encrypted without retrieving it."""
    secret_uuid = event.get('uuid')
    
    if not secret_uuid:
        return build_error_response('Missing required field: uuid', headers=CORS_HEADERS)
    
    # Check if secret exists
    if not vault_manager.secret_exists(secret_uuid):
        return build_response(404, {'error': 'Secret not found or already accessed'}, CORS_HEADERS)
    
    # Check expiration
    expiration_error = _check_expiration(vault_manager, secret_uuid)
    if expiration_error:
        return expiration_error
    
    # Get password requirement and expiration info
    requires_password = _check_password_requirement(vault_manager, secret_uuid)
    expires_at_unix = _get_expiration_info(vault_manager, secret_uuid)
    
    # Build response
    response_data = {
        'encrypted': requires_password,
        'requires_password': requires_password
    }
    if expires_at_unix:
        response_data['expires_at'] = expires_at_unix
    
    return build_response(200, response_data, CORS_HEADERS)


def _validate_action(action):
    """
    Validate the action parameter.
    
    Args:
        action: Action string from event
        
    Returns:
        Error response or None if valid
    """
    if not action or action not in ['create', 'retrieve', 'check']:
        return build_error_response(
            'Invalid or missing action. Must be "create", "retrieve", "check", or "healthcheck"',
            headers=CORS_HEADERS
        )
    return None


def _validate_turnstile(event, original_event, context):
    """
    Validate CloudFlare Turnstile token.
    
    Args:
        event: Parsed event
        original_event: Original event
        context: Lambda context
        
    Returns:
        Error response or None if valid
    """
    turnstile_token = event.get('turnstile_token')
    
    if not turnstile_token:
        return build_error_response(
            'Missing required field: turnstile_token (bot protection enabled)',
            headers=CORS_HEADERS
        )
    
    remoteip = extract_remote_ip(original_event, context)
    
    if not validate_turnstile(turnstile_token, remoteip):
        return build_response(403, {'error': 'Invalid or expired Turnstile token'}, CORS_HEADERS)
    
    return None


def lambda_handler(event, context):
    """
    AWS Lambda handler for secrets sharing service.
    
    Expected event format for creating a secret:
    {
        "action": "create",
        "secret": "my-secret-value",
        "password": "optional-password-for-encryption",
        "expires_at": 1735689599,
        "turnstile_token": "cloudflare-turnstile-token"
    }
    
    Expected event format for retrieving/deleting a secret:
    {
        "action": "retrieve",
        "uuid": "generated-uuid-here",
        "password": "password-if-encrypted",
        "turnstile_token": "cloudflare-turnstile-token"
    }
    
    Expected event format for checking if a secret is encrypted:
    {
        "action": "check",
        "uuid": "generated-uuid-here",
        "turnstile_token": "cloudflare-turnstile-token"
    }
    
    Expected event format for healthcheck:
    {
        "action": "healthcheck"
    }
    
    Or with body wrapper (from API Gateway):
    {
        "body": {
            "action": "create",
            "secret": "my-secret-value",
            "password": "optional-password-for-encryption",
            "expires_at": 1735689599,
            "turnstile_token": "cloudflare-turnstile-token"
        }
    }
    
    Environment variables required:
    - KEY_VAULT_NAME: Azure Key Vault name
    - AZURE_TENANT_ID
    - AZURE_CLIENT_ID
    - AZURE_CLIENT_SECRET
    - CF_SECRET_KEY: CloudFlare Turnstile secret key (bot protection is always enabled)
    - SECRET_KEY: Additional encryption key for enhanced security (auto-generated during deployment)
    
    Environment variables optional:
    - CORS_ORIGIN: CORS origin URL (default: https://secrets.merabytes.com)
    
    Multi-layer encryption:
    - All secrets are encrypted with SECRET_KEY (system-level encryption, always applied)
    - If "password" is provided during creation, an additional user-level encryption is applied
    - Decryption happens in reverse order: system-level first, then user password if needed
    - This provides defense-in-depth security with two independent encryption layers
    
    Password-based encryption (user-level):
    - If "password" is provided during creation, the secret will be encrypted with AES-256
    - The same password must be provided during retrieval to decrypt the secret
    - If no password is provided, only system-level SECRET_KEY encryption is used
    
    Time-based expiration:
    - If "expires_at" is provided during creation, the secret will expire at that time
    - Format: UNIX timestamp (seconds since epoch, e.g., 1735689599)
    - Expired secrets are automatically deleted when accessed
    - If no expiration is provided, the secret never expires (backward compatible)
    
    Returns:
        dict: Response with statusCode and body containing operation result
    """
    original_event = event
    event = parse_lambda_event(event)
    
    # Handle OPTIONS preflight
    if extract_http_method(original_event) == "OPTIONS":
        return build_response(200, {"message": "CORS preflight OK"}, CORS_HEADERS)
    
    # Validate event body
    if not event:
        return build_error_response(
            'Missing event body. Expected fields: action, secret (for create), uuid (for retrieve/check)',
            headers=CORS_HEADERS
        )
    
    action = event.get('action')
    
    # Handle healthcheck (no turnstile required)
    if action == 'healthcheck':
        return _handle_healthcheck()
    
    # Validate action
    error = _validate_action(action)
    if error:
        return error
    
    # Validate turnstile token
    error = _validate_turnstile(event, original_event, context)
    if error:
        return error
    
    try:
        vault_manager = VaultManager()
        
        if action == 'create':
            return _handle_create_secret(event, vault_manager)
        elif action == 'retrieve':
            return _handle_retrieve_secret(event, vault_manager)
        elif action == 'check':
            return _handle_check_secret(event, vault_manager)
        
    except Exception as e:
        return build_response(500, {
            'error': str(e),
            'type': type(e).__name__,
            'traceback': traceback.format_exc()
        }, CORS_HEADERS)
