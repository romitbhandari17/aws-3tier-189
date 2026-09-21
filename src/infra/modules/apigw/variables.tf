# Inputs for the API Gateway module. Kept to the bare minimum for the demo.

variable "api_name" {
  description = "Name of the REST API shown in the AWS console"
  type        = string
}

variable "stage_name" {
  description = "Deployment stage (e.g. dev, prod) - forms part of the invoke URL"
  type        = string
  default     = "dev"
}

variable "backend_url" {
  description = "Full URL of the ECS/ALB backend that GET /courses/count proxies to"
  type        = string
}
