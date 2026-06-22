# Cloud-specific outputs. The runtime/client snippet (output "runtime_snippet")
# lives in the shared runtime.tf. local.base_url is defined in main.tf.

output "dashboard_url" {
  description = "The URL of the SecureVector engine dashboard (ALB DNS; https when certificate_arn is set, else http)."
  value       = local.base_url
}

output "health_url" {
  description = "Load-balancer / uptime health endpoint."
  value       = "${local.base_url}/health"
}

output "alb_dns_name" {
  description = "Raw ALB DNS name — point a CNAME / Route 53 alias here for a custom domain (and the ACM cert)."
  value       = aws_lb.this.dns_name
}

output "service_name" {
  description = "Name of the deployed ECS service."
  value       = aws_ecs_service.this.name
}

output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.this.name
}

output "region" {
  description = "AWS region the service was deployed to (from the provider config)."
  value       = local.region
}

output "persistence_filesystem_id" {
  description = "EFS file system ID backing the audit hash-chain volume (null when persistence is disabled)."
  value       = var.enable_persistence ? aws_efs_file_system.data[0].id : null
}
