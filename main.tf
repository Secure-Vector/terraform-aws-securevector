###############################################################################
# SecureVector engine on AWS ECS Fargate
#
# One `terraform apply` stands up the SecureVector threat-monitor engine in YOUR
# AWS account: an ECS Fargate service behind an Application Load Balancer
# (public HTTPS DNS), with an optional EFS-backed persistence volume for the
# tamper-evident audit chain.
#
# Why Fargate + EFS + ALB (not App Runner): App Runner gives a managed HTTPS URL
# but has NO durable volume, and the engine's default posture keeps a persistent
# audit hash-chain (enable_persistence = true). Fargate + EFS is the faithful
# AWS analog of GCP Cloud Run + a GCS-backed volume; the ALB supplies the stable
# public endpoint (HTTP by default, HTTPS when certificate_arn is set).
###############################################################################

data "aws_region" "current" {}

# Default VPC / subnets are used only when the caller does not pass their own.
# The default VPC's subnets are public (have an IGW route), which is what the
# public ALB + Fargate (assign_public_ip) need. For a custom VPC, pass
# public subnet_ids explicitly.
data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = length(var.subnet_ids) == 0 ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

locals {
  vpc_id     = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id
  subnet_ids = length(var.subnet_ids) > 0 ? var.subnet_ids : data.aws_subnets.default[0].ids

  # `.region` exists on AWS provider 6.x; `.name` is the (now-deprecated) 5.x
  # attribute. try() picks the right one so the module is warning-free on 6.x
  # and still works on 5.x.
  region = try(data.aws_region.current.region, data.aws_region.current.name)

  # Cloud-specific: the deployed engine's HTTPS URL. The shared runtime.tf
  # consumes this local — every cloud module must define local.base_url. ALB
  # gives a DNS name; scheme is HTTPS only when a cert is attached.
  base_url = "${var.certificate_arn != "" ? "https" : "http"}://${aws_lb.this.dns_name}"

  # Engine container env. Only vars the app actually reads (verified against
  # securevector-ai-threat-monitor). Host/port are NOT env — they are CLI args
  # on the launch command (see var.container_command). Empty optional values are
  # filtered out so they are never set to "".
  #
  #   SECUREVECTOR_INGRESS_TOKEN — INBOUND gate. When set the engine requires
  #                             this credential on every request (Authorization:
  #                             Bearer or X-Api-Key); /health stays open for the
  #                             ALB target-group probe. Validated by the
  #                             ingress_auth middleware in threat-monitor.
  #   SECUREVECTOR_API_KEY    — engine's OUTBOUND cloud key (personal cloud mode;
  #                             cloud_sync sends it as X-Api-Key). NOT an inbound
  #                             auth gate — it does not protect /analyze.
  #   SECUREVECTOR_API_URL    — override the SecureVector cloud API base URL.
  #   SECUREVECTOR_ENROLL_TOKEN — svet_* org enrollment token. Consumed by the
  #                             `securevector-app enroll` subcommand, so the IMAGE
  #                             ENTRYPOINT must enroll before serving (see README).
  container_env = merge(
    var.ingress_token != "" ? { SECUREVECTOR_INGRESS_TOKEN = var.ingress_token } : {},
    var.securevector_api_key != "" ? { SECUREVECTOR_API_KEY = var.securevector_api_key } : {},
    var.securevector_api_url != "" ? { SECUREVECTOR_API_URL = var.securevector_api_url } : {},
    var.cloud_connect_token != "" ? { SECUREVECTOR_ENROLL_TOKEN = var.cloud_connect_token } : {},
    var.extra_env,
  )

  # ECS container definitions want env as a list of {name, value} objects.
  container_env_list = [for k, v in local.container_env : { name = k, value = tostring(v) }]

  # ALB ingress source: open to the internet when allow_unauthenticated, else
  # restrict to the caller-supplied CIDRs (empty list = nothing reachable).
  alb_ingress_cidrs = var.allow_unauthenticated ? ["0.0.0.0/0"] : var.ingress_cidrs
}

