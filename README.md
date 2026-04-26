# Merabytes Secrets Sharing Service

A OneTimeSecret-like service built on AWS Lambda and Azure KeyVault that allows secure sharing of secrets with one-time access.

## Overview

The Merabytes Secrets Sharing Service provides a simple yet secure way to share sensitive information. Secrets are:
- Stored securely in Azure KeyVault
- Identified by a unique UUID
- Accessible only once (retrieved and immediately deleted)

This implementation follows the OneTimeSecret pattern where secrets self-destruct after being accessed.

## Architecture

```
┌─────────────┐         ┌──────────────────┐         ┌─────────────────┐
│  Frontend   │────────▶│  AWS Lambda      │────────▶│  Azure KeyVault │
│             │         │  (Secrets)       │         │                 │
└─────────────┘         └──────────────────┘         └─────────────────┘
                              │
                              │
                        ┌─────▼──────┐
                        │  Generate  │
                        │    UUID    │
                        └────────────┘
```

## Features

- **Create Secret**: Store a secret and receive a unique UUID
- **Retrieve Secret**: Get the secret once using the UUID (auto-deletes after retrieval)
- **Check Secret**: Check if a secret is encrypted without retrieving it (non-destructive)
- **Multi-layer PQC Encryption**: Two independent encryption layers for enhanced security
  - System-level encryption with SECRET_KEY using ML-KEM-768 + AES-256-GCM (always applied)
  - Optional user-level encryption with password using ML-KEM-768 + AES-256-GCM
- **Password Encryption**: Optional client-side password protection for secrets
- **Time-based Expiration**: Optional expiration time for automatic secret deletion
- **Secure Storage**: All secrets stored in Azure KeyVault with explicit encryption metadata
- **Serverless**: Runs on AWS Lambda with automatic scaling
- **Continuous Deployment**: Automated deployment via GitHub Actions
- **Bot Protection**: Optional CloudFlare Turnstile integration for spam prevention

## How It Works

The API provides three main operations:

1. **Create**: Store a secret (with optional password encryption and/or expiration time) and get a UUID
2. **Check**: Verify if a secret is encrypted and/or has expiration before attempting to retrieve it
3. **Retrieve**: Get the secret once (with password if encrypted) and auto-delete

### Encryption Metadata

When creating a secret, the service stores up to three items in Azure KeyVault:
- `{uuid}` - The actual secret value (always encrypted with SECRET_KEY, plus optional password encryption)
- `{uuid}-metadata` - Encryption type marker:
  - `secret_key_encrypted` - System-level PQC encryption only (no password required)
  - `secret_key_password_encrypted` - Both system-level and user password PQC encryption
- `{uuid}-expires` - (Optional) UNIX timestamp expiration

**Multi-layer Encryption Process (ML-KEM-768 + AES-256-GCM):**
1. **User Password Layer** (optional): If user provides a password, secret is first encrypted with ML-KEM-768 + AES-256-GCM
2. **System SECRET_KEY Layer** (always): Result is then encrypted again with the system-level SECRET_KEY
3. **Storage**: Doubly-encrypted PQC blob is stored in Azure KeyVault

**Decryption Process:**
1. **System Layer**: Secret is first decrypted using SECRET_KEY
2. **User Layer**: If password was used, secret is then decrypted with the user's password

This ensures bulletproof detection of encryption status without content inspection, preventing false positives from base64-encoded data.

### Time-based Expiration

Secrets can be created with an optional expiration time:
- Provide `expires_at` as a UNIX timestamp (seconds since epoch, e.g., 1735689599)
- Expired secrets are automatically detected and deleted when accessed
- Returns HTTP 410 Gone for expired secrets
- Expiration is checked during both `check` and `retrieve` operations

## API Reference

### Create Secret

Store a new secret and receive a UUID to access it. Optionally encrypt with a password and/or set an expiration time.

**Request (plaintext secret):**
```json
{
  "action": "create",
  "secret": "Your secret message here",
  "turnstile_token": "cloudflare-turnstile-response-token"
}
```

