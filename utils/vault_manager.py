"""
Azure Key Vault helper — extracted from merabytes/acido for standalone use.

Credential priority (no azure-mgmt-resource or PyJWT required):
  1. Managed Identity if MANAGED_IDENTITY_CLIENT_ID is set
  2. ClientSecretCredential via AZURE_TENANT_ID / AZURE_CLIENT_ID / AZURE_CLIENT_SECRET
"""

import os
import logging

from azure.identity import ManagedIdentityCredential, ClientSecretCredential
from azure.keyvault.secrets import SecretClient
from azure.core.exceptions import ResourceNotFoundError

logging.getLogger('azure.identity').setLevel(logging.ERROR)


def _get_credential():
    client_id = os.getenv("MANAGED_IDENTITY_CLIENT_ID")
    if client_id:
        return ManagedIdentityCredential(client_id=client_id)

    tenant_id = os.getenv("AZURE_TENANT_ID")
    azure_client_id = os.getenv("AZURE_CLIENT_ID")
    client_secret = os.getenv("AZURE_CLIENT_SECRET")

    missing = [k for k, v in {
        "AZURE_TENANT_ID": tenant_id,
        "AZURE_CLIENT_ID": azure_client_id,
        "AZURE_CLIENT_SECRET": client_secret,
    }.items() if not v]
    if missing:
        raise RuntimeError(
            f"Missing required env vars for Azure credential: {', '.join(missing)}"
        )

    return ClientSecretCredential(
        tenant_id=tenant_id,
        client_id=azure_client_id,
        client_secret=client_secret,
    )


class VaultManager:
    def __init__(self, vault_name=None):
        if not vault_name:
            vault_name = os.getenv("KEY_VAULT_NAME")
        if not vault_name:
            raise RuntimeError("KEY_VAULT_NAME is required (env var or ctor arg).")
        self.vault_name = vault_name
        credential = _get_credential()
        self.client = SecretClient(
            vault_url=f"https://{self.vault_name}.vault.azure.net",
            credential=credential,
        )

    def get_secret(self, secret_name):
        return self.client.get_secret(secret_name).value

    def set_secret(self, secret_name, secret_value):
        return self.client.set_secret(secret_name, secret_value)

    def delete_secret(self, secret_name):
        return self.client.begin_delete_secret(secret_name).result()

    def secret_exists(self, secret_name):
        try:
            self.client.get_secret(secret_name)
            return True
        except ResourceNotFoundError:
            return False

    def __getattr__(self, name):
        return self.get_secret(name)
