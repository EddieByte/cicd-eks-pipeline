terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "cluster" {
  source = "./modules/cluster"

  aws_region         = var.aws_region
  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  instance_type      = var.instance_type
  node_min           = var.node_min
  node_max           = var.node_max
  node_desired       = var.node_desired
  tags               = var.tags
}

module "bootstrap" {
  source     = "./modules/bootstrap"
  depends_on = [module.cluster]

  aws_region        = var.aws_region
  ami_id            = var.ami_id
  instance_type     = var.instance_type
  volume_size       = var.volume_size
  key_name          = var.key_name
  allowed_ssh_cidrs = var.allowed_ssh_cidrs
  ssm_ssh_key_path  = var.ssm_ssh_key_path
  tags              = var.tags
}
