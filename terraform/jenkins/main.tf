terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "master" {
  source = "./modules/master"

  aws_region         = var.aws_region
  ami_id             = var.ami_id
  instance_type      = var.instance_type
  volume_size        = var.volume_size
  key_name           = var.key_name
  allowed_ssh_cidrs  = var.allowed_ssh_cidrs
  ssm_parameter_name = var.ssm_parameter_name
  tags               = var.tags
}

module "agent" {
  source     = "./modules/agent"
  depends_on = [module.master]

  aws_region         = var.aws_region
  ami_id             = var.ami_id
  instance_type      = var.instance_type
  volume_size        = var.volume_size
  key_name           = var.key_name
  allowed_ssh_cidrs  = var.allowed_ssh_cidrs
  ssm_parameter_name = var.ssm_parameter_name
  tags               = var.tags
}

module "sonarqube" {
  source = "./modules/sonarqube"

  aws_region            = var.aws_region
  ami_id                = var.ami_id
  instance_type         = var.instance_type
  volume_size           = var.volume_size
  key_name              = var.key_name
  allowed_ssh_cidrs     = var.allowed_ssh_cidrs
  sonar_db_username_ssm = var.sonar_db_username_ssm
  sonar_db_password_ssm = var.sonar_db_password_ssm
  tags                  = var.tags
}

module "control_node" {
  source     = "./modules/control_node"
  depends_on = [module.master, module.agent, module.sonarqube]

  aws_region        = var.aws_region
  ami_id            = var.ami_id
  instance_type     = var.control_node_instance_type
  volume_size       = var.volume_size
  key_name          = var.key_name
  allowed_ssh_cidrs = var.allowed_ssh_cidrs
  ssm_ssh_key_path  = var.ssm_ssh_key_path
  github_repo       = var.github_repo
  tags              = var.tags
}

# ── Ansible Inventory ─────────────────────────────────────────────────────────

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/inventory.tpl", {
    master_ip    = module.master.public_ip
    agent_ip     = module.agent.public_ip
    sonarqube_ip = module.sonarqube.public_ip
    key_name     = var.key_name
  })
  filename = "${path.module}/../../ansible/inventory/hosts.ini"
}