**Request (password-encrypted secret):**
```json
{
  "action": "create",
  "secret": "Your secret message here",
  "password": "your-encryption-password",
  "turnstile_token": "cloudflare-turnstile-response-token"
}
```

**Request (secret with expiration time):**
```json
{
  "action": "create",
  "secret": "Your secret message here",
  "expires_at": 1735689599,
  "turnstile_token": "cloudflare-turnstile-response-token"
}
```

**Request (password-encrypted secret with expiration):**
```json
{
  "action": "create",
  "secret": "Your secret message here",
  "password": "your-encryption-password",
  "expires_at": 1735689599,
  "turnstile_token": "cloudflare-turnstile-response-token"
}
```

**Response (201 Created):**
```json
{
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "message": "Secret created successfully"
}
```

**Response (201 Created - with expiration):**
```json
{
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "message": "Secret created successfully",
  "expires_at": 1735689599
}
```

**Notes:**
- If `password` is provided, the secret is encrypted with ML-KEM-768 + AES-256-GCM (PQC)
- The same password must be provided during retrieval to decrypt
- Metadata is stored to track encryption status (bulletproof detection)
- If `expires_at` is provided, the secret will automatically expire and be deleted at that time
- `expires_at` must be a UNIX timestamp (seconds since epoch) and in the future
- Expired secrets return a 410 Gone status and are automatically deleted

**Response (400 Bad Request - Turnstile enabled, token missing):**
```json
{
  "error": "Missing required field: turnstile_token (bot protection enabled)"
}
```

**Response (400 Bad Request - Invalid expiration):**
```json
{
  "error": "expires_at must be in the future"
}
```

**Response (403 Forbidden - Invalid Turnstile token):**
```json
{
  "error": "Invalid or expired Turnstile token"
}
```

### Check Secret

Check if a secret is encrypted without retrieving or deleting it. This is useful for frontend applications to conditionally render password input fields.

**Request:**
```json
{
  "action": "check",
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "turnstile_token": "cloudflare-turnstile-response-token"
}
```

**Response (200 OK - Encrypted secret):**
```json
{
  "encrypted": true,
  "requires_password": true
}
```

**Response (200 OK - Plaintext secret):**
```json
{
  "encrypted": false,
  "requires_password": false
}
```

**Response (200 OK - Secret with expiration):**
```json
{
  "encrypted": false,
  "requires_password": false,
  "expires_at": 1735689599
}
```

**Response (404 Not Found):**
```json
{
  "error": "Secret not found or already accessed"
}
```

**Response (410 Gone - Secret expired):**
```json
{
  "error": "Secret has expired and has been deleted",
  "expired_at": 1735689599
}
```

**Notes:**
- Non-destructive operation - secret remains accessible after check
- Uses stored metadata for bulletproof encryption detection
- No content inspection or heuristics - 100% reliable
- Frontend can use `requires_password` to show/hide password input
- If secret has expiration, `expires_at` field will be included in the response
- Expired secrets return 410 Gone and are automatically deleted

### Retrieve Secret

Retrieve and delete a secret using its UUID (one-time access). Provide password if the secret is encrypted.

**Request (plaintext secret):**
```json
{
  "action": "retrieve",
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "turnstile_token": "cloudflare-turnstile-response-token"
}
```

**Request (encrypted secret with password):**
```json
{
  "action": "retrieve",
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "password": "your-encryption-password",
  "turnstile_token": "cloudflare-turnstile-response-token"
}
```

**Response (200 OK):**
```json
{
  "secret": "Your secret message here",
  "message": "Secret retrieved and deleted successfully"
}
```

**Response (400 Bad Request - Missing password for encrypted secret):**
```json
{
  "error": "Password required for encrypted secret"
}
```

**Response (400 Bad Request - Wrong password):**
```json
{
  "error": "Decryption failed: Invalid password or corrupted data"
}
```

**Response (404 Not Found):**
```json
{
  "error": "Secret not found or already accessed"
}
```

