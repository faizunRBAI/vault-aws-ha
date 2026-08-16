# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# VPC & Networking
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project_name}-igw" }
}

# Public subnets (bastion + NAT gateways)
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-public-${count.index + 1}" }
}

# Private subnets (Vault EC2 nodes)
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${var.project_name}-private-${count.index + 1}" }
}

# Elastic IPs for NAT gateways
resource "aws_eip" "nat" {
  count  = length(var.availability_zones)
  domain = "vpc"

  tags = { Name = "${var.project_name}-nat-eip-${count.index + 1}" }

  depends_on = [aws_internet_gateway.main]
}

# NAT gateways - one per AZ for AZ-redundant egress
resource "aws_nat_gateway" "main" {
  count         = length(var.availability_zones)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${var.project_name}-nat-${count.index + 1}" }

  depends_on = [aws_internet_gateway.main]
}

# Route table: public subnets -> IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Route tables: private subnets -> NAT gateways
resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = { Name = "${var.project_name}-private-rt-${count.index + 1}" }
}

resource "aws_route_table_association" "private" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

# ALB security group - accepts HTTP from trusted CIDR
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP inbound from trusted sources"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from trusted CIDR"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.trusted_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-alb-sg" }
}

# Bastion security group - SSH from trusted CIDR
resource "aws_security_group" "bastion" {
  name        = "${var.project_name}-bastion-sg"
  description = "Allow SSH inbound from trusted sources"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from trusted CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.trusted_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-bastion-sg" }
}

# Vault security group - Vault API only from ALB + bastion
resource "aws_security_group" "vault" {
  name        = "${var.project_name}-vault-sg"
  description = "Vault nodes: API from ALB, SSH from bastion, cluster port internal"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Vault API from ALB"
    from_port       = 8200
    to_port         = 8200
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description = "Vault cluster port HA - internal VPC only"
    from_port   = 8201
    to_port     = 8201
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-vault-sg" }
}

# ---------------------------------------------------------------------------
# KMS - Vault auto-unseal CMK
# ---------------------------------------------------------------------------

resource "aws_kms_key" "vault_unseal" {
  description             = "Vault auto-unseal key for ${var.project_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowVaultInstances"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.vault.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = { Name = "${var.project_name}-vault-unseal-key" }
}

resource "aws_kms_alias" "vault_unseal" {
  name          = var.vault_kms_key_alias
  target_key_id = aws_kms_key.vault_unseal.key_id
}

# ---------------------------------------------------------------------------
# S3 - Vault storage backend
# ---------------------------------------------------------------------------

resource "random_id" "bucket_suffix" {
  byte_length = 4

  keepers = {
    project = var.project_name
  }
}

resource "aws_s3_bucket" "vault" {
  bucket        = "${var.project_name}-vault-data-${random_id.bucket_suffix.hex}"
  force_destroy = false

  tags = { Name = "${var.project_name}-vault-data" }
}

resource "aws_s3_bucket_versioning" "vault" {
  bucket = aws_s3_bucket.vault.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vault" {
  bucket = aws_s3_bucket.vault.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "vault" {
  bucket                  = aws_s3_bucket.vault.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "vault" {
  bucket = aws_s3_bucket.vault.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    # AWS provider v5 requires an explicit filter block; empty = apply to all objects
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "vault" {
  bucket = aws_s3_bucket.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyNonVaultRole"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action   = "s3:*"
        Resource = [
          aws_s3_bucket.vault.arn,
          "${aws_s3_bucket.vault.arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:PrincipalArn" = [
              aws_iam_role.vault.arn,
              "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
            ]
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.vault]
}

# ---------------------------------------------------------------------------
# DynamoDB - Vault HA lock table
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "vault_ha" {
  name         = "${var.project_name}-vault-ha-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "Path"
  range_key    = "Key"

  attribute {
    name = "Path"
    type = "S"
  }

  attribute {
    name = "Key"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.vault_unseal.arn
  }

  tags = { Name = "${var.project_name}-vault-ha-lock" }
}

# ---------------------------------------------------------------------------
# IAM - Vault instance role and policies
# ---------------------------------------------------------------------------

resource "aws_iam_role" "vault" {
  name = "${var.project_name}-vault-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = { Name = "${var.project_name}-vault-role" }
}

resource "aws_iam_role_policy" "vault_s3" {
  name = "${var.project_name}-vault-s3-policy"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.vault.arn,
          "${aws_s3_bucket.vault.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "vault_dynamodb" {
  name = "${var.project_name}-vault-dynamodb-policy"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeLimits",
          "dynamodb:DescribeTimeToLive",
          "dynamodb:ListTagsOfResource",
          "dynamodb:DescribeReservedCapacityOfferings",
          "dynamodb:DescribeReservedCapacity",
          "dynamodb:ListTables",
          "dynamodb:BatchGetItem",
          "dynamodb:BatchWriteItem",
          "dynamodb:CreateTable",
          "dynamodb:DeleteItem",
          "dynamodb:GetItem",
          "dynamodb:GetRecords",
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:UpdateItem",
          "dynamodb:Scan",
          "dynamodb:DescribeTable"
        ]
        Resource = aws_dynamodb_table.vault_ha.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "vault_kms" {
  name = "${var.project_name}-vault-kms-policy"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*"
        ]
        Resource = aws_kms_key.vault_unseal.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "vault_cloudwatch" {
  name = "${var.project_name}-vault-cloudwatch-policy"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "cloudwatch:PutMetricData",
          "ec2:DescribeVolumes",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      }
    ]
  })
}

