variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "environment" {
  type        = string
  description = "Deployment environment name"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "instance_type" {
  type    = string
  default = "t3.micro" # Free Tier eligible
}

variable "architecture" {
  type        = string
  description = "AMI architecture; must match instance_type (x86_64 for t3, arm64 for t4g)"
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be x86_64 or arm64."
  }
}

variable "root_volume_size" {
  type    = number
  default = 16
}

variable "detailed_monitoring" {
  type    = bool
  default = false
}

variable "allowed_http_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach port 80"
  default     = ["0.0.0.0/0"]
}

variable "ecr_repository_name" {
  type    = string
  default = "careguide-api"
}

variable "image_tag" {
  type        = string
  description = "Image tag deployed at first boot. Later releases are rolled out by CI via SSM."
  default     = "1.0.0"
}

variable "log_retention_days" {
  type    = number
  default = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch-supported retention value."
  }
}
