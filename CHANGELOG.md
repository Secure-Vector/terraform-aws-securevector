# Changelog

All notable changes to this module are documented here. This project adheres to
[Semantic Versioning](https://semver.org/). The Terraform Registry publishes a
release per `vX.Y.Z` git tag.

## [Unreleased]

### Added
- Initial AWS module: deploys the SecureVector engine to the user's own AWS
  account on **ECS Fargate behind an Application Load Balancer**, with a clean
  `terraform destroy`. Defaults to the account's default VPC + public subnets so
  a single `apply` works with no networking to manage.
- Optional **EFS-backed persistence volume** for the tamper-evident audit
  hash-chain (`enable_persistence`, default on), mounted at the app data dir via
  an EFS access point that enforces the container's POSIX uid/gid so the
  non-root engine user can write.
- Application-layer inbound gate (`ingress_token` → `SECUREVECTOR_INGRESS_TOKEN`)
  — when set, the engine requires `Authorization: Bearer` / `X-Api-Key` on every
  request (`/health` stays open for the ALB target-group probe), validated by
  the `ingress_auth` middleware in securevector-ai-threat-monitor (fail-open when
  unset). Network-layer gate via `allow_unauthenticated` / `ingress_cidrs` on the
  ALB security group.
- Optional HTTPS: set `certificate_arn` (ACM) to add a TLS1.3 443 listener and
  redirect 80 → 443. HTTP-only by default.
- Engine **outbound** cloud credentials: `securevector_api_key` (`svpk_`/legacy →
  `SECUREVECTOR_API_KEY`, personal cloud mode) and `cloud_connect_token`
  (`svet_*` → `SECUREVECTOR_ENROLL_TOKEN`, fleet + policy sync).
- `securevector_runtime` variable that emits a copy-paste SDK/plugin wiring
  snippet as a Terraform output, pre-pointed at the new ALB URL. Covers all
  SecureVector clients: SDKs (langchain / langgraph / crewai) and plugins
  (claude-code / cursor / codex / copilot-cli / openclaw), each with its real
  base-URL env var and the shared credential `SECUREVECTOR_API_KEY`.
- Shared `runtime.tf` — **byte-identical** with the other
  `terraform-<cloud>-securevector` repos so every cloud exposes the same
  clients/snippets/contract.
- CPU target-tracking autoscaling between `min_instances` and `max_instances`;
  CloudWatch Logs (`/ecs/<name>`); ECS Exec toggle (`enable_execute_command`);
  Graviton support (`cpu_architecture = "ARM64"`).

### Terraform best-practices / DevOps notes
- **Region** comes from the AWS provider config (the AWS idiom), not a module
  variable; the module reads the active region via `aws_region` for log config
  and the `region` output.
- **No scale-to-zero** on Fargate (unlike Cloud Run): `min_instances` is the
  always-on task count (default 1). Documented in the README and example.
- `assign_public_ip = true` by default because the default-VPC public subnets
  have no NAT — the task needs a public IP to pull the image and reach the
  SecureVector cloud. Set false only with private subnets + a NAT route.
- ALB target-group health check hits `/health` (exempt from the ingress gate)
  with a 120s service grace period to cover the engine's boot (rules + Guardian
  ML load). No container-level health check — the slim image has no curl/wget.
- Security groups are chained ALB → service → EFS (least-privilege NFS), all
  `create_before_destroy` to avoid replacement deadlocks.
- Input validation on `name` (≤32, ALB limit), `container_port` (1–65535),
  `min_instances` (≥0), `max_instances` (≥1), `cpu_architecture` (enum).

### Notes
- Hard prerequisites (story #182): a published engine container image whose
  entrypoint binds `0.0.0.0:$PORT`, stores data at the mount path, and enrolls
  from `SECUREVECTOR_ENROLL_TOKEN`; plus engine-side inbound auth. Both are
  implemented in securevector-ai-threat-monitor pending the first ghcr publish.
  The Terraform is correct against the real app interface and will deploy a
  working engine once that image ships.
- `container_uid` / `container_gid` (default 1000) MUST match the user baked
  into the published image, or EFS writes will be denied.
