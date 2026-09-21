output "db_host" {
  description = "Hostname the app connects to (without the port)"
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "Port MySQL listens on"
  value       = aws_db_instance.this.port
}
