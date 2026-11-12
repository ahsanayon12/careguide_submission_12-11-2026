output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "github_actions_role_arn" {
  description = "Store as GitHub secret AWS_GITHUB_ROLE_ARN"
  value       = aws_iam_role.github_actions.arn
}