###############################################################################
# Networking — security groups (ALB -> service -> EFS)
###############################################################################

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "SecureVector ALB ingress"
  vpc_id      = local.vpc_id
  tags        = var.tags

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = local.alb_ingress_cidrs
  }

  dynamic "ingress" {
    for_each = var.certificate_arn != "" ? [1] : []
    content {
      description = "HTTPS"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = local.alb_ingress_cidrs
    }
  }

  egress {
    description = "to service"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "service" {
  name_prefix = "${var.name}-svc-"
  description = "SecureVector Fargate service"
  vpc_id      = local.vpc_id
  tags        = var.tags

  ingress {
    description     = "from ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "all outbound (image pull, cloud sync)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "efs" {
  count = var.enable_persistence ? 1 : 0

  name_prefix = "${var.name}-efs-"
  description = "SecureVector EFS mount targets (NFS from service)"
  vpc_id      = local.vpc_id
  tags        = var.tags

  ingress {
    description     = "NFS from service"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.service.id]
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Persistence — EFS-backed volume for the audit hash-chain
###############################################################################

resource "aws_efs_file_system" "data" {
  count = var.enable_persistence ? 1 : 0

  creation_token = "${var.name}-data"
  encrypted      = true
  tags           = merge(var.tags, { Name = "${var.name}-data" })
}

resource "aws_efs_mount_target" "data" {
  for_each = var.enable_persistence ? toset(local.subnet_ids) : toset([])

  file_system_id  = aws_efs_file_system.data[0].id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs[0].id]
}

# Access point enforces the container's POSIX uid/gid and creates a dedicated
# root dir owned by that user, so the non-root engine user can write. uid/gid
# MUST match the user baked into the published image (HOME=/home/securevector).
resource "aws_efs_access_point" "data" {
  count = var.enable_persistence ? 1 : 0

  file_system_id = aws_efs_file_system.data[0].id
  tags           = var.tags

  posix_user {
    uid = var.container_uid
    gid = var.container_gid
  }

  root_directory {
    path = "/securevector"
    creation_info {
      owner_uid   = var.container_uid
      owner_gid   = var.container_gid
      permissions = "0755"
    }
  }
}

###############################################################################
# IAM — task execution role (image pull + logs) and task role (app identity)
###############################################################################

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name_prefix        = "${var.name}-exec-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name_prefix        = "${var.name}-task-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

###############################################################################
# Logs + ECS cluster
###############################################################################

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_ecs_cluster" "this" {
  name = var.name
  tags = var.tags

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }
}

###############################################################################
# Task definition — the engine container
###############################################################################

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  tags                     = var.tags

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  # Persistence mounts at the engine's data dir. The app has NO data-dir env
  # override — it uses $HOME/.local/share/securevector/threat-monitor — so
  # persistence_mount_path MUST equal that path in the published image.
  dynamic "volume" {
    for_each = var.enable_persistence ? [1] : []
    content {
      name = "data"
      efs_volume_configuration {
        file_system_id     = aws_efs_file_system.data[0].id
        transit_encryption = "ENABLED"
        authorization_config {
          access_point_id = aws_efs_access_point.data[0].id
          iam             = "DISABLED"
        }
      }
    }
  }

  # The app binds host/port from CLI args (--host/--port), NOT env. An empty
  # container_command (default) defers to the image ENTRYPOINT, which per the
  # #182 image contract binds 0.0.0.0:container_port and enrolls from
  # SECUREVECTOR_ENROLL_TOKEN (when set) before serving. We omit the `command`
  # key entirely when not overriding (ECS rejects a null command).
  container_definitions = jsonencode([
    merge(
      {
        name        = var.name
        image       = var.image
        essential   = true
        environment = local.container_env_list
        portMappings = [{
          containerPort = var.container_port
          protocol      = "tcp"
        }]
        mountPoints = var.enable_persistence ? [{
          sourceVolume  = "data"
          containerPath = var.persistence_mount_path
          readOnly      = false
        }] : []
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = aws_cloudwatch_log_group.this.name
            "awslogs-region"        = local.region
            "awslogs-stream-prefix" = "engine"
          }
        }
      },
      length(var.container_command) > 0 ? { command = var.container_command } : {},
    )
  ])
}

###############################################################################
# Application Load Balancer — stable public endpoint + /health routing gate
###############################################################################

resource "aws_lb" "this" {
  name                       = var.name
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = local.subnet_ids
  idle_timeout               = 120
  enable_deletion_protection = var.deletion_protection
  tags                       = var.tags
}

resource "aws_lb_target_group" "this" {
  name        = var.name
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"
  tags        = var.tags

  # /health is exempt from the ingress-auth gate, so the probe works even when
  # ingress_token is set. Generous thresholds cover the engine's boot (rules +
  # Guardian ML load).
  health_check {
    path                = "/health"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }

  deregistration_delay = 30
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # With a cert: redirect 80 -> 443. Without: forward 80 -> target group.
  dynamic "default_action" {
    for_each = var.certificate_arn != "" ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = var.certificate_arn == "" ? [1] : []
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this.arn
    }
  }
}

resource "aws_lb_listener" "https" {
  count = var.certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

###############################################################################
# ECS service — runs the engine, registers with the ALB
###############################################################################

resource "aws_ecs_service" "this" {
  name                   = var.name
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = var.min_instances
  launch_type            = "FARGATE"
  enable_execute_command = var.enable_execute_command

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.name
    container_port   = var.container_port
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 120

  depends_on = [
    aws_lb_listener.http,
    aws_efs_mount_target.data,
  ]

  # When autoscaling is enabled, the target tracks desired_count; ignore drift.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

###############################################################################
# Autoscaling (optional) — scale between min_instances and max_instances on CPU
###############################################################################

resource "aws_appautoscaling_target" "this" {
  count = var.max_instances > var.min_instances ? 1 : 0

  max_capacity       = var.max_instances
  min_capacity       = var.min_instances
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.max_instances > var.min_instances ? 1 : 0

  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.autoscale_cpu_target
    scale_in_cooldown  = 120
    scale_out_cooldown = 60
  }
}
