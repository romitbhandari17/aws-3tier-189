variable "name_prefix" {
  description = "Short prefix used to name resources (e.g. everythingaws-dev)"
  type        = string
}

variable "task_execution_role_arn" {
  description = "IAM role ECS uses to pull the image and write logs (from the iam module)"
  type        = string
}

variable "task_role_arn" {
  description = "IAM role the running application code uses (from the iam module)"
  type        = string
}

variable "container_port" {
  description = "Port the Flask app listens on inside the container"
  type        = number
  default     = 5000
}

variable "image_tag" {
  description = "Tag of the image to run, e.g. 'latest' after you docker push it"
  type        = string
  default     = "latest"
}

variable "cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU - smallest/cheapest size)"
  type        = string
  default     = "256"
}

variable "memory" {
  description = "Fargate task memory in MB (512 - smallest/cheapest size)"
  type        = string
  default     = "512"
}

variable "db_host" {
  description = "RDS hostname the app connects to (from the rds module)"
  type        = string
}

variable "db_port" {
  description = "RDS port the app connects to (from the rds module)"
  type        = number
}

variable "db_name" {
  description = "Database name the app connects to (from the rds module)"
  type        = string
}

variable "db_username" {
  description = "Database username the app connects with"
  type        = string
}

variable "db_password" {
  description = "Database password the app connects with"
  type        = string
  sensitive   = true # hides the value from CLI output/logs (still visible in state - demo only)
}
