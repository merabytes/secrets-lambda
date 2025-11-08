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


def _handle_healthcheck():
    """Handle healthcheck action."""
    return build_response(200, {
        'status': 'healthy',
        'message': 'Lambda function is running',
        'version': _get_version()
    }, CORS_HEADERS)


def _handle_create_secret(event, vault_manager):
    """Handle secret creation action."""
    secret_value = event.get('secret')
    password = event.get('password')
    expires_at = event.get('expires_at')  # Optional expiration timestamp (UNIX timestamp)
    
    if not secret_value:
        return build_error_response(
            'Missing required field: secret',
            headers=CORS_HEADERS
        )
    
    # Validate expires_at if provided
    expiration_datetime = None
    expiration_unix = None
    if expires_at:
        try:
            # Parse UNIX timestamp (integer or string)
            expiration_unix = int(expires_at)
            # OSError can be raised for timestamps outside platform's valid range
            # (typically 1970-2038 on 32-bit systems, much larger on 64-bit systems)
            expiration_datetime = datetime.fromtimestamp(expiration_unix, tz=timezone.utc)
            
            # Ensure the expiration is in the future
            now = datetime.now(timezone.utc)
            if expiration_datetime <= now:
                return build_error_response(
                    'expires_at must be in the future',
                    headers=CORS_HEADERS
                )
        except (ValueError, TypeError, OSError) as e:
            return build_error_response(
                f'Invalid expires_at format. Expected UNIX timestamp (integer): {str(e)}',
                headers=CORS_HEADERS
            )
    
    # Generate UUID for the secret
    secret_uuid = str(uuid.uuid4())
    
    # Track encryption type for metadata
    # Options: "secret_key_encrypted" (system-level only), "secret_key_password_encrypted" (system + user password)
    # Note: "plaintext" and "encrypted" are legacy values for backward compatibility
    encryption_type = "secret_key_encrypted"
    
    # First layer: Optional user password encryption
    if password:
        try:
            secret_value = encrypt_secret(secret_value, password)
            encryption_type = "secret_key_password_encrypted"
        except Exception as e:
            return build_response(500, {
                'error': f'Password encryption failed: {str(e)}'
            }, CORS_HEADERS)
    
    # Second layer: System-level SECRET_KEY encryption (always applied)
    try:
        secret_value = _encrypt_with_secret_key(secret_value)
    except Exception as e:
        return build_response(500, {
            'error': f'System encryption failed: {str(e)}'
        }, CORS_HEADERS)
    
    # Store secret in Key Vault
    vault_manager.set_secret(secret_uuid, secret_value)
    
    # Store encryption metadata as a separate secret
    # Using a naming convention: {uuid}-metadata
    metadata_key = f"{secret_uuid}-metadata"
    vault_manager.set_secret(metadata_key, encryption_type)
    
    # Store expiration metadata if provided
    if expiration_unix:
        expires_key = f"{secret_uuid}-expires"
        # Store as UNIX timestamp string for consistency
        vault_manager.set_secret(expires_key, str(expiration_unix))
    
    # Return success response with UUID
    response_data = {
        'uuid': secret_uuid,
        'message': 'Secret created successfully'
    }
    if expiration_unix:
        response_data['expires_at'] = expiration_unix
    
    return build_response(201, response_data, CORS_HEADERS)