**Response (410 Gone - Secret expired):**
```json
{
  "error": "Secret has expired and has been deleted",
  "expired_at": 1735689599
}
```

**Notes:**
- Secret is automatically deleted after successful retrieval (one-time access)
- If secret is encrypted, password must match the one used during creation
- Wrong password or missing password for encrypted secrets returns 400 error and secret remains accessible for retry
- Multiple password attempts are allowed until correct password is provided
- Secret is only deleted upon successful decryption and retrieval
- Expired secrets return 410 Gone status and are automatically deleted from storage

## Workflow Examples

### Basic Workflow (Plaintext Secret)

1. **Create** a plaintext secret:
   ```bash
   curl -X POST https://lambda-url/secrets \
     -H "Content-Type: application/json" \
     -d '{
       "action": "create",
       "secret": "Meet me at the coffee shop at 3pm",
       "turnstile_token": "token..."
     }'
   ```
   Response: `{"uuid": "abc-123", "message": "Secret created successfully"}`

2. **Share** the UUID with recipient: `https://yourapp.com/view/abc-123`

3. **Check** if password is needed (optional):
   ```bash
   curl -X POST https://lambda-url/secrets \
     -H "Content-Type: application/json" \
     -d '{
       "action": "check",
       "uuid": "abc-123",
       "turnstile_token": "token..."
     }'
   ```
   Response: `{"encrypted": false, "requires_password": false}`

4. **Retrieve** the secret:
   ```bash
   curl -X POST https://lambda-url/secrets \
     -H "Content-Type: application/json" \
     -d '{
       "action": "retrieve",
       "uuid": "abc-123",
       "turnstile_token": "token..."
     }'
   ```
   Response: `{"secret": "Meet me at the coffee shop at 3pm", ...}`

5. **Try again** - fails with 404 (already accessed)

### Advanced Workflow (Password-Encrypted Secret)

1. **Create** an encrypted secret:
   ```bash
   curl -X POST https://lambda-url/secrets \
     -H "Content-Type: application/json" \
     -d '{
       "action": "create",
       "secret": "Database password: super_secret_123",
       "password": "myStrongPassword2024",
       "turnstile_token": "token..."
     }'
   ```
   Response: `{"uuid": "xyz-789", "message": "Secret created successfully"}`

2. **Share** UUID and password separately:
   - Email: "Here's the secret UUID: xyz-789"
   - SMS: "Password: myStrongPassword2024"

3. **Check** encryption status:
   ```bash
   curl -X POST https://lambda-url/secrets \
     -H "Content-Type: application/json" \
     -d '{
       "action": "check",
       "uuid": "xyz-789",
       "turnstile_token": "token..."
     }'
   ```
   Response: `{"encrypted": true, "requires_password": true}`
   (Frontend shows password input field)

4. **Retrieve** with password:
   ```bash
   curl -X POST https://lambda-url/secrets \
     -H "Content-Type: application/json" \
     -d '{
       "action": "retrieve",
       "uuid": "xyz-789",
       "password": "myStrongPassword2024",
       "turnstile_token": "token..."
     }'
   ```
   Response: `{"secret": "Database password: super_secret_123", ...}`

5. **Wrong password** - returns 400 but secret remains accessible for retry

## Deployment

> **📖 For detailed setup instructions, see [MULTI_REGION_SETUP.md](./MULTI_REGION_SETUP.md)**

### Multi-Region Deployment Architecture

The service supports multi-region deployment to AWS Lambda across multiple geographic regions, with each region using region-specific Azure Key Vault credentials. This architecture provides:

- **Global availability**: Deploy to 6 AWS regions (Europe, US, Asia-Pacific)
- **Regional isolation**: Each region has its own Azure Key Vault
- **Improved performance**: Users can connect to the nearest region
- **High availability**: Redundancy across multiple regions

**Supported Regions:**

