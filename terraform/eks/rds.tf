# -- Amazon RDS PostgreSQL for the register app --------------------------------
#
# A small private PostgreSQL instance in the EKS VPC. Only the private subnets
# (where the worker nodes and app pods live) can reach it on port 5432.
#
# The password is read from SSM (/app/db-password, created by
# scripts/setup-secrets.ps1) so it never appears in Git or tfvars.
# Note: Terraform still records it in the state file, which is why the state
# lives in the encrypted, private S3 bucket.
#
# Lab settings: no final snapshot and no deletion protection, so
# "terraform destroy" removes the database (and its data) cleanly.

data "aws_ssm_parameter" "db_password" {
  name            = var.db_password_ssm
  with_decryption = true
}

resource "aws_db_subnet_group" "app" {
  name        = "${var.db_identifier}-subnets"
  description = "Private subnets for the register app database"
  subnet_ids  = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = merge(var.tags, { Name = "${var.db_identifier}-subnets" })
}

resource "aws_security_group" "rds" {
  name        = "${var.db_identifier}-sg"
  description = "PostgreSQL access from the EKS private subnets only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "PostgreSQL from worker nodes and pods (VPC CNI gives pods private-subnet IPs)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.private_a.cidr_block, aws_subnet.private_b.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.db_identifier}-sg" })
}

resource "aws_db_instance" "app" {
  identifier     = var.db_identifier
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = data.aws_ssm_parameter.db_password.value
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.app.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  apply_immediately          = true

  # Lab: destroy cleanly. For production set deletion_protection = true and keep a final snapshot.
  skip_final_snapshot = true
  deletion_protection = false

  tags = merge(var.tags, { Name = var.db_identifier })
}

output "db_endpoint" {
  description = "Hostname of the RDS PostgreSQL instance"
  value       = aws_db_instance.app.address
}

output "db_port" {
  description = "Port of the RDS PostgreSQL instance"
  value       = aws_db_instance.app.port
}

output "db_name" {
  description = "Database name used by the app"
  value       = aws_db_instance.app.db_name
}

output "db_username" {
  description = "Database user the app connects as"
  value       = aws_db_instance.app.username
}
