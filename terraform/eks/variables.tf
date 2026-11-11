variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "ami_id" {
  description = "Ubuntu 22.04 LTS AMI ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "eddie-register-app-eks"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.32"
}

variable "instance_type" {
  description = "EC2 instance type for EKS nodes and bootstrap"
  type        = string
  default     = "t3.medium"
}

variable "volume_size" {
  description = "Root EBS volume size in GB for Bootstrap node"
  type        = number
  default     = 20
}

variable "node_min" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

variable "node_desired" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
  default     = "labs_kp"
}

variable "ssm_ssh_key_path" {
  description = "SSM parameter path for the labs_kp private key"
  type        = string
  default     = "/jenkins/ssh-private-key"
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "eddie-register-app"
    Environment = "Prod"
    ManagedBy   = "Terraform"
  }
}

# -- Database (RDS PostgreSQL) -------------------------------------------------

variable "db_identifier" {
  description = "Name of the RDS instance"
  type        = string
  default     = "register-app-db"
}

variable "db_name" {
  description = "Database created inside PostgreSQL for the app"
  type        = string
  default     = "registerapp"
}

variable "db_username" {
  description = "Master user the app connects as"
  type        = string
  default     = "registerapp_admin"
}

variable "db_instance_class" {
  description = "RDS instance size (db.t4g.micro is the smallest, roughly USD 0.02/hour)"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"
}

variable "db_password_ssm" {
  description = "SSM SecureString holding the database password (created by scripts/setup-secrets.ps1)"
  type        = string
  default     = "/app/db-password"
}
