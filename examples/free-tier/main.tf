###############################################################################
# "Try it" example — SecureVector engine on AWS ECS Fargate
#
# Cheapest credible SecureVector engine on AWS:
#   - 1 always-on Fargate task (.5 vCPU / 1 GiB) behind a public ALB
#   - EFS persistence on, public HTTP endpoint
#   - deploys into the account's DEFAULT VPC + its public subnets (no VPC to manage)
#   - emits a wired LangChain snippet on apply
#
# NOTE: unlike Cloud Run, Fargate has no scale-to-zero, and an ALB bills ~hourly,
# so this is NOT free at idle — budget a few dollars/month. `terraform destroy`
# tears everything down cleanly.
#
# Usage:
#   terraform init
#   terraform apply -var="region=us-east-1" -var="securevector_api_key=$(openssl rand -hex 24)"
#   terraform output -raw runtime_snippet
#   terraform destroy
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "securevector_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

provider "aws" {
  region = var.region
}

module "securevector" {
  source = "../../"

  name                 = "securevector"
  securevector_runtime = "langchain" # emits a wired client snippet

  # Cheapest trial posture: one task, default VPC/subnets, public HTTP.
  min_instances        = 1
  max_instances        = 1
  securevector_api_key = var.securevector_api_key
}

output "dashboard_url" {
  value = module.securevector.dashboard_url
}

output "runtime_snippet" {
  value = module.securevector.runtime_snippet
}
