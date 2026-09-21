# Expose the module output at the environment level so `terraform output`
# from src/infra/envs/dev shows the Postman-ready URL directly.

output "courses_count_invoke_url" {
  description = "Paste this URL into Postman as a GET request"
  value       = module.apigw.invoke_url
}

output "ecr_repository_url" {
  description = "Build & push your image here (see src/ecs) before ECS can serve traffic"
  value       = module.ecs.ecr_repository_url
}

output "db_host" {
  description = "RDS endpoint (for reference/troubleshooting - the app connects to it directly)"
  value       = module.rds.db_host
}
