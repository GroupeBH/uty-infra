terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

locals {
  alternate_azs          = [for az in data.aws_availability_zones.available.names : az if az != var.availability_zone]
  effective_secondary_az = var.secondary_availability_zone != "" ? var.secondary_availability_zone : (length(local.alternate_azs) > 0 ? local.alternate_azs[0] : var.availability_zone)
  effective_ami_id       = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu[0].id

  primary_instance_name   = var.instance_name
  secondary_instance_name = "${var.instance_name}-secondary"

  app_scheme = var.domain_name != "" ? "https" : "http"
  app_host   = var.domain_name != "" ? var.domain_name : aws_eip.primary.public_ip
  app_url    = "${local.app_scheme}://${local.app_host}"

  common_tags = {
    ManagedBy   = "terraform"
    Project     = "uty"
    Environment = "production"
  }

  instance_bootstrap = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    if command -v snap >/dev/null 2>&1; then
      snap install amazon-ssm-agent --classic || true
    fi

    systemctl enable amazon-ssm-agent || systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service || true
    systemctl start amazon-ssm-agent || systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service || true
  EOT
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "uty-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "uty-igw"
  })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "uty-public-${var.availability_zone}"
    Tier = "public"
  })
}

resource "aws_subnet" "secondary_public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.secondary_public_subnet_cidr
  availability_zone       = local.effective_secondary_az
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "uty-public-${local.effective_secondary_az}"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "uty-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "secondary_public" {
  subnet_id      = aws_subnet.secondary_public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "app" {
  name        = "uty-app-sg"
  description = "Shared security group for uty API nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from admin CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "uty-app-sg"
  })
}

resource "aws_iam_role" "ec2" {
  name               = "uty-api-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = merge(local.common_tags, {
    Name = "uty-api-ec2-role"
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "uty-api-ec2-profile"
  role = aws_iam_role.ec2.name
}

resource "aws_instance" "primary" {
  ami                         = local.effective_ami_id
  instance_type               = var.instance_type
  availability_zone           = var.availability_zone
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  key_name                    = var.key_name
  user_data                   = local.instance_bootstrap

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size           = 16
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.common_tags, {
    Name = local.primary_instance_name
    Role = "primary"
  })
}

resource "aws_instance" "secondary" {
  count = var.secondary_instance_enabled ? 1 : 0

  ami                         = local.effective_ami_id
  instance_type               = var.instance_type
  availability_zone           = local.effective_secondary_az
  subnet_id                   = aws_subnet.secondary_public.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  key_name                    = var.key_name
  user_data                   = local.instance_bootstrap

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size           = 16
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.common_tags, {
    Name = local.secondary_instance_name
    Role = "secondary"
  })
}

resource "aws_eip" "primary" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${local.primary_instance_name}-eip"
  })
}

resource "aws_eip_association" "primary" {
  allocation_id = aws_eip.primary.id
  instance_id   = aws_instance.primary.id
}

resource "aws_eip" "secondary" {
  count  = var.secondary_instance_enabled ? 1 : 0
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${local.secondary_instance_name}-eip"
  })
}

resource "aws_eip_association" "secondary" {
  count = var.secondary_instance_enabled ? 1 : 0

  allocation_id = aws_eip.secondary[0].id
  instance_id   = aws_instance.secondary[0].id
}

resource "aws_cloudwatch_log_group" "primary_app" {
  name              = "/${local.primary_instance_name}/app"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, {
    Name = "${local.primary_instance_name}-app-logs"
  })
}

resource "aws_cloudwatch_log_group" "primary_caddy" {
  name              = "/${local.primary_instance_name}/caddy"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, {
    Name = "${local.primary_instance_name}-caddy-logs"
  })
}

resource "aws_cloudwatch_log_group" "secondary_app" {
  count             = var.secondary_instance_enabled ? 1 : 0
  name              = "/${local.secondary_instance_name}/app"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, {
    Name = "${local.secondary_instance_name}-app-logs"
  })
}

resource "aws_cloudwatch_log_group" "secondary_caddy" {
  count             = var.secondary_instance_enabled ? 1 : 0
  name              = "/${local.secondary_instance_name}/caddy"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, {
    Name = "${local.secondary_instance_name}-caddy-logs"
  })
}

resource "aws_sns_topic" "ops_alerts" {
  count = length(var.alarm_email_endpoints) > 0 ? 1 : 0
  name  = "uty-ops-alerts"

  tags = merge(local.common_tags, {
    Name = "uty-ops-alerts"
  })
}

resource "aws_sns_topic_subscription" "email" {
  for_each = length(var.alarm_email_endpoints) > 0 ? toset(var.alarm_email_endpoints) : toset([])

  topic_arn = aws_sns_topic.ops_alerts[0].arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_ssm_parameter" "secure" {
  for_each = var.ssm_secure_parameters

  name  = each.key
  type  = "SecureString"
  value = each.value
  tier  = "Standard"

  tags = merge(local.common_tags, {
    Name = each.key
  })
}

resource "aws_cloudwatch_metric_alarm" "primary_system" {
  alarm_name          = "${local.primary_instance_name}-StatusCheckFailed-System"
  alarm_description   = "Recover the primary EC2 instance when the system status check fails."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.primary.id
  }

  alarm_actions = concat(
    ["arn:aws:automate:${var.aws_region}:ec2:recover"],
    aws_sns_topic.ops_alerts[*].arn,
  )
}

resource "aws_cloudwatch_metric_alarm" "primary_instance" {
  alarm_name          = "${local.primary_instance_name}-StatusCheckFailed-Instance"
  alarm_description   = "Alert when the primary EC2 instance status check fails."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.primary.id
  }

  alarm_actions = aws_sns_topic.ops_alerts[*].arn
}

resource "aws_cloudwatch_metric_alarm" "secondary_system" {
  count = var.secondary_instance_enabled ? 1 : 0

  alarm_name          = "${local.secondary_instance_name}-StatusCheckFailed-System"
  alarm_description   = "Recover the secondary EC2 instance when the system status check fails."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.secondary[0].id
  }

  alarm_actions = concat(
    ["arn:aws:automate:${var.aws_region}:ec2:recover"],
    aws_sns_topic.ops_alerts[*].arn,
  )
}

resource "aws_cloudwatch_metric_alarm" "secondary_instance" {
  count = var.secondary_instance_enabled ? 1 : 0

  alarm_name          = "${local.secondary_instance_name}-StatusCheckFailed-Instance"
  alarm_description   = "Alert when the secondary EC2 instance status check fails."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.secondary[0].id
  }

  alarm_actions = aws_sns_topic.ops_alerts[*].arn
}