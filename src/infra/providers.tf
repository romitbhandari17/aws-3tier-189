# AWS provider setup for the dev environment.
# The region comes from a variable so it's easy to change per environment.

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

  # Tags every resource this provider creates, so actual spend can be
  # isolated in Cost Explorer / Cost & Usage Reports (see docs/COSTS.md).
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
