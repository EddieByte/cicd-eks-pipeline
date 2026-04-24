variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "ami_id" {
  description = "Ubuntu 22.04 LTS AMI ID"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 15
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
  default     = "labs_kp"
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssm_parameter_name" {
  description = "SSM parameter path for the Jenkins master public key"
  type        = string
  default     = "/jenkins/master-public-key"
}

variable "sonar_db_username_ssm" {
  description = "SSM parameter path for SonarQube DB username"
  type        = string
  default     = "/sonarqube/db-username"
}

variable "sonar_db_password_ssm" {
  description = "SSM parameter path for SonarQube DB password"
  type        = string
  default     = "/sonarqube/db-password"
}

variable "control_node_instance_type" {
  description = "EC2 instance type for the Ansible control node"
  type        = string
  default     = "t3.micro"
}

variable "ssm_ssh_key_path" {
  description = "SSM parameter path for the labs_kp private key"
  type        = string
  default     = "/jenkins/ssh-private-key"
}

variable "github_repo" {
  description = "GitHub repo URL to clone playbooks from"
  type        = string
  default     = "https://github.com/EddieByte/cicd-eks-pipeline"
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "DevPulse"
    Environment = "CI"
    ManagedBy   = "Terraform"
  }
}
