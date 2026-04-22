variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-central-1"
}

variable "aws_account_id" {
  description = "Your 12-digit AWS account ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "gds-mission-cluster"
}

variable "app_port" {
  description = "Port the Flask app listens on"
  type        = number
  default     = 5000
}
