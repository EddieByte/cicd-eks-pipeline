output "public_ip" {
  value = aws_instance.jenkins_agent.public_ip
}

output "private_ip" {
  value = aws_instance.jenkins_agent.private_ip
}

output "instance_id" {
  value = aws_instance.jenkins_agent.id
}
