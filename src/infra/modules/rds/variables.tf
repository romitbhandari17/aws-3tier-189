variable "name_prefix" {
  description = "Short prefix used to name resources (e.g. everythingaws-dev)"
  type        = string
}

variable "db_name" {
  description = "Name of the initial database created inside the RDS instance"
  type        = string
  default     = "everythingaws"
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
}

variable "db_password" {
  description = "Master password for the RDS instance (kept out of version control via dev.tfvars, which is gitignored)"
  type        = string
  sensitive   = true # hides the value from CLI output/logs (still visible in state - demo only)
}

variable "instance_class" {
  description = "RDS instance size - db.t3.micro is the smallest/cheapest, fine for a demo"
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Storage size in GB for the RDS instance"
  type        = number
  default     = 20
}
