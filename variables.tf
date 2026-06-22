###############################################################################
# Placement & naming
#
# NOTE: the AWS region comes from the AWS provider configuration (provider "aws"
# { region = ... }), not a module variable — that's the AWS idiom. The module
# reads the active region for log config / outputs via a data source.
###############################################################################

variable "name" {
  description = "Base name for the ECS cluster/service, ALB, target group, EFS, and IAM roles. Lowercase, alphanumeric + hyphens. Keep <= 32 chars (the ALB name limit)."
  type        = string
  default     = "securevector"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name)) && length(var.name) <= 32
    error_message = "name must be lowercase, start with a letter, contain only letters/digits/hyphens, and be <= 32 chars (ALB limit)."
  }
}

variable "tags" {
  description = "Tags applied to all created AWS resources."
  type        = map(string)
  default     = {}
}

###############################################################################
# Networking — defaults to the account's default VPC + its public subnets
###############################################################################

variable "vpc_id" {
  description = "VPC to deploy into. Empty = use the account's default VPC. For a custom VPC, also set subnet_ids to PUBLIC subnets (the ALB and Fargate tasks need internet routing for image pull)."
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "Public subnet IDs (>= 2 AZs) for the ALB, Fargate tasks, and EFS mount targets. Empty = all subnets of the default VPC (which are public). For a custom VPC you MUST supply public subnets here."
  type        = list(string)
  default     = []
}

variable "assign_public_ip" {
  description = "Assign a public IP to Fargate tasks. Required (true) when running in public subnets with no NAT gateway, so the task can pull the image and reach the SecureVector cloud. Set false only if you provide private subnets with a NAT route."
  type        = bool
  default     = true
}

###############################################################################
# Container image
###############################################################################

variable "image" {
  description = "Container image for the SecureVector engine. Defaults to the public ghcr.io image published from securevector-ai-threat-monitor. Pin to a version tag for production."
  type        = string
  default     = "ghcr.io/secure-vector/securevector-ai-threat-monitor:latest"
}

variable "container_port" {
  description = "Port the engine listens on inside the container. The ALB routes HTTP traffic to this port. The image/command must bind this port on 0.0.0.0."
  type        = number
  default     = 8741

  validation {
    condition     = var.container_port >= 1 && var.container_port <= 65535
    error_message = "container_port must be between 1 and 65535."
  }
}

variable "container_command" {
  description = "Override the container entrypoint. Empty (default) defers to the image ENTRYPOINT. The app takes host/port as CLI args (NOT env), so a working override looks like [\"securevector-app\", \"--web\", \"--host\", \"0.0.0.0\", \"--port\", \"8741\"]. (Enrollment from SECUREVECTOR_ENROLL_TOKEN must be handled by the image entrypoint, not this command.)"
  type        = list(string)
  default     = []
}