def _handle_retrieve_secret(event, vault_manager):
    """Handle secret retrieval and deletion action."""
    secret_uuid = event.get('uuid')
    password = event.get('password')
    
    if not secret_uuid:
        return build_error_response(
            'Missing required field: uuid',
            headers=CORS_HEADERS
        )
    
    # Check if secret exists
    if not vault_manager.secret_exists(secret_uuid):
        return build_response(404, {
            'error': 'Secret not found or already accessed'
        }, CORS_HEADERS)
    
    # Check if secret has expired
    expires_key = f"{secret_uuid}-expires"
    try:
        expires_at_str = vault_manager.get_secret(expires_key)
        expires_at_unix = int(expires_at_str)
        expires_at = datetime.fromtimestamp(expires_at_unix, tz=timezone.utc)
        now = datetime.now(timezone.utc)
        
        if now >= expires_at:
            # Secret has expired - delete it and all metadata
            vault_manager.delete_secret(secret_uuid)
            try:
                vault_manager.delete_secret(f"{secret_uuid}-metadata")
            except Exception:
                pass
            try:
                vault_manager.delete_secret(expires_key)
            except Exception:
                pass
            
            return build_response(410, {
                'error': 'Secret has expired and has been deleted',
                'expired_at': expires_at_unix
            }, CORS_HEADERS)
    except Exception:
        # No expiration metadata means secret doesn't expire
        pass
    
    # Check metadata to determine encryption type
    metadata_key = f"{secret_uuid}-metadata"
    encryption_type = None
    try:
        encryption_type = vault_manager.get_secret(metadata_key)
    except Exception:
        # If metadata doesn't exist, fall back to heuristic check for backward compatibility
        pass
    
    # Retrieve the secret value
    secret_value = vault_manager.get_secret(secret_uuid)
    
    # Decrypt based on encryption type
    if encryption_type in ["secret_key_encrypted", "secret_key_password_encrypted"]:
        # New encryption scheme: First decrypt with SECRET_KEY (system-level)
        try:
            secret_value = _decrypt_with_secret_key(secret_value)
        except Exception as e:
            return build_response(500, {
                'error': f'System decryption failed: {str(e)}'
            }, CORS_HEADERS)
        
        # Then decrypt with user password if it was password-encrypted
        if encryption_type == "secret_key_password_encrypted":
            if not password:
                # Do NOT delete the secret - allow retry
                return build_response(400, {
                    'error': 'Password required for encrypted secret'
                }, CORS_HEADERS)
            
            try:
                secret_value = decrypt_secret(secret_value, password)
            except ValueError as e:
                # Do NOT delete the secret on wrong password - allow retry
                return build_response(400, {
                    'error': f'Decryption failed: {str(e)}'
                }, CORS_HEADERS)
    
    elif encryption_type == "encrypted":
        # Legacy encryption scheme: Only password encryption (backward compatibility)
        if not password:
            return build_response(400, {
                'error': 'Password required for encrypted secret'
            }, CORS_HEADERS)
        
        try:
            secret_value = decrypt_secret(secret_value, password)
        except ValueError as e:
            return build_response(400, {
                'error': f'Decryption failed: {str(e)}'
            }, CORS_HEADERS)
    
    elif encryption_type == "plaintext":
        # Legacy plaintext scheme: No encryption (backward compatibility)
        pass
    
    else:
        # Unknown or missing metadata - try heuristic check for backward compatibility
        if is_encrypted(secret_value):
            if not password:
                return build_response(400, {
                    'error': 'Password required for encrypted secret'
                }, CORS_HEADERS)
            
            try:
                secret_value = decrypt_secret(secret_value, password)
            except ValueError as e:
                return build_response(400, {
                    'error': f'Decryption failed: {str(e)}'
                }, CORS_HEADERS)
    
    # Delete the secret and all metadata (one-time access)
    vault_manager.delete_secret(secret_uuid)
    try:
        vault_manager.delete_secret(metadata_key)
    except Exception:
        # Metadata might not exist for old secrets
        pass
    try:
        vault_manager.delete_secret(expires_key)
    except Exception:
        # Expiration metadata might not exist
        pass
    
    # Return success response with secret value
    return build_response(200, {
        'secret': secret_value,
        'message': 'Secret retrieved and deleted successfully'
    }, CORS_HEADERS)