| AWS Region | Azure Region Code | Geographic Location |
|------------|-------------------|---------------------|
| eu-west-1 | WESTEUROPE | West Europe (Ireland) |
| eu-central-1 | GERMANYWESTCENTRAL | Germany West Central |
| us-east-1 | EASTUS | East US (Virginia) |
| us-west-2 | WESTUS2 | West US 2 (Washington) |
| ap-southeast-1 | SOUTHEASTASIA | Southeast Asia (Singapore) |
| ap-northeast-1 | JAPANEAST | Japan East (Tokyo) |

### Prerequisites

1. **AWS Account** with:
   - ECR repository: `acido-secrets` (in eu-west-1 for centralized image storage)
   - Lambda functions: `acido-secrets` deployed in each target region
   - Appropriate IAM permissions for multi-region deployment
   - Lambda Function URLs configured for each regional Lambda (optional but recommended)

2. **Azure Account** with:
   - One Key Vault created per region
   - Service Principal with Key Vault access for each vault
   - Each Key Vault should have appropriate permissions configured

3. **GitHub Secrets** configured (Global):
   - `AWS_ACCESS_KEY_ID` - AWS access key for deployment
   - `AWS_SECRET_ACCESS_KEY` - AWS secret key for deployment
   - `CF_SECRET_KEY` - CloudFlare Turnstile secret key (optional, for bot protection)
   - `CORS_ORIGIN` - Comma-separated list of allowed CORS origins (optional, defaults to secrets.merabytes.com, app.merabytes.com, and local.merabytes.com)

### Automated Deployment

The service automatically deploys to all configured AWS Lambda regions when changes are pushed to the `main` branch.

**Deployment Process:**
1. **Build Stage**: Docker image is built once and pushed to ECR (eu-west-1)
2. **Deploy Stage**: Image is deployed to Lambda functions in all 6 regions in parallel
3. **Configuration**: Each region's Lambda is configured with region-specific Azure Key Vault credentials
4. **Testing**: Health checks are performed on each regional deployment
5. **Summary**: Deployment summary is generated with all regional endpoints
6. **JSON Output**: A JSON dictionary of deployed function URLs is displayed in the format: `{"aws-region": "function-url"}`

See `.github/workflows/deploy.yml` for the multi-region deployment workflow.

**Deployment Output:**

The GitHub Actions workflow automatically outputs a JSON dictionary of all deployed Lambda function URLs in the "Deployment Summary" job. This makes it easy to copy and use in your frontend application:

```json
{
  "eu-west-1": "https://abc123.lambda-url.eu-west-1.on.aws/",
  "eu-central-1": "https://def456.lambda-url.eu-central-1.on.aws/",
  "us-east-1": "https://ghi789.lambda-url.us-east-1.on.aws/",
  "us-west-2": "https://jkl012.lambda-url.us-west-2.on.aws/",
  "ap-southeast-1": "https://mno345.lambda-url.ap-southeast-1.on.aws/",
  "ap-northeast-1": "https://pqr678.lambda-url.ap-northeast-1.on.aws/"
}
```

### Getting Lambda Function URLs

After deployment, the function URLs are automatically collected and displayed in JSON format in the workflow logs. You can also retrieve them manually for each region:

```bash
# Get function URL for a specific region
aws lambda get-function-url-config \
  --function-name AcidoSecrets \
  --region eu-west-1 \
  --query 'FunctionUrl' \
  --output text
```

**Frontend Integration Example:**

Create a dictionary mapping regions to Lambda URLs:

```javascript
const REGION_ENDPOINTS = {
  'eu-west-1': 'https://abc123.lambda-url.eu-west-1.on.aws/',
  'eu-central-1': 'https://def456.lambda-url.eu-central-1.on.aws/',
  'us-east-1': 'https://ghi789.lambda-url.us-east-1.on.aws/',
  'us-west-2': 'https://jkl012.lambda-url.us-west-2.on.aws/',
  'ap-southeast-1': 'https://mno345.lambda-url.ap-southeast-1.on.aws/',
  'ap-northeast-1': 'https://pqr678.lambda-url.ap-northeast-1.on.aws/',
};

// Select nearest region or allow user to choose
const selectedRegion = 'eu-west-1';
const lambdaUrl = REGION_ENDPOINTS[selectedRegion];
```

