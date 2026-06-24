###############################################################################
# EU-region example — SecureVector engine on AWS ECS Fargate, deployed in the EU
#
# Same shape as ../free-tier, but pinned to an EU region for data residency.
# Every resource this module creates — the Fargate task, the ALB, the EFS volume,
# and the CloudWatch log group — is created in the provider's region, so setting
# an EU region keeps the resident copy of governance/runtime data in-region. Nothing in this
# module replicates data to another region.
#
# Data residency: the engine processes and stores agent/governance data only in
# the AWS account and region you deploy into. SecureVector does not store it. (NOTE: with Cloud Mode on, the engine sends
# prompt text to scan.securevector.io (US) for ML analysis — not stored, but it
# leaves the region; leave Cloud Mode off for strict EU residency. See README.)
# See the module README for the residency posture.
#
# Default region here is eu-west-1 (Ireland). eu-central-1 (Frankfurt) also works
# — just override -var="region=eu-central-1".
#
# Usage:
#   terraform init
#   terraform apply -var="region=eu-west-1" -var="securevector_api_key=$(openssl rand -hex 24)"
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
  type        = string
  default     = "eu-west-1" # Ireland; use eu-central-1 for Frankfurt
  description = "EU AWS region to deploy into. All resources are created here, so this is what governs data residency."
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
