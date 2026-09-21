output "alb_dns_name" {
  description = "Public ALB DNS name - API Gateway proxies requests here"
  value       = aws_lb.app.dns_name
}

output "ecr_repository_url" {
  description = "Push your built image here before the service can serve traffic"
  value       = aws_ecr_repository.app.repository_url
}