def _handle_check_secret(event, vault_manager):
    """Handle checking if a secret is encrypted without retrieving it."""
    secret_uuid = event.get('uuid')
    
    if not secret_uuid:
        return build_error_response(
            'Missing required field: uuid',
            headers=CORS_HEADERS
        )
    
    # Check if secret exists
    if not vault_manager.secret_exists(secret_uuid):
        return build_response(404, {
            'error': 'Secret not found or already accessed'
        }, CORS_HEADERS)
    
    # Check if secret has expired
    expires_key = f"{secret_uuid}-expires"
    expires_at_unix = None
    is_expired = False
    try:
        expires_at_str = vault_manager.get_secret(expires_key)
        expires_at_unix = int(expires_at_str)
        expires_at = datetime.fromtimestamp(expires_at_unix, tz=timezone.utc)
        now = datetime.now(timezone.utc)
        
        if now >= expires_at:
            is_expired = True
            # Secret has expired - delete it and all metadata
            vault_manager.delete_secret(secret_uuid)
            try:
                vault_manager.delete_secret(f"{secret_uuid}-metadata")
            except Exception:
                pass
            try:
                vault_manager.delete_secret(expires_key)
            except Exception:
                pass
            
            return build_response(410, {
                'error': 'Secret has expired and has been deleted',
                'expired_at': expires_at_unix
            }, CORS_HEADERS)
    except Exception:
        # No expiration metadata means secret doesn't expire
        pass
    
    # Check metadata to determine if secret requires a password (bulletproof method)
    metadata_key = f"{secret_uuid}-metadata"
    requires_password = False
    try:
        metadata_value = vault_manager.get_secret(metadata_key)
        # New metadata types: "secret_key_password_encrypted" requires password
        # "secret_key_encrypted" does not require password (system-level only)
        # Legacy: "encrypted" requires password, "plaintext" does not
        if metadata_value in ["encrypted", "secret_key_password_encrypted"]:
            requires_password = True
    except Exception:
        # If metadata doesn't exist, fall back to heuristic check for backward compatibility
        secret_value = vault_manager.get_secret(secret_uuid)
        requires_password = is_encrypted(secret_value)
    
    # Return check result
    response_data = {
        'encrypted': requires_password,  # For backward compatibility with frontends
        'requires_password': requires_password
    }
    if expires_at_unix:
        response_data['expires_at'] = expires_at_unix
    
    return build_response(200, response_data, CORS_HEADERS)


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
    # Parse event first to handle string inputs
    original_event = event
    event = parse_lambda_event(event)
    
    # Handle OPTIONS preflight request
    http_method = extract_http_method(original_event)
    if http_method == "OPTIONS":
        return build_response(200, {"message": "CORS preflight OK"}, CORS_HEADERS)
    
    # Validate required fields
    if not event:
        return build_error_response(
            'Missing event body. Expected fields: action, secret (for create), uuid (for retrieve/check)',
            headers=CORS_HEADERS
        )
    
    action = event.get('action')
    
    # Handle healthcheck action (no turnstile validation required)
    if action == 'healthcheck':
        return _handle_healthcheck()
    
    # Validate action
    if not action or action not in ['create', 'retrieve', 'check']:
        return build_error_response(
            'Invalid or missing action. Must be "create", "retrieve", "check", or "healthcheck"',
            headers=CORS_HEADERS
        )
    
    # Validate CloudFlare Turnstile token (required for create/retrieve/check)
    turnstile_token = event.get('turnstile_token')
    
    if not turnstile_token:
        return build_error_response(
            'Missing required field: turnstile_token (bot protection enabled)',
            headers=CORS_HEADERS
        )
    
    # Extract remote IP and validate turnstile
    remoteip = extract_remote_ip(original_event, context)
    
    if not validate_turnstile(turnstile_token, remoteip):
        return build_response(403, {
            'error': 'Invalid or expired Turnstile token'
        }, CORS_HEADERS)
    
    try:
        # Initialize VaultManager with Azure Key Vault
        vault_manager = VaultManager()
        
        if action == 'create':
            return _handle_create_secret(event, vault_manager)
        elif action == 'retrieve':
            return _handle_retrieve_secret(event, vault_manager)
        elif action == 'check':
            return _handle_check_secret(event, vault_manager)
        
    except Exception as e:
        # Return error response
        error_details = {
            'error': str(e),
            'type': type(e).__name__,
            'traceback': traceback.format_exc()
        }
        return build_response(500, error_details, CORS_HEADERS)
