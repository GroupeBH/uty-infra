variable "aws_region" {
  description = "AWS region used for all resources."
  type        = string
  default     = "eu-central-1"
}

variable "availability_zone" {
  description = "Primary Availability Zone."
  type        = string
  default     = "eu-central-1a"
}

variable "secondary_availability_zone" {
  description = "Secondary Availability Zone. Leave empty to auto-pick a different AZ when possible."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the primary public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "secondary_public_subnet_cidr" {
  description = "CIDR block for the secondary public subnet."
  type        = string
  default     = "10.0.2.0/24"
}

variable "ami_id" {
  description = "Explicit AMI ID. Leave empty to auto-select the latest Canonical Ubuntu 22.04 LTS AMI."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for both nodes."
  type        = string
  default     = "t3.micro"
}

variable "secondary_instance_enabled" {
  description = "Whether to provision the passive secondary EC2 node."
  type        = bool
  default     = true
}

variable "key_name" {
  description = "EC2 key pair name used for SSH access."
  type        = string
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH to both nodes."
  type        = string
}

variable "additional_admin_cidrs" {
  description = "Additional CIDR blocks allowed to SSH to both nodes, for example a CI runner public IP."
  type        = list(string)
  default     = []
}

variable "instance_name" {
  description = "Base instance name. Primary keeps this exact value."
  type        = string
  default     = "uty-api"
}

variable "domain_name" {
  description = "External DNS name served by Caddy. Leave empty to expose HTTP only on port 80."
  type        = string
  default     = ""
}

variable "caddy_email" {
  description = "Email address used by Caddy for ACME registration when a domain is configured."
  type        = string
  default     = ""
}

variable "app_image_repository" {
  description = "Docker Hub repository for the NestJS image."
  type        = string
}

variable "app_image_tag" {
  description = "Docker image tag to deploy."
  type        = string
  default     = "latest"
}

variable "app_healthcheck_path" {
  description = "Application health endpoint path."
  type        = string
  default     = "/health"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period."
  type        = number
  default     = 14
}

variable "alarm_email_endpoints" {
  description = "Optional list of email endpoints subscribed to SNS alerts."
  type        = list(string)
  default     = []
}

variable "ssm_secure_parameters" {
  description = "Optional SecureString SSM parameters to create. Map key is the parameter name."
  type        = map(string)
  default     = {}
}
