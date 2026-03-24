output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "secondary_public_subnet_id" {
  value = aws_subnet.secondary_public.id
}

output "public_subnet_ids" {
  value = [aws_subnet.public.id, aws_subnet.secondary_public.id]
}

output "security_group_id" {
  value = aws_security_group.app.id
}

output "instance_id" {
  value = aws_instance.primary.id
}

output "secondary_instance_id" {
  value = try(aws_instance.secondary[0].id, null)
}

output "instance_ids" {
  value = compact([
    aws_instance.primary.id,
    try(aws_instance.secondary[0].id, null),
  ])
}

output "elastic_ip" {
  value = aws_eip.primary.public_ip
}

output "secondary_elastic_ip" {
  value = try(aws_eip.secondary[0].public_ip, null)
}

output "elastic_ips" {
  value = compact([
    aws_eip.primary.public_ip,
    try(aws_eip.secondary[0].public_ip, null),
  ])
}

output "ssh_command" {
  value = "ssh -i <private-key-path> ubuntu@${aws_eip.primary.public_ip}"
}

output "secondary_ssh_command" {
  value = var.secondary_instance_enabled ? "ssh -i <private-key-path> ubuntu@${aws_eip.secondary[0].public_ip}" : null
}

output "ssh_commands" {
  value = compact([
    "ssh -i <private-key-path> ubuntu@${aws_eip.primary.public_ip}",
    var.secondary_instance_enabled ? "ssh -i <private-key-path> ubuntu@${aws_eip.secondary[0].public_ip}" : null,
  ])
}

output "external_dns_failover_targets" {
  value = {
    primary_public_ip   = aws_eip.primary.public_ip
    secondary_public_ip = try(aws_eip.secondary[0].public_ip, null)
    domain_name         = var.domain_name
    suggested_ttl       = 60
  }
}

output "app_url" {
  value = local.app_url
}

output "health_url" {
  value = "${local.app_url}${var.app_healthcheck_path}"
}

output "cloudwatch_log_group_app" {
  value = aws_cloudwatch_log_group.primary_app.name
}

output "cloudwatch_log_group_caddy" {
  value = aws_cloudwatch_log_group.primary_caddy.name
}

output "ops_alerts_topic_arn" {
  value = try(aws_sns_topic.ops_alerts[0].arn, null)
}

output "deploy_admin_cidr" {
  value = var.admin_cidr
}

output "deploy_app_image_repository" {
  value = var.app_image_repository
}

output "deploy_app_image_tag" {
  value = var.app_image_tag
}

output "deploy_app_healthcheck_path" {
  value = var.app_healthcheck_path
}

output "deploy_caddy_email" {
  value = var.caddy_email
}

output "deploy_domain_name" {
  value = var.domain_name
}

output "deploy_instance_name" {
  value = var.instance_name
}

output "deploy_region" {
  value = var.aws_region
}

output "deploy_primary_public_ip" {
  value = aws_eip.primary.public_ip
}

output "deploy_secondary_public_ip" {
  value = try(aws_eip.secondary[0].public_ip, "")
}

output "deploy_secondary_enabled" {
  value = var.secondary_instance_enabled
}

output "ssm_parameter_names" {
  value = sort(keys(var.ssm_secure_parameters))
}