# Vault IAM auth: allow instances to describe themselves for auth
resource "aws_iam_role_policy" "vault_iam_auth" {
  name = "${var.project_name}-vault-iam-auth-policy"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:GetInstanceProfile",
          "iam:GetUser",
          "iam:GetRole",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "vault" {
  name = "${var.project_name}-vault-profile"
  role = aws_iam_role.vault.name

  tags = { Name = "${var.project_name}-vault-profile" }
}

# ---------------------------------------------------------------------------
# EC2 Key Pair
# ---------------------------------------------------------------------------

resource "aws_key_pair" "vault" {
  key_name   = "${var.project_name}-vault-key"
  public_key = var.ssh_public_key

  tags = { Name = "${var.project_name}-vault-key" }
}

# ---------------------------------------------------------------------------
# Bastion Host
# ---------------------------------------------------------------------------

resource "aws_eip" "bastion" {
  domain = "vpc"

  tags = { Name = "${var.project_name}-bastion-eip" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.bastion_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  key_name               = aws_key_pair.vault.key_name

  user_data = <<-EOT
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y curl unzip
  EOT

  tags = { Name = "${var.project_name}-bastion" }
}

resource "aws_eip_association" "bastion" {
  instance_id   = aws_instance.bastion.id
  allocation_id = aws_eip.bastion.id
}

# ---------------------------------------------------------------------------
# ALB - Application Load Balancer (HTTP)
# ---------------------------------------------------------------------------

resource "aws_lb" "vault" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false

  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_lb_target_group" "vault" {
  name        = "${var.project_name}-vault-tg"
  port        = 8200
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = var.vault_health_check_path
    protocol            = "HTTP"
    port                = "8200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
    matcher             = "200,473"
  }

  tags = { Name = "${var.project_name}-vault-tg" }
}

resource "aws_lb_listener" "vault_http" {
  load_balancer_arn = aws_lb.vault.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault.arn
  }

  tags = { Name = "${var.project_name}-vault-listener" }
}

# ---------------------------------------------------------------------------
# Auto Scaling Group - Vault nodes
# ---------------------------------------------------------------------------

resource "aws_launch_template" "vault" {
  name_prefix   = "${var.project_name}-vault-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.vault_instance_type
  key_name      = aws_key_pair.vault.key_name

  vpc_security_group_ids = [aws_security_group.vault.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.vault.arn
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.vault_unseal.arn
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -e
    # Bootstrap: install dependencies only - Ansible handles Vault install
    apt-get update -y
    apt-get install -y curl unzip python3 python3-pip awscli
    # Signal readiness for Ansible
    touch /tmp/bootstrap-complete
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name      = "${var.project_name}-vault-node"
      Project   = var.project_name
      ManagedBy = "udap"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "vault" {
  name                = "${var.project_name}-vault-asg"
  min_size            = var.vault_asg_min
  max_size            = var.vault_asg_max
  desired_capacity    = var.vault_asg_desired
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.vault.arn]

  # EC2 health check: only tests instance running state, not app health.
  # Using EC2 here because Vault is installed AFTER provision by Ansible —
  # ELB health checks would time out before the app is configured.
  # After Ansible completes, steady-state unhealthy instances are replaced
  # by the ASG on the next EC2 health check cycle.
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.vault.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 66
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-vault-node"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "udap"
    propagate_at_launch = true
  }

  depends_on = [aws_nat_gateway.main]
}

resource "aws_autoscaling_policy" "vault_cpu" {
  name                   = "${var.project_name}-vault-cpu-scaling"
  autoscaling_group_name = aws_autoscaling_group.vault.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}

# ---------------------------------------------------------------------------
# CloudWatch - Log groups and alarms
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "vault_audit" {
  name              = "/vault/audit"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = { Name = "${var.project_name}-vault-audit" }
}

resource "aws_cloudwatch_log_group" "vault_system" {
  name              = "/vault/system"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = { Name = "${var.project_name}-vault-system" }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.project_name}-vault-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  alarm_description   = "Vault ALB target group has unhealthy hosts"

  dimensions = {
    TargetGroup  = aws_lb_target_group.vault.arn_suffix
    LoadBalancer = aws_lb.vault.arn_suffix
  }

  tags = { Name = "${var.project_name}-unhealthy-hosts-alarm" }
}

resource "aws_cloudwatch_metric_alarm" "vault_cpu_high" {
  alarm_name          = "${var.project_name}-vault-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Vault ASG average CPU above 80%"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.vault.name
  }

  tags = { Name = "${var.project_name}-cpu-high-alarm" }
}
