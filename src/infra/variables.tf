# Inputs for the dev environment. Values are supplied via dev.tfvars.

variable "project_name" {
  description = "Short project name used as a prefix on every resource (e.g. everythingaws)"
  type        = string
}

variable "environment" {
  description = "Environment name used as part of the resource prefix (e.g. dev, prod)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy the demo into"
  type        = string
  default     = "us-east-1"
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
}

variable "db_name" {
  description = "Name of the initial database created inside the RDS instance"
  type        = string
  default     = "aws_internal_199_db" # a simple name for the demo database
}

variable "db_password" {
  description = "Master password for the RDS instance (set this in dev.tfvars, not committed with a real value)"
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = "Tag of the ECS app image to deploy (e.g. a git short-sha). Changing this forces a new ECS deployment via terraform apply. See deploy.sh."
  type        = string
  default     = "latest"
}