### Helper Scripts

Two helper scripts are provided to assist with multi-region deployment:

#### 1. Validation Script

Validates that all prerequisites are in place before deployment:

```bash
./scripts/validate-setup.sh
```

This script checks:
- AWS and Azure CLI installation
- AWS and Azure credentials
- ECR repository existence
- Lambda functions in all regions
- Azure Key Vaults in all regions
- GitHub secrets configuration checklist

#### 2. Get Function URLs Script

Retrieves Lambda Function URLs from all regions in various formats:

```bash
./scripts/get-function-urls.sh
```

Output formats:
- JSON (for APIs)
- JavaScript (for frontend)
- Python (for backend)
- Table (for documentation)

Use this script after deployment to get the region endpoints dictionary for your frontend application.

### Manual Deployment

1. **Build the Docker image:**
```bash
docker build -t acido-secrets:latest -f Dockerfile.lambda.secrets .
```

2. **Tag and push to ECR:**
```bash
docker tag acido-secrets:latest <ECR_REGISTRY>/acido-secrets:latest
docker push <ECR_REGISTRY>/acido-secrets:latest
```

3. **Update Lambda function:**
```bash
aws lambda update-function-code \
  --function-name AcidoSecrets \
  --image-uri <ECR_REGISTRY>/acido-secrets:latest
```

4. **Set environment variables (minimal configuration):**
```bash
# Generate a random SECRET_KEY for additional encryption
SECRET_KEY=$(openssl rand -hex 32)

aws lambda update-function-configuration \
  --function-name AcidoSecrets \
  --environment "Variables={
    KEY_VAULT_NAME=<your-vault-name>,
    AZURE_TENANT_ID=<tenant-id>,
    AZURE_CLIENT_ID=<client-id>,
    AZURE_CLIENT_SECRET=<client-secret>,
    SECRET_KEY=$SECRET_KEY,
    CORS_ORIGIN=https://secrets.merabytes.com
  }"
```

5. **Set environment variables (with all optional features):**
```bash
# Generate a random SECRET_KEY for additional encryption
SECRET_KEY=$(openssl rand -hex 32)

aws lambda update-function-configuration \
  --function-name AcidoSecrets \
  --environment "Variables={
    KEY_VAULT_NAME=<your-vault-name>,
    AZURE_TENANT_ID=<tenant-id>,
    AZURE_CLIENT_ID=<client-id>,
    AZURE_CLIENT_SECRET=<client-secret>,
    SECRET_KEY=$SECRET_KEY,
    CORS_ORIGIN=<your-cors-origin-url>,
    CF_SECRET_KEY=<cloudflare-turnstile-secret-key>
  }"
```

## CORS Configuration

The Lambda function supports Cross-Origin Resource Sharing (CORS) to allow web applications to interact with the secrets API. The service now supports **multiple allowed origins** with dynamic origin matching.

### Configuration

- **Default Origins**: If not specified, the service allows requests from:
  - `https://secrets.merabytes.com`
  - `https://app.merabytes.com`
  - `https://local.merabytes.com`

- **Custom Origins**: Set `CORS_ORIGIN` environment variable to a comma-separated list of allowed origins
- **Dynamic Matching**: The service inspects the `Origin` header in each request and returns it in the response if it's in the allowed list

**Example - Single origin:**
```bash
# Set custom CORS origin (single domain)
aws lambda update-function-configuration \
  --function-name AcidoSecrets \
  --environment "Variables={...,CORS_ORIGIN=https://myapp.example.com}"
```

**Example - Multiple origins:**
```bash
# Set custom CORS origins (multiple domains, comma-separated)
aws lambda update-function-configuration \
  --function-name AcidoSecrets \
  --environment "Variables={...,CORS_ORIGIN=https://app1.example.com,https://app2.example.com,https://local.example.com}"
```

