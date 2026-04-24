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
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
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

# ── Copy inventory to control node and run playbooks ─────────────────────────

resource "null_resource" "run_ansible" {
  depends_on = [module.control_node, local_file.ansible_inventory]

  triggers = {
    master_id    = module.master.instance_id
    agent_id     = module.agent.instance_id
    sonarqube_id = module.sonarqube.instance_id
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = <<-EOT
      Write-Host "Waiting for control node to finish booting..."
      Start-Sleep -Seconds 90

      # Ensure inventory directory exists on control node
      ssh -o StrictHostKeyChecking=no `
          -i "$env:USERPROFILE\.ssh\${var.key_name}.pem" `
          ubuntu@${module.control_node.public_ip} `
          'mkdir -p /home/ubuntu/cicd-eks-pipeline/ansible/inventory'

      # Copy generated inventory to control node
      scp -o StrictHostKeyChecking=no `
          -i "$env:USERPROFILE\.ssh\${var.key_name}.pem" `
          "${path.module}/../../ansible/inventory/hosts.ini" `
          "ubuntu@${module.control_node.public_ip}:/home/ubuntu/cicd-eks-pipeline/ansible/inventory/hosts.ini"

      # Run playbooks in order on the control node
      ssh -o StrictHostKeyChecking=no `
          -i "$env:USERPROFILE\.ssh\${var.key_name}.pem" `
          ubuntu@${module.control_node.public_ip} `
          'cd /home/ubuntu/cicd-eks-pipeline/ansible && ansible-playbook -i inventory/hosts.ini --private-key ~/.ssh/${var.key_name}.pem playbooks/master.yml && ansible-playbook -i inventory/hosts.ini --private-key ~/.ssh/${var.key_name}.pem playbooks/agent.yml && ansible-playbook -i inventory/hosts.ini --private-key ~/.ssh/${var.key_name}.pem playbooks/sonarqube.yml'
    EOT
  }
}
