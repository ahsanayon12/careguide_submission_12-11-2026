variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "ecr_repository_name" {
  type    = string
  default = "careguide-api"
}

variable "github_repository" {
  type        = string
  description = "GitHub repository allowed to assume the CI role, in owner/name form"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/repo."
  }
}
