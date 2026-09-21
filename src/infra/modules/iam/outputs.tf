output "task_execution_role_arn" {
  description = "Role ECS uses to pull the image and write logs"
  value       = aws_iam_role.task_execution.arn
}

output "task_role_arn" {
  description = "Role the running application code uses"
  value       = aws_iam_role.task.arn
}
