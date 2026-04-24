variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "ami_id" {
  description = "Ubuntu 22.04 LTS AMI ID"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}

variable "volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH"
  type        = list(string)
}

variable "ssm_parameter_name" {
  description = "SSM parameter path for the Jenkins master public key"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
}
