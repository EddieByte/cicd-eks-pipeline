# ── URLs ──────────────────────────────────────────────────────────────────────

output "jenkins_url" {
  description = "Jenkins UI URL"
  value       = module.master.jenkins_url
}

output "sonarqube_url" {
  description = "SonarQube UI URL"
  value       = module.sonarqube.sonarqube_url
}

# ── SSH Commands ──────────────────────────────────────────────────────────────

output "jenkins_master_ssh" {
  description = "SSH command for Jenkins Master"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.master.public_ip}"
}

output "jenkins_agent_ssh" {
  description = "SSH command for Jenkins Agent"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.agent.public_ip}"
}

output "sonarqube_ssh" {
  description = "SSH command for SonarQube"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.sonarqube.public_ip}"
}

output "control_node_ssh" {
  description = "SSH command for Ansible Control Node"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.control_node.public_ip}"
}

# ── Public IPs ────────────────────────────────────────────────────────────────

output "jenkins_master_public_ip" {
  description = "Jenkins Master public IP"
  value       = module.master.public_ip
}

output "jenkins_agent_public_ip" {
  description = "Jenkins Agent public IP"
  value       = module.agent.public_ip
}

output "sonarqube_public_ip" {
  description = "SonarQube public IP"
  value       = module.sonarqube.public_ip
}

output "control_node_public_ip" {
  description = "Ansible Control Node public IP"
  value       = module.control_node.public_ip
}

# ── Private IPs ───────────────────────────────────────────────────────────────

output "jenkins_master_private_ip" {
  description = "Jenkins Master private IP"
  value       = module.master.private_ip
}

output "jenkins_agent_private_ip" {
  description = "Jenkins Agent private IP — use when registering agent node in Jenkins"
  value       = module.agent.private_ip
}

output "sonarqube_private_ip" {
  description = "SonarQube private IP — use when configuring SonarQube server in Jenkins"
  value       = module.sonarqube.private_ip
}

output "control_node_private_ip" {
  description = "Ansible Control Node private IP — use in infrastructure-config pipeline"
  value       = module.control_node.private_ip
}
