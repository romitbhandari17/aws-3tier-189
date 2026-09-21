# Terraform root: wires the modules together for this demo environment.
# All 3 tiers are now connected: API Gateway -> ECS Fargate -> RDS.

locals {
  # Every resource name across all modules is prefixed with this, so
  # everything from this deployment is easy to spot in the AWS console.
  name_prefix = "${var.project_name}-${var.environment}"
}

# Tier 2 IAM: roles the ECS tasks assume.
module "iam" {
  source      = "./modules/iam"
  name_prefix = local.name_prefix
}

# Tier 3: the MySQL database. Built before ECS since the app needs its
# connection details to start up.
module "rds" {
  source      = "./modules/rds"
  name_prefix = local.name_prefix
  db_name     = var.db_name
  db_username = var.db_username
  db_password = var.db_password
}

# Tier 2 compute: Fargate service + ALB, using the IAM roles and DB details above.
module "ecs" {
  source                  = "./modules/ecs"
  name_prefix             = local.name_prefix
  task_execution_role_arn = module.iam.task_execution_role_arn
  task_role_arn           = module.iam.task_role_arn
  db_host                 = module.rds.db_host
  db_port                 = module.rds.db_port
  db_name                 = var.db_name
  db_username             = var.db_username
  db_password             = var.db_password
  image_tag               = var.image_tag
}

# Tier 1: API Gateway proxies GET /courses/count to the ECS/ALB backend.
module "apigw" {
  source      = "./modules/apigw"
  api_name    = "${local.name_prefix}-courses-api"
  backend_url = "http://${module.ecs.alb_dns_name}/courses/count"
}
