terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_vpc" "main" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, { Name = "${var.tags["Project"]}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.tags["Project"]}-igw" })
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = merge(var.tags, { Name = "${var.tags["Project"]}-public-a" })
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.10.2.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true

  tags = merge(var.tags, { Name = "${var.tags["Project"]}-public-b" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.tags["Project"]}-public-rt" })
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
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
  vpc_id             = aws_vpc.main.id
  subnet_id          = aws_subnet.public_a.id
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
  vpc_id             = aws_vpc.main.id
  subnet_id          = aws_subnet.public_b.id
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
  vpc_id                = aws_vpc.main.id
  subnet_id             = aws_subnet.public_a.id
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
  vpc_id            = aws_vpc.main.id
  subnet_id         = aws_subnet.public_b.id
  tags              = var.tags
}
