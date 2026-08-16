#!/usr/bin/env bash
# vault-init.sh
# One-time Vault initialization guide script for vault-aws-ha
#
# IMPORTANT: Run this ONCE on ONE Vault node after first deploy.
# SSH via bastion: ssh -J ubuntu@<BASTION_IP> ubuntu@<VAULT_NODE_PRIVATE_IP>
#
# This script prints commands for review — it does NOT execute them automatically.
# Run each block manually after inspecting it.

set -euo pipefail

ALB_DNS="${1:-}" # Pass your ALB DNS or use the VAULT_ADDR env var
VAULT_ADDR="${VAULT_ADDR:-https://${ALB_DNS}}"

cat <<'BANNER'
╔══════════════════════════════════════════════════════════════════╗
║          HashiCorp Vault — One-Time Initialization Guide         ║
╚══════════════════════════════════════════════════════════════════╝
BANNER

echo ""
echo "==> Step 1: Export Vault address (use ALB DNS or node private IP)"
echo ""
echo "    export VAULT_ADDR='https://<ALB_DNS>'"
echo "    export VAULT_SKIP_VERIFY=true   # only if using self-signed cert"
echo ""

echo "==> Step 2: Check Vault status"
echo ""
echo "    vault status"
echo ""
echo "    Expected: Initialized=false, Sealed=true, Storage Type=s3"
echo ""

echo "==> Step 3: Initialize Vault (run ONCE — generates root token and recovery keys)"
echo ""
echo "    vault operator init \\"
echo "      -recovery-shares=5 \\"
echo "      -recovery-threshold=3"
echo ""
echo "    CRITICAL: Save the 5 Recovery Keys and the Initial Root Token IMMEDIATELY."
echo "    Store them in AWS Secrets Manager:"
echo ""
echo "    aws secretsmanager create-secret \\"
echo "      --name /${PROJECT_NAME:-vault-aws-ha}/recovery-keys \\"
echo "      --secret-string '{\"key1\":\"...\",\"key2\":\"...\",\"root_token\":\"...\"}'"
echo ""

echo "==> Step 4: Verify auto-unseal (KMS should unseal automatically)"
echo ""
echo "    vault status"
echo "    # Sealed should be: false"
echo ""

echo "==> Step 5: Login with root token (temporary — revoke after setup)"
echo ""
echo "    vault login <ROOT_TOKEN>"
echo ""

echo "==> Step 6: Enable AWS IAM auth method"
echo ""
echo "    vault auth enable aws"
echo "    vault write auth/aws/config/client \\"
echo "      iam_server_id_header_value=<ALB_DNS>"
echo ""
echo "    # Create a role for workload instances"
echo "    vault write auth/aws/role/vault-workload \\"
echo "      auth_type=iam \\"
echo "      bound_iam_principal_arn=arn:aws:iam::<ACCOUNT_ID>:role/<APP_ROLE> \\"
echo "      policies=workload-policy \\"
echo "      ttl=1h \\"
echo "      max_ttl=24h"
echo ""

echo "==> Step 7: Enable userpass auth (for human operators)"
echo ""
echo "    vault auth enable userpass"
echo "    vault write auth/userpass/users/admin \\"
echo "      password=<STRONG_PASSWORD> \\"
echo "      policies=admin-policy"
echo ""

echo "==> Step 8: Enable KV v2 secrets engine"
echo ""
echo "    vault secrets enable -path=secret kv-v2"
echo "    vault kv put secret/example foo=bar"
echo ""

echo "==> Step 9: Enable Transit secrets engine (encryption-as-a-service)"
echo ""
echo "    vault secrets enable transit"
echo "    vault write -f transit/keys/app-encryption-key \\"
echo "      type=aes256-gcm96"
echo ""

echo "==> Step 10: Enable Database secrets engine"
echo ""
echo "    vault secrets enable database"
echo "    vault write database/config/my-rds-db \\"
echo "      plugin_name=postgresql-database-plugin \\"
echo "      allowed_roles=app-role \\"
echo "      connection_url='postgresql://{{username}}:{{password}}@<RDS_ENDPOINT>:5432/<DB_NAME>' \\"
echo "      username=<DB_ADMIN_USER> \\"
echo "      password=<DB_ADMIN_PASS>"
echo ""
echo "    vault write database/roles/app-role \\"
echo "      db_name=my-rds-db \\"
echo "      creation_statements=\"CREATE ROLE \\\"{{name}}\\\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'\" \\"
echo "      default_ttl=1h \\"
echo "      max_ttl=24h"
echo ""

echo "==> Step 11: Enable PKI secrets engine"
echo ""
echo "    vault secrets enable pki"
echo "    vault secrets tune -max-lease-ttl=8760h pki"
echo "    vault write pki/root/generate/internal \\"
echo "      common_name=vault-ca \\"
echo "      ttl=8760h"
echo "    vault write pki/roles/app-certs \\"
echo "      allowed_domains=internal.example.com \\"
echo "      allow_subdomains=true \\"
echo "      max_ttl=720h"
echo ""

echo "==> Step 12: Enable file audit device (logs go to CloudWatch via agent)"
echo ""
echo "    vault audit enable file file_path=/var/log/vault/audit.log"
echo ""

echo "==> Step 13: Revoke root token after setup is complete"
echo ""
echo "    vault token revoke <ROOT_TOKEN>"
echo ""
echo "    Store recovery keys safely. Use 'vault operator generate-root' to"
echo "    generate a new root token when needed."
echo ""

echo "==> Step 14: Key rotation schedule"
echo ""
echo "    # Rotate KMS key (AWS handles this automatically with enable_key_rotation=true)"
echo "    # Rotate IAM access keys annually — these instances use roles, so N/A"
echo "    # Rotate Vault encryption key (barrier key):"
echo "    vault operator rotate"
echo ""

cat <<'FOOTER'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
For full documentation: https://developer.hashicorp.com/vault/docs
FOOTER
