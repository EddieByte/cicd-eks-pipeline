variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for EKS nodes"
  type        = string
}

variable "node_min" {
  description = "Minimum number of worker nodes"
  type        = number
}

variable "node_max" {
  description = "Maximum number of worker nodes"
  type        = number
}

variable "node_desired" {
  description = "Desired number of worker nodes"
  type        = number
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
}
