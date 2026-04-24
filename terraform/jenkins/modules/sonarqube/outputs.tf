output "public_ip" {
  value = aws_instance.sonarqube.public_ip
}

output "private_ip" {
  value = aws_instance.sonarqube.private_ip
}

output "instance_id" {
  value = aws_instance.sonarqube.id
}

output "sonarqube_url" {
  value = "http://${aws_instance.sonarqube.public_ip}:9000"
}
