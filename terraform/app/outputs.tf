output "instance_id" {
  value = aws_instance.app.id
}

output "public_ip" {
  value = aws_instance.app.public_ip
}

output "app_url" {
  value = "http://${aws_instance.app.public_dns}"
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}

output "ssm_session_command" {
  description = "Shell access without SSH"
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
}