variable "cpu_architecture" {
  description = "Fargate CPU architecture: X86_64 or ARM64 (Graviton — cheaper). The image must be multi-arch or match."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "container_uid" {
  description = "POSIX uid the engine runs as inside the image (HOME=/home/securevector). Used by the EFS access point so the non-root user can write the audit chain. MUST match the user baked into the published image."
  type        = number
  default     = 1000
}

variable "container_gid" {
  description = "POSIX gid the engine runs as inside the image. Used by the EFS access point. MUST match the published image."
  type        = number
  default     = 1000
}

###############################################################################
# Scaling & resources
#
# Unlike Cloud Run, ECS Fargate has no true scale-to-zero — min_instances is the
# always-on task count (default 1). Set max_instances > min_instances to enable
# CPU-target autoscaling between the two.
###############################################################################

variable "cpu" {
  description = "Fargate task CPU units (256 = .25 vCPU, 512 = .5, 1024 = 1 vCPU ...). Must form a valid Fargate cpu/memory combo. Default 512 (.5 vCPU) gives the Guardian ML model headroom."
  type        = string
  default     = "512"
}

variable "memory" {
  description = "Fargate task memory in MiB (must pair with cpu per Fargate's valid combos). Default 1024 (1 GiB)."
  type        = string
  default     = "1024"
}

variable "min_instances" {
  description = "Always-on task count (ECS desired_count). >= 1 to keep the endpoint reachable (Fargate has no scale-to-zero). Also the autoscaling floor."
  type        = number
  default     = 1

  validation {
    condition     = var.min_instances >= 0
    error_message = "min_instances must be >= 0."
  }
}

variable "max_instances" {
  description = "Autoscaling ceiling. When > min_instances, a CPU target-tracking policy scales the service between min and max. Equal to min_instances disables autoscaling."
  type        = number
  default     = 2

  validation {
    condition     = var.max_instances >= 1
    error_message = "max_instances must be >= 1."
  }
}

variable "autoscale_cpu_target" {
  description = "Target average CPU utilization (%) for the autoscaling policy (only used when max_instances > min_instances)."
  type        = number
  default     = 70
}

###############################################################################
# Access & auth
#
# Two independent layers:
#   - ingress_token  -> SECUREVECTOR_INGRESS_TOKEN: APP-LAYER inbound gate. When
#     set, the engine requires the credential on every request (Authorization:
#     Bearer or X-Api-Key); /health stays open. Validated by the ingress_auth
#     middleware in securevector-ai-threat-monitor (pending release).
#   - allow_unauthenticated / ingress_cidrs -> ALB security group: NETWORK-LAYER
#     gate (who can reach the load balancer at all).
# Use either or both. securevector_api_key below is the engine's OUTBOUND cloud
# key, NOT an inbound gate — don't confuse the two.
###############################################################################

variable "allow_unauthenticated" {
  description = "Open the ALB to the public internet (0.0.0.0/0). Pair with ingress_token for app-layer auth. Set FALSE to restrict network access to var.ingress_cidrs only."
  type        = bool
  default     = true
}

variable "ingress_cidrs" {
  description = "CIDR blocks allowed to reach the ALB when allow_unauthenticated = false (e.g. your office/VPN range). Ignored when allow_unauthenticated = true (which opens 0.0.0.0/0). Empty list + allow_unauthenticated = false = nothing reachable."
  type        = list(string)
  default     = []
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS. When set, the module adds a 443 HTTPS listener (TLS1.3 policy) and redirects 80 -> 443. Empty = HTTP-only on port 80 (fine for a trial / behind a VPN; not for internet-facing prod). Requires a DNS name you control pointed at the ALB."
  type        = string
  default     = ""
}

variable "ingress_token" {
  description = "App-layer inbound credential -> SECUREVECTOR_INGRESS_TOKEN. When set, the engine requires it on every request (Authorization: Bearer <token> or X-Api-Key: <token>); /health stays open for the ALB probe. Header-capable clients (OpenClaw, curl) can pass it today; SDK/JS-hook client-side forwarding is rolling out (#182). Empty = no app-layer gate (rely on ingress_cidrs)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "securevector_api_key" {
  description = "OUTBOUND cloud credential: a personal API key (svpk_* / legacy) the engine presents to the SecureVector cloud (sent as X-Api-Key by cloud_sync) for personal cloud mode / enhanced detection. This is NOT an inbound gate and does not protect /analyze. Empty = no cloud key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "securevector_api_url" {
  description = "Optional override for the SecureVector cloud API base URL (SECUREVECTOR_API_URL). Empty = the app's built-in default."
  type        = string
  default     = ""
}

###############################################################################
# Cloud Connect bridge (optional) — turns this self-hosted node into a member
# of the SecureVector managed fleet (the OSS-self-host -> paid Pro/Enterprise
# on-ramp). Leave empty to stay fully self-hosted.
###############################################################################

variable "cloud_connect_token" {
  description = "Optional svet_* org ENROLLMENT token (passed as SECUREVECTOR_ENROLL_TOKEN). Enrolls the node into the org FLEET view AND receives signed policy bundles (Policy Sync ON). NOTE: only the svet_* enroll path enables policy sync; a personal key (svpk_*) goes in securevector_api_key instead. Requires the image entrypoint to run `securevector-app enroll` before serving (see README / #182). Empty = pure self-host, no enrollment."
  type        = string
  default     = ""
  sensitive   = true
}

# NOTE: variable "securevector_runtime" lives in the shared runtime.tf (kept
# identical across all terraform-<cloud>-securevector repos).

###############################################################################
# Persistence — durable audit hash-chain. v1 = SQLite on an EFS-backed volume.
###############################################################################

variable "enable_persistence" {
  description = "Mount an EFS-backed volume at persistence_mount_path so the audit hash-chain survives task restarts. Disable for a stateless throwaway trial."
  type        = bool
  default     = true
}

variable "persistence_mount_path" {
  description = "Path the persistence volume mounts at inside the container. The app has NO data-dir env override — it stores its SQLite DB / audit chain at $HOME/.local/share/securevector/threat-monitor — so this MUST match that path in the published image. Default assumes HOME=/home/securevector."
  type        = string
  default     = "/home/securevector/.local/share/securevector/threat-monitor"
}

###############################################################################
# Operational toggles
###############################################################################

variable "deletion_protection" {
  description = "ALB deletion protection. Default false so `terraform destroy` works for trials; set true to protect a production load balancer."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the engine container logs (/ecs/<name>)."
  type        = number
  default     = 30
}

variable "container_insights" {
  description = "Enable ECS Container Insights on the cluster (extra CloudWatch cost). Off by default."
  type        = bool
  default     = false
}

variable "enable_execute_command" {
  description = "Enable ECS Exec (`aws ecs execute-command`) for shell access into the running task — useful for debugging the engine. Off by default."
  type        = bool
  default     = false
}

variable "extra_env" {
  description = "Additional environment variables to pass to the engine container (advanced / forward-compat with future server-mode flags)."
  type        = map(string)
  default     = {}
}
