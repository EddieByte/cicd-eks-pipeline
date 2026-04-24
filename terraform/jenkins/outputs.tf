output "jenkins_url" {
  description = "Jenkins UI URL"
  value       = module.master.jenkins_url
}

output "jenkins_master_public_ip" {
  description = "Jenkins Master public IP"
  value       = module.master.public_ip
}

output "jenkins_master_private_ip" {
  description = "Jenkins Master private IP"
  value       = module.master.private_ip
}

output "jenkins_master_instance_id" {
  description = "Jenkins Master instance ID"
  value       = module.master.instance_id
}

output "jenkins_agent_public_ip" {
  description = "Jenkins Agent public IP"
  value       = module.agent.public_ip
}

output "jenkins_agent_private_ip" {
  description = "Jenkins Agent private IP — use this when registering the node in Jenkins dashboard"
  value       = module.agent.private_ip
}

output "jenkins_agent_instance_id" {
  description = "Jenkins Agent instance ID"
  value       = module.agent.instance_id
}

output "agent_setup_step_1" {
  description = "Get master public key — paste into agent authorized_keys if SSM fails"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.master.public_ip} 'sudo cat /var/lib/jenkins/.ssh/id_rsa.pub'"
}

output "agent_setup_step_2" {
  description = "Get master private key — add to Jenkins credential store"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.master.public_ip} 'sudo cat /var/lib/jenkins/.ssh/id_rsa'"
}

output "sonarqube_url" {
  description = "SonarQube UI URL"
  value       = module.sonarqube.sonarqube_url
}

output "sonarqube_public_ip" {
  description = "SonarQube public IP"
  value       = module.sonarqube.public_ip
}

output "sonarqube_private_ip" {
  description = "SonarQube private IP"
  value       = module.sonarqube.private_ip
}

output "sonarqube_instance_id" {
  description = "SonarQube instance ID"
  value       = module.sonarqube.instance_id
}

output "control_node_public_ip" {
  description = "Ansible Control Node public IP"
  value       = module.control_node.public_ip
}

output "control_node_instance_id" {
  description = "Ansible Control Node instance ID"
  value       = module.control_node.instance_id
}

output "control_node_ssh" {
  description = "SSH command to access the Ansible Control Node"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.control_node.public_ip}"
}
