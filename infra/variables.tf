variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (Vault nodes)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "availability_zones" {
  description = "Availability zones to use"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "vault_instance_type" {
  description = "EC2 instance type for Vault nodes"
  type        = string
  default     = "t3.medium"
}

variable "bastion_instance_type" {
  description = "EC2 instance type for the bastion host"
  type        = string
  default     = "t3.micro"
}

variable "vault_asg_min" {
  description = "Minimum number of Vault nodes in ASG"
  type        = number
  default     = 3
}

variable "vault_asg_max" {
  description = "Maximum number of Vault nodes in ASG"
  type        = number
  default     = 6
}

variable "vault_asg_desired" {
  description = "Desired number of Vault nodes in ASG"
  type        = number
  default     = 3
}

variable "vault_version" {
  description = "HashiCorp Vault version to install"
  type        = string
  default     = "1.15.6"
}

variable "ssh_public_key" {
  description = "SSH public key material for EC2 key pair"
  type        = string
  sensitive   = true
}

variable "vault_kms_key_alias" {
  description = "KMS key alias for Vault auto-unseal (e.g. alias/vault-unseal)"
  type        = string
  default     = "alias/vault-aws-ha-unseal"
}

variable "trusted_cidr" {
  description = "Trusted CIDR block for bastion SSH and ALB HTTP access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "cloudwatch_log_retention_days" {
  description = "CloudWatch log retention period in days"
  type        = number
  default     = 30
}

variable "vault_health_check_path" {
  description = "ALB health check path for Vault"
  type        = string
  default     = "/v1/sys/health"
}
