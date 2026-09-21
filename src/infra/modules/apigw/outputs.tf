# Values other modules/environments might need from this module.

output "invoke_url" {
  description = "Full URL to paste into Postman, e.g. https://xxxx.execute-api.<region>.amazonaws.com/dev/courses/count"
  value       = "${aws_api_gateway_stage.this.invoke_url}/courses/count"
}
