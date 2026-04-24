[jenkins_master]
${master_ip} ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/${key_name}.pem ansible_ssh_common_args='-o StrictHostKeyChecking=no'

[jenkins_agent]
${agent_ip} ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/${key_name}.pem ansible_ssh_common_args='-o StrictHostKeyChecking=no'

[sonarqube]
${sonarqube_ip} ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/${key_name}.pem ansible_ssh_common_args='-o StrictHostKeyChecking=no'
