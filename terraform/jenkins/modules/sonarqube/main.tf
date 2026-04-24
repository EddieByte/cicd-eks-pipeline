# ── Default VPC + Subnet ──────────────────────────────────────────────────────

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ── IAM Role ──────────────────────────────────────────────────────────────────

resource "aws_iam_role" "sonarqube" {
  name = "sonarqube-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "sonarqube-role" })
}

resource "aws_iam_role_policy" "sonarqube_ssm" {
  name = "sonarqube-ssm-read"
  role = aws_iam_role.sonarqube.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameter"]
      Resource = [
        "arn:aws:ssm:${var.aws_region}:*:parameter${var.sonar_db_username_ssm}",
        "arn:aws:ssm:${var.aws_region}:*:parameter${var.sonar_db_password_ssm}"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "sonarqube" {
  name = "sonarqube-profile"
  role = aws_iam_role.sonarqube.name
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "sonarqube" {
  name        = "sonarqube-sg"
  description = "SonarQube: SSH and web UI access"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  ingress {
    description = "SonarQube Web UI"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # NOTE: restrict to known CIDRs in production
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sonarqube-sg" })
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "sonarqube" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.sonarqube.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.sonarqube.name

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = file("${path.module}/userdata.sh")

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(var.tags, { Name = "SonarQube" })
}
