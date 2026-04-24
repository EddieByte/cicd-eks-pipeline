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

resource "aws_iam_role" "control_node" {
  name = "ansible-control-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "ansible-control-node-role" })
}

resource "aws_iam_role_policy" "control_node_ssm" {
  name = "control-node-ssm-read"
  role = aws_iam_role.control_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/*"
    }]
  })
}

resource "aws_iam_instance_profile" "control_node" {
  name = "ansible-control-node-profile"
  role = aws_iam_role.control_node.name
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "control_node" {
  name        = "ansible-control-node-sg"
  description = "Ansible Control Node: SSH access only"
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

  tags = merge(var.tags, { Name = "ansible-control-node-sg" })
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "control_node" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.control_node.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.control_node.name

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = templatefile("${path.module}/userdata.sh", {
    aws_region       = var.aws_region
    ssm_ssh_key_path = var.ssm_ssh_key_path
    github_repo      = var.github_repo
    key_name         = var.key_name
  })

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(var.tags, { Name = "Ansible-Control-Node" })
}
