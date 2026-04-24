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

resource "aws_iam_role" "jenkins_master" {
  name = "jenkins-master-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "jenkins-master-role" })
}

resource "aws_iam_role_policy" "jenkins_master_ssm" {
  name = "jenkins-master-ssm-write"
  role = aws_iam_role.jenkins_master.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:PutParameter", "ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/jenkins/*"
    }]
  })
}

resource "aws_iam_instance_profile" "jenkins_master" {
  name = "jenkins-master-profile"
  role = aws_iam_role.jenkins_master.name
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "jenkins_master" {
  name        = "jenkins-master-sg"
  description = "Jenkins Master: SSH and web UI access"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  ingress {
    description = "Jenkins Web UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "jenkins-master-sg" })
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "jenkins_master" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.jenkins_master.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.jenkins_master.name

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = templatefile("${path.module}/userdata.sh", {
    ssm_parameter_name = var.ssm_parameter_name
  })

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(var.tags, { Name = "Jenkins-Master" })
}
