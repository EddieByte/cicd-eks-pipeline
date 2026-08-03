output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.cluster.cluster_endpoint
}

output "bootstrap_public_ip" {
  description = "Bootstrap server public IP"
  value       = module.bootstrap.public_ip
}

output "bootstrap_ssh_command" {
  description = "SSH command to access the Bootstrap server"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.bootstrap.public_ip}"
}

output "kubeconfig_ssm_parameter" {
  description = "SSM parameter path containing the kubeconfig generation command"
  value       = module.cluster.kubeconfig_ssm_parameter
}
