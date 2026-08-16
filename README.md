# vault-aws-ha

Production-grade **HashiCorp Vault** cluster on AWS — private VPC, 3-AZ Auto Scaling Group, ALB with ACM TLS, S3 storage backend, DynamoDB HA lock, KMS auto-unseal, and CloudWatch audit logging.

---

## Architecture

```
Internet
    │ HTTPS 443
    ▼
Application Load Balancer (public subnets, ACM TLS)
    │ HTTPS 8200
    ▼
Auto Scaling Group — 3× Vault EC2 nodes (private subnets, 3 AZs)
    │              │              │
    ▼              ▼              ▼
  S3 Backend   DynamoDB HA   KMS Auto-Unseal
  (storage)    (lock table)  (CMK)
    │
CloudWatch Logs (/vault/audit, /vault/system)

Bastion Host (public subnet) ─SSH─▶ Vault nodes (via ProxyJump)
```

| Component | Detail |
|---|---|
| Vault version | 1.15.6 (OSS) |
| Instance type | t3.medium × 3 (ASG min=3, max=6) |
| OS | Ubuntu 22.04 LTS |
| Storage backend | S3 (versioned, AES-256 SSE) |
| HA coordination | DynamoDB (PAY_PER_REQUEST, PITR enabled) |
| Auto-unseal | AWS KMS CMK (key rotation enabled) |
| TLS | ACM cert on ALB; self-signed on node listener |
| Auth methods | AWS IAM (workloads), userpass (operators) |
| Secrets engines | KV v2, Database, Transit, PKI |
| Audit | File device → CloudWatch Logs |
| IaC | Terraform 1.7.x |
| Config | Ansible (site.yml + roles) |

**Estimated cost:** ~$120–160/month (3× t3.medium + 3× NAT Gateways + ALB + S3 + DynamoDB)

---

## Pipeline Secrets

Set these in your GitHub repository secrets before deploying:

| Secret | Description | Required |
|---|---|---|
| `ACM_CERTIFICATE_ARN` | ARN of a validated ACM cert in `us-east-1` | **Must set** |
| `TRUSTED_CIDR` | Your IP CIDR for bastion SSH + ALB HTTPS (e.g. `203.0.113.5/32`) | **Must set** |
| `VAULT_KMS_KEY_ALIAS` | KMS key alias, e.g. `alias/vault-aws-ha-unseal` | Auto-set |
| `VAULT_S3_BUCKET` | S3 bucket name (set from TF output after first apply) | Auto-set |
| `VAULT_DYNAMO_TABLE` | DynamoDB table name (set from TF output) | Auto-set |
| `VAULT_KMS_KEY_ID` | KMS key ID (set from TF output) | Auto-set |

> **ACM Certificate**: You must create and validate an ACM certificate *before* first deploy.  
> Go to: AWS Console → Certificate Manager → Request → add your domain → DNS validation.

---

## Deploying

1. **Set required secrets** in GitHub → Settings → Secrets → Actions:
   - `ACM_CERTIFICATE_ARN` — your validated ACM cert ARN
   - `TRUSTED_CIDR` — e.g. `203.0.113.5/32` (your public IP)

2. **Push to `main`** — the pipeline runs: lint → provision → configure → verify

3. **After first deploy** — set the remaining secrets from Terraform outputs:
   ```bash
   # From the pipeline logs or terraform output:
   VAULT_S3_BUCKET=<value from tf output>
   VAULT_DYNAMO_TABLE=<value from tf output>
   VAULT_KMS_KEY_ID=<value from tf output>
   ```

---

## One-Time Vault Initialization

After the first successful deploy, SSH to a Vault node and run the init procedure:

```bash
# 1. SSH via bastion
ssh -J ubuntu@<BASTION_IP> ubuntu@<VAULT_NODE_PRIVATE_IP>

# 2. Check status (should be uninitialized)
vault status

# 3. Initialize (generates recovery keys + root token)
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
vault operator init -recovery-shares=5 -recovery-threshold=3

# 4. Store recovery keys in AWS Secrets Manager immediately
aws secretsmanager create-secret \
  --name /vault-aws-ha/recovery-keys \
  --secret-string '{"key1":"...","root_token":"..."}'
```

For full step-by-step commands (auth methods, secrets engines, audit setup):
```bash
bash scripts/vault-init.sh
```

---

## Auth Methods

### AWS IAM (for workloads/applications)
```bash
vault auth enable aws
vault write auth/aws/role/my-app \
  auth_type=iam \
  bound_iam_principal_arn=arn:aws:iam::<ACCOUNT>:role/<APP_ROLE> \
  policies=my-app-policy ttl=1h
```

### Userpass (for human operators)
```bash
vault auth enable userpass
vault write auth/userpass/users/ops password=<PASS> policies=admin-policy
vault login -method=userpass username=ops
```

---

## Secrets Engines

| Engine | Path | Use Case |
|---|---|---|
| KV v2 | `secret/` | Application secrets, API keys |
| Database | `database/` | Dynamic RDS credentials |
| Transit | `transit/` | Encryption-as-a-service |
| PKI | `pki/` | Internal certificate authority |

---

## Key Rotation Runbook

### KMS key rotation
AWS automatically rotates the CMK every year (`enable_key_rotation = true` in Terraform).  
Vault's `awskms` seal uses `kms:Decrypt` which works across all key versions — no Vault restart needed.

### Vault barrier key rotation
```bash
vault operator rotate
```

### Recovery key re-generation (after key loss)
```bash
vault operator rekey -recovery-key \
  -key-shares=5 -key-threshold=3 -init
# Provide 3 of the original 5 recovery keys when prompted
```

### IAM role key rotation
Instance roles use short-lived STS credentials from the instance metadata service — no manual rotation required.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Vault is sealed after restart | KMS key policy | Verify instance role has `kms:Decrypt` on the CMK |
| ALB health check failing | TLS mismatch | Node cert is self-signed; ALB TG matcher includes `473` |
| `permission denied` on S3 | IAM policy | Check instance profile attached; verify S3 bucket policy |
| DynamoDB lock contention | Split brain | Check all 3 nodes are running and reachable on port 8201 |
| Ansible configure fails | Bastion unreachable | GitHub Actions IPs vary — allow `0.0.0.0/0` on bastion:22 temporarily or use SSM |

---

## Directory Structure

```
vault-aws-ha/
├── infra/                    # Terraform IaC
│   ├── main.tf               # VPC, ASG, ALB, S3, DynamoDB, KMS, IAM
│   ├── variables.tf
│   ├── outputs.tf
│   └── versions.tf
├── ansible/                  # Server configuration
│   ├── site.yml              # Main playbook
│   └── roles/
│       ├── common/           # Packages, CloudWatch agent, hardening
│       └── vault/            # Vault install, vault.hcl, systemd
├── scripts/
│   └── vault-init.sh         # One-time initialization guide
└── .udap/
    ├── architecture.d2       # Architecture diagram source
    └── pipeline.yaml         # CI/CD pipeline spec
```

---

## Security Notes

- Vault nodes are in **private subnets** — no public IPs, no direct internet exposure
- Security groups enforce **least-privilege** inbound: port 8200 from ALB only, port 22 from bastion only
- IMDSv2 **required** (`http_tokens = "required"` in launch template)
- EBS volumes are **encrypted at rest** with the same KMS CMK
- KMS key rotation is **enabled** (annual automatic rotation)
- `mlock` is **enabled** — secrets are never swapped to disk
- Root token should be **revoked** after initial setup; use operator generate-root when needed
