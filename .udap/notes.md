# vault-aws-ha — Build Notes

## Status
- [x] Meta approved
- [x] Architecture written (rev 1)
- [x] Pipeline written (rev 1)
- [x] Design approved
- [x] Plan approved
- [ ] Files generated
- [ ] validate_project
- [ ] test_project
- [ ] create_repo_and_push
- [ ] secrets set
- [ ] deploy

## Architecture Decisions
- Custom VPC (10.0.0.0/16) with 3 public + 3 private subnets across us-east-1a/b/c
- Vault nodes in PRIVATE subnets; only reachable via ALB (port 8200) or bastion (SSH)
- ALB is internet-facing, terminates TLS via ACM cert (user must supply ACM_CERTIFICATE_ARN)
- KMS auto-unseal: CMK created by TF; alias stored as VAULT_KMS_KEY_ALIAS secret
- S3 backend with versioning + SSE-AES256; DynamoDB HA lock with PAY_PER_REQUEST
- Bastion in public subnet with EIP; SSH restricted to TRUSTED_CIDR
- IAM: instance role with least-privilege inline policies (no managed policies)
- ASG: min=3, max=6, desired=3; target tracking CPU 60%; Ubuntu 22.04 t3.medium
- CloudWatch log group /vault/audit, 30-day retention
- Vault 1.15.x binary (community/OSS)

## Pipeline Secrets Required (user must set these before first deploy)
- VAULT_KMS_KEY_ALIAS: e.g. "alias/vault-aws-ha-unseal" (TF creates the key, this is just the alias name string)
- ACM_CERTIFICATE_ARN: real ACM cert ARN for the ALB HTTPS listener (MUST be valid)
- TRUSTED_CIDR: your IP CIDR for bastion+ALB access, e.g. "203.0.113.5/32"
- VAULT_S3_BUCKET: derived from project_name — set after TF apply (or use a fixed name)
- VAULT_DYNAMO_TABLE: derived from project_name — same
- VAULT_KMS_KEY_ID: the KMS key ID output from TF apply

## Post-Deploy Manual Steps (one-time)
1. SSH via bastion to first Vault node
2. `vault operator init` — saves 5 recovery keys + root token
3. Store recovery keys in a secure vault (AWS Secrets Manager recommended)
4. Vault should auto-unseal via KMS
5. Enable auth: `vault auth enable aws` and `vault auth enable userpass`
6. Enable secrets engines: `vault secrets enable -path=secret kv-v2`
   `vault secrets enable database` / `vault secrets enable transit` / `vault secrets enable pki`
7. See scripts/vault-init.sh for full command reference

## Known Pitfalls
- NAT GWs are the biggest cost driver (~$100/mo for 3)
- ACM cert must be issued in us-east-1 and VALIDATED before deploy (ALB listener fails otherwise)
- Vault init is a one-time manual step — not automated in pipeline (recovery keys must be human-handled)
- TLS on vault.hcl listener: using self-signed cert initially; replace with ACM-issued cert path for production
- The configure stage resolves ASG instance IPs dynamically via AWS CLI — instances need ~2 min to pass health checks after ASG launch

## Recovery Notes
- If provision fails: check TF state, fix init flags
- If configure fails: check bastion SG 22 from runner IPs (GitHub Actions IPs are dynamic — may need 0.0.0.0/0 on bastion or use SSM)
- Vault sealed after restart = KMS key policy issue; check instance role has kms:Decrypt
