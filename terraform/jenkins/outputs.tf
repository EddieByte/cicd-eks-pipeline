output "jenkins_url" {
  description = "Jenkins UI URL"
  value       = module.master.jenkins_url
}

output "sonarqube_url" {
  description = "SonarQube UI URL"
  value       = module.sonarqube.sonarqube_url
}

# ── Jenkins Master ────────────────────────────────────────────────────────────

output "jenkins_master_public_ip" {
  value = module.master.public_ip
}

output "jenkins_master_private_ip" {
  value = module.master.private_ip
}

output "jenkins_master_ssh" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.master.public_ip}"
}

# ── Jenkins Agent ─────────────────────────────────────────────────────────────

output "jenkins_agent_public_ip" {
  value = module.agent.public_ip
}

output "jenkins_agent_private_ip" {
  value = module.agent.private_ip
}

output "jenkins_agent_ssh" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.agent.public_ip}"
}

# ── SonarQube ─────────────────────────────────────────────────────────────────

output "sonarqube_public_ip" {
  value = module.sonarqube.public_ip
}

output "sonarqube_private_ip" {
  value = module.sonarqube.private_ip
}

output "sonarqube_ssh" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.sonarqube.public_ip}"
}

# ── Ansible Control Node ──────────────────────────────────────────────────────

output "control_node_public_ip" {
  value = module.control_node.public_ip
}

output "control_node_private_ip" {
  value = module.control_node.private_ip
}

output "control_node_ssh" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.control_node.public_ip}"
}
