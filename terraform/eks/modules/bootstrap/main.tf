# ── IAM Role ──────────────────────────────────────────────────────────────────

resource "aws_iam_role" "bootstrap" {
  name = "eks-bootstrap-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "eks-bootstrap-role" })
}

# NOTE: Permissions are intentionally broad for a CI bootstrap server.
# Restrict to specific actions before using in production.
resource "aws_iam_role_policy" "bootstrap_permissions" {
  name = "eks-bootstrap-permissions"
  role = aws_iam_role.bootstrap.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "ec2:DescribeInstances",
          "ec2:DescribeRegions",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeSecurityGroups",
          "autoscaling:DescribeAutoScalingGroups"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "bootstrap" {
  name = "eks-bootstrap-profile"
  role = aws_iam_role.bootstrap.name
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "bootstrap" {
  name        = "eks-bootstrap-sg"
  description = "EKS Bootstrap Node: SSH access only"
  vpc_id      = var.vpc_id

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

  tags = merge(var.tags, { Name = "eks-bootstrap-sg" })
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "bootstrap" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.public_subnet_ids[0]
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.bootstrap.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.bootstrap.name

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = templatefile("${path.module}/userdata.sh", {
    aws_region       = var.aws_region
    ssm_ssh_key_path = var.ssm_ssh_key_path
    key_name         = var.key_name
  })

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(var.tags, { Name = "EKS-Bootstrap" })
}
