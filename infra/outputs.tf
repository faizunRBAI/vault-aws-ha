output "alb_dns_name" {
  description = "DNS name of the Vault Application Load Balancer"
  value       = aws_lb.vault.dns_name
}

output "alb_zone_id" {
  description = "Route53 zone ID of the Vault ALB"
  value       = aws_lb.vault.zone_id
}

output "bastion_public_ip" {
  description = "Public IP of the bastion host"
  value       = aws_eip.bastion.public_ip
}

output "vault_asg_name" {
  description = "Name of the Vault Auto Scaling Group"
  value       = aws_autoscaling_group.vault.name
}

output "vault_s3_bucket" {
  description = "S3 bucket name for Vault storage backend"
  value       = aws_s3_bucket.vault.bucket
}

output "vault_dynamo_table" {
  description = "DynamoDB table name for Vault HA lock"
  value       = aws_dynamodb_table.vault_ha.name
}

output "vault_kms_key_id" {
  description = "KMS key ID for Vault auto-unseal"
  value       = aws_kms_key.vault_unseal.key_id
}

output "vault_kms_key_arn" {
  description = "KMS key ARN for Vault auto-unseal"
  value       = aws_kms_key.vault_unseal.arn
}

output "vault_instance_role_arn" {
  description = "ARN of the Vault IAM instance role"
  value       = aws_iam_role.vault.arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (Vault nodes)"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "vault_audit_log_group" {
  description = "CloudWatch log group for Vault audit logs"
  value       = aws_cloudwatch_log_group.vault_audit.name
}

output "vault_system_log_group" {
  description = "CloudWatch log group for Vault system logs"
  value       = aws_cloudwatch_log_group.vault_system.name
}