**In GitHub Actions:**
Add `CORS_ORIGIN` to your repository secrets to configure it during deployment. Use a comma-separated list for multiple origins.

### CORS Headers

The service responds with the following CORS headers:
- `Access-Control-Allow-Origin`: Dynamically set to match the request origin if it's in the allowed list (defaults to first allowed origin if no match)
- `Access-Control-Allow-Methods`: `POST, OPTIONS`
- `Access-Control-Allow-Headers`: `Content-Type`

### How It Works

1. The service extracts the `Origin` header from incoming requests
2. If the origin is in the allowed list, it's returned in the `Access-Control-Allow-Origin` response header
3. If the origin is not in the allowed list (or missing), the first allowed origin is used as the default
4. This allows multiple frontend applications to interact with the same Lambda function while maintaining security

## CloudFlare Turnstile Integration

CloudFlare Turnstile provides bot protection to prevent abuse of the secrets service. It's **optional** and only activated when the `CF_SECRET_KEY` environment variable is set.

### Setup

1. **Create a Turnstile Site:**
   - Go to https://dash.cloudflare.com/
   - Navigate to Turnstile
   - Create a new site
   - Choose "Managed" or "Non-Interactive" mode
   - Copy the Site Key and Secret Key

2. **Configure Lambda:**
   - Add `CF_SECRET_KEY` to your Lambda environment variables
   - Deploy the updated configuration

3. **Frontend Integration:**
   ```html
   <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
   
   <div class="cf-turnstile" data-sitekey="YOUR_SITE_KEY"></div>
   ```

4. **Send Token with Request:**
   ```javascript
   const turnstileToken = document.querySelector('[name="cf-turnstile-response"]').value;
   
   fetch(lambdaUrl, {
     method: 'POST',
     headers: { 'Content-Type': 'application/json' },
     body: JSON.stringify({
       action: 'create',
       secret: 'my-secret',
       turnstile_token: turnstileToken
     })
   });
   ```

### How It Works

- **When CF_SECRET_KEY is NOT set**: Turnstile validation is skipped entirely
- **When CF_SECRET_KEY is set**: All requests must include a valid `turnstile_token`
- Invalid or missing tokens return 403 Forbidden
- The service validates tokens with CloudFlare's API
- Remote IP is extracted from Lambda context when available


**Note:** Remember to include `turnstile_token` in all requests if CloudFlare Turnstile is enabled.

## Security Considerations

1. **One-Time Access**: Secrets are automatically deleted after retrieval
2. **Multi-layer Encryption**: Defense-in-depth with two independent encryption layers
   - System-level SECRET_KEY encryption (always applied, auto-generated per deployment)
   - Optional user-level password encryption (AES-256 with PBKDF2, 100,000 iterations)
3. **Password Encryption**: Optional AES-256 encryption with PBKDF2 (100,000 iterations)
4. **Bulletproof Encryption Detection**: Metadata storage ensures reliable encryption status tracking
5. **Azure KeyVault**: Industry-standard secret storage with access controls
6. **HTTPS Only**: All communication should be over HTTPS
7. **No Logging**: Secrets should never be logged
8. **Bot Protection**: CloudFlare Turnstile prevents automated abuse
9. **Secure Deletion**: Secrets deleted even if decryption fails (prevents brute force)
10. **Time Limits**: Consider adding TTL for secrets in Key Vault (future enhancement)


## Troubleshooting

### Common Issues

**Lambda timeout:**
- Default timeout is 3 seconds, increase if needed for Key Vault operations

**Key Vault access denied:**
- Verify Service Principal has `Get`, `Set`, `Delete` permissions
- Check that environment variables are correctly set

**Secret not found on first access:**
- Wait a few seconds after creation for Key Vault replication
- Verify the UUID is correct


## License

MIT License - See LICENSE file for details

## Contributors

- Xavier Álvarez (xalvarez@merabytes.com)

