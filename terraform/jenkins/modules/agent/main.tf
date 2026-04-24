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

resource "aws_iam_role" "jenkins_agent" {
  name = "jenkins-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "jenkins-agent-role" })
}

resource "aws_iam_role_policy" "jenkins_agent_ssm" {
  name = "jenkins-agent-ssm-read"
  role = aws_iam_role.jenkins_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/jenkins/*"
    }]
  })
}

resource "aws_iam_instance_profile" "jenkins_agent" {
  name = "jenkins-agent-profile"
  role = aws_iam_role.jenkins_agent.name
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "jenkins_agent" {
  name        = "jenkins-agent-sg"
  description = "Jenkins Agent: SSH access"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "jenkins-agent-sg" })
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "jenkins_agent" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.jenkins_agent.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.jenkins_agent.name

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

  tags = merge(var.tags, { Name = "Jenkins-Agent" })
}
