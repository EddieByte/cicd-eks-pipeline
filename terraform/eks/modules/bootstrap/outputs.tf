output "public_ip" {
  value = aws_instance.bootstrap.public_ip
}

output "private_ip" {
  value = aws_instance.bootstrap.private_ip
}

output "instance_id" {
  value = aws_instance.bootstrap.id
}
