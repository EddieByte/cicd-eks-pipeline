output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "kubeconfig_ssm_parameter" {
  description = "SSM parameter path for the generated kubeconfig generation command"
  value       = aws_ssm_parameter.kubeconfig.name
}
