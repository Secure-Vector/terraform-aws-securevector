# terraform-aws-securevector

[![License](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)
[![Terraform](https://img.shields.io/badge/terraform-%3E%3D1.5-7B42BC)](https://www.terraform.io/)
[![AWS Fargate](https://img.shields.io/badge/AWS-ECS%20Fargate-FF9900)](https://aws.amazon.com/fargate/)

> **One `terraform apply` → a live SecureVector engine in your own AWS account,
> in ~5 minutes.** The turnkey *server* companion to the SecureVector Guard SDKs
> ([langchain](https://pypi.org/project/securevector-sdk-langchain/) ·
> [langgraph](https://pypi.org/project/securevector-sdk-langgraph/) ·
> [crewai](https://pypi.org/project/securevector-sdk-crewai/)) **and the Guard
> plugins** for agent runtimes (Claude Code, Codex, GitHub Copilot CLI, OpenClaw,
> and more — see the
> [threat-monitor repo](https://github.com/Secure-Vector/securevector-ai-threat-monitor)).
> The SDKs and plugins secure individual agents on individual machines; this
> stands up the shared engine your whole team's agents, CI runners, and prod
> services point at.

This is **bring-your-own-cloud (BYOC) self-hosting**: the engine and all scanned
data live in *your* account, in *your* tenant — nothing leaves. It is the
local-first story scaled from one laptop to one shared box you control.

> ✅ **Status: live.** The engine image is published and **public** —
> `ghcr.io/secure-vector/securevector-ai-threat-monitor` (tags `latest` and
> `4.7.1`), multi-arch (amd64/arm64). `var.image` pulls it with no extra setup.
>
> One caveat: the current image runs **device-level (Option 1) detection**;
> engine-side **inbound auth** (`ingress_token` → `SECUREVECTOR_INGRESS_TOKEN`)
> is not yet enforced and ships in a later release. Until then, gate
> internet-facing deployments at the **network layer**
> (`allow_unauthenticated = false`, `ingress_cidrs`, or cloud IAM) rather than
> relying on `ingress_token` alone.

---

## Why Fargate + ALB + EFS

AWS has no single primitive that gives a managed HTTPS URL *and* a durable
volume. App Runner gives the URL but **no persistent storage**; the engine's
default posture keeps a tamper-evident audit hash-chain. So this module uses the
faithful analog of GCP Cloud Run + a GCS volume:

- **ECS Fargate** — serverless containers, no EC2 to manage.
- **Application Load Balancer** — a stable public DNS endpoint + `/health`
  routing (HTTP by default; HTTPS when you set `certificate_arn`).
- **EFS** — a durable volume mounted at the engine's data dir (via an access
  point that maps the container's non-root uid/gid).

By default it deploys into your account's **default VPC and its public subnets**,
so a single `apply` needs no networking setup.

```
terraform apply -var="region=us-east-1"
#
# Outputs:
#   dashboard_url   = "http://securevector-123.us-east-1.elb.amazonaws.com"
#   runtime_snippet = "point any SecureVector SDK/plugin at the URL above"
```

> Unlike Cloud Run, **Fargate has no scale-to-zero** and the **ALB bills
> ~hourly**, so this is not free at idle — budget a few dollars/month. `terraform
> destroy` removes everything.

## Quick start

### Prerequisites
- An AWS account with credentials configured for Terraform (`AWS_PROFILE` / env /
  instance role) and a chosen region in the `provider "aws"` block.
- Terraform `>= 1.5` (or OpenTofu).
- Permission to create ECS, ELB, EFS, IAM, CloudWatch Logs, and EC2 (SG) resources.

There are two ways to run it. **Option 1** is the standalone self-host engine;
**Option 2** adds the SecureVector cloud on top.

| | **Option 1 — Device-level engine** (default) | **Option 2 — + Fleet & advanced cloud ML** |
|---|---|---|
| What you get | Your own engine doing **local, device-level** detection — local rules + the **Guardian ML** model — running entirely in your account. | Everything in Option 1, **plus** the SecureVector cloud: org **fleet** management, **policy sync**, and the cloud's **advanced ML / enhanced `/analyze`**. |
| Needs | Just an AWS account. No SecureVector account. | **Requires a SecureVector account (sign up).** An `svet_*` enrollment token (and/or `svpk_*` key); cloud tiers/billing apply. |
| Set | nothing extra | `cloud_connect_token` (svet\_) and/or `securevector_api_key` (svpk\_) |

#### Option 1 — Device-level engine (default, one command)

A region and AWS creds: a Fargate task behind a public ALB, local detection, and
a clean `terraform destroy`. This is the [`examples/free-tier`](examples/free-tier) example.

```bash
terraform apply -var="region=us-east-1"
terraform output dashboard_url      # live URL — local engine, device-level detection
terraform destroy                   # clean teardown
```

> Keyless = the endpoint is open HTTP. Fine for a quick trial or a
> network-restricted box. For anything internet-facing, gate it with
> `ingress_token` (app-layer auth), `certificate_arn` (HTTPS), and/or
> `allow_unauthenticated = false` + `ingress_cidrs` (network layer).

#### Option 2 — Add fleet management + advanced cloud ML

> **Requires a SecureVector account — sign up first.** Option 2 connects the
> engine to the SecureVector cloud, so you must create an account and obtain a
> token: an `svet_*` enrollment token (→ fleet + policy sync) and/or an `svpk_*`
> key (→ personal cloud mode). Sign up at [app.securevector.io/signup](https://app.securevector.io/signup).
> Cloud tiers / billing apply. **Option 1 needs none of this.**

Same engine, now bridged to the SecureVector cloud: set `cloud_connect_token`
(an `svet_*` org token → **fleet view + policy sync**) and/or
`securevector_api_key` (a personal `svpk_*`/legacy key → personal cloud mode +
**enhanced ML `/analyze`**). Those are the engine's *outbound* cloud credentials.
Add `ingress_token` to authenticate inbound clients. See
[Tokens](#tokens--which-credential-enables-what).

**Fleet use case — one pane of glass across many containers.** Running more than
one engine — replicas of a service, several agent apps, or containers spread
across regions and clusters? Give every container the **same**
`cloud_connect_token` (`svet_*`). Each node enrolls into your org and streams its
**security findings** (threats, blocked tool calls, secret/data-leak hits) and
**observability** (agent runs, tool-permission decisions) up to the SecureVector
cloud — so the **entire fleet shows up in a single span / fleet view** instead of
N isolated per-container dashboards. One place to watch security posture *and*
agent behavior across the whole fleet, with org-wide policy pushed back down to
every node via policy sync.

```hcl
module "securevector" {
  source  = "Secure-Vector/securevector/aws"
  version = "~> 0.1"   # once published to the Terraform Registry

  name                 = "securevector"
  securevector_runtime = "langchain"            # emits a wired client snippet
  ingress_token        = var.ingress_token      # app-layer inbound auth
  cloud_connect_token  = var.svet_token         # → fleet + policy sync (advanced)
  # securevector_api_key = var.svpk_key         # → personal cloud mode + enhanced ML
  # certificate_arn      = var.acm_cert_arn     # → HTTPS (else HTTP only)
}

output "dashboard_url"   { value = module.securevector.dashboard_url }
output "runtime_snippet" { value = module.securevector.runtime_snippet }
```

Until the Registry listing is live, point `source` at the repo:
`source = "github.com/Secure-Vector/terraform-aws-securevector"`.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | `securevector` | Base name for cluster/service/ALB/EFS/IAM. ≤32 chars (ALB limit). |
| `image` | string | `ghcr.io/secure-vector/securevector-ai-threat-monitor:latest` | Engine container image. Pin a tag for prod. |
| `container_port` | number | `8741` | Port the engine listens on. |
| `cpu` / `memory` | string | `512` / `1024` | Fargate task size (units / MiB). Must be a valid Fargate combo. |
| `cpu_architecture` | string | `X86_64` | `X86_64` or `ARM64` (Graviton). |
| `min_instances` / `max_instances` | number | `1` / `2` | Always-on task count / autoscaling ceiling. **No scale-to-zero.** |
| `autoscale_cpu_target` | number | `70` | Target CPU % (when `max>min`). |
| `container_command` | list(string) | `[]` | Override the image entrypoint. `[]` = use the image's own. App takes host/port as CLI args. |
| `vpc_id` | string | `""` | VPC to deploy into. `""` = default VPC. |
| `subnet_ids` | list(string) | `[]` | Public subnets (≥2 AZs). `[]` = default VPC's subnets. |
| `assign_public_ip` | bool | `true` | Public IP on tasks (needed in public subnets without NAT). |
| `allow_unauthenticated` | bool | `true` | Open the ALB to `0.0.0.0/0`. `false` = restrict to `ingress_cidrs`. |
| `ingress_cidrs` | list(string) | `[]` | CIDRs allowed when `allow_unauthenticated = false`. |
| `certificate_arn` | string | `""` | ACM cert ARN → HTTPS 443 listener + 80→443 redirect. `""` = HTTP only. |
| `ingress_token` | string (sensitive) | `""` | App-layer inbound gate → `SECUREVECTOR_INGRESS_TOKEN`. Engine requires `Authorization: Bearer`/`X-Api-Key`; `/health` stays open. |
| `securevector_api_key` | string (sensitive) | `""` | **Outbound** cloud key (`svpk_`/legacy) → `SECUREVECTOR_API_KEY` (personal cloud mode). Not an inbound gate. |
| `securevector_api_url` | string | `""` | Override the SecureVector cloud API base URL. |
| `cloud_connect_token` | string (sensitive) | `""` | **Outbound** `svet_*` org enroll token → `SECUREVECTOR_ENROLL_TOKEN` (fleet + policy sync). Needs the image entrypoint to enroll. |
| `securevector_runtime` | string | `none` | Client to emit a wiring snippet for. SDKs: `langchain`/`langgraph`/`crewai`. Plugins: `claude-code`/`cursor`/`codex`/`copilot-cli`/`openclaw`. Or `none`. |
| `enable_persistence` | bool | `true` | Mount an EFS volume for the audit hash-chain. |
| `persistence_mount_path` | string | `…/securevector/threat-monitor` | Where the volume mounts; must equal the app data dir in the image. |
| `container_uid` / `container_gid` | number | `1000` / `1000` | POSIX ids for the EFS access point; must match the image user. |
| `deletion_protection` | bool | `false` | ALB deletion protection. `true` for prod. |
| `log_retention_days` | number | `30` | CloudWatch Logs retention. |
| `container_insights` | bool | `false` | ECS Container Insights (extra cost). |
| `enable_execute_command` | bool | `false` | ECS Exec for debugging into the task. |
| `tags` | map(string) | `{}` | Tags on created resources. |
| `extra_env` | map(string) | `{}` | Extra container env vars. |

## Outputs

| Name | Description |
|---|---|
| `dashboard_url` | Engine dashboard URL (ALB DNS; https when `certificate_arn` set). |
| `health_url` | Health endpoint for probes. |
| `alb_dns_name` | Raw ALB DNS (point a CNAME / Route 53 alias here). |
| `service_name` / `cluster_name` / `region` | Deployed ECS identity. |
| `persistence_filesystem_id` | Audit-chain EFS id (null if persistence off). |
| `runtime_snippet` | Copy-paste snippet wiring the chosen SDK/plugin to this engine. |

## Clients — point any SDK or plugin at this engine

`securevector_runtime` makes the module emit a ready-to-paste wiring snippet
(`terraform output -raw runtime_snippet`). All SecureVector clients are
supported. **The base-URL env var (how a client targets the engine) differs by
family** and is the part that works today:

| Client | `securevector_runtime` value | Base-URL env var (targets the engine) |
|---|---|---|
| LangChain / LangGraph / CrewAI SDK | `langchain` / `langgraph` / `crewai` | `SECUREVECTOR_SDK_APP_URL` (+ `SECUREVECTOR_SDK_MODE`) |
| Claude Code plugin | `claude-code` | `SV_BASE_URL` (hooks) · `SECUREVECTOR_URL` (statusline) |
| Cursor plugin | `cursor` | `SV_BASE_URL` · `SECUREVECTOR_URL` |
| Codex plugin | `codex` | `SV_BASE_URL` · `SECUREVECTOR_URL` |
| GitHub Copilot CLI plugin | `copilot-cli` | `SV_BASE_URL` · `SECUREVECTOR_URL` |
| OpenClaw guard | `openclaw` | `SECUREVECTOR_URL` |

When the module sets `ingress_token`, the engine **requires** a credential
(`Authorization: Bearer` / `X-Api-Key`). A client forwards it via
`SECUREVECTOR_API_KEY` — **OpenClaw (and any header-capable client like curl)
works today**; SDK / JS-hook client-side forwarding is rolling out, so for
those leave `ingress_token` unset or restrict at the network layer. (Plugin list
mirrors `securevector-ai-threat-monitor/src/securevector/plugins/`.)

## Tokens — which credential enables what

Two distinct, **outbound** engine credentials (engine → SecureVector cloud), plus
the inbound story:

| Capability | Direction | Credential | Notes |
|---|---|---|---|
| **Remote analyze** (client → engine) | inbound | `ingress_token` → `SECUREVECTOR_INGRESS_TOKEN` | Engine requires `Authorization: Bearer`/`X-Api-Key` when set (fail-open when unset). Header-capable clients (OpenClaw, curl) work today; SDK/JS-hook forwarding rolling out. Or restrict via `ingress_cidrs`. |
| **Personal cloud mode** (enhanced detection) | outbound | `securevector_api_key` (`svpk_`/legacy) → `SECUREVECTOR_API_KEY` | Engine presents it to the cloud as `X-Api-Key` (`cloud_sync.py`). No policy sync. |
| **Forward to fleet** (org visibility) | outbound | `cloud_connect_token` (`svet_*`) → `SECUREVECTOR_ENROLL_TOKEN` | Org enrollment. Needs the image entrypoint to run `securevector-app enroll`. |
| **Sync policies to local** (signed bundles) | outbound→in | `cloud_connect_token` (`svet_*` **only**) | `svpk_`/legacy/none ⇒ Policy Sync OFF — no partial mode (`device_admin.py`). |

> For production, source `securevector_api_key` / `cloud_connect_token` from AWS
> Secrets Manager rather than tfvars (roadmap; see wiki open questions).

## Persistence

`enable_persistence = true` mounts an EFS file system for the tamper-evident
audit hash-chain. The app has **no data-dir env override** — it writes to
`$HOME/.local/share/securevector/threat-monitor` — so `persistence_mount_path`
must equal that path in the published image, and `container_uid`/`container_gid`
must match the image's user (the EFS access point creates a root dir owned by
that uid/gid). For a throwaway trial, set `enable_persistence = false`.

## Cloud Connect (optional)

Set `cloud_connect_token` (an `svet_*` org enrollment token) to enroll this
self-hosted node into the SecureVector managed fleet view and receive signed
policy bundles — the OSS-self-host → paid Pro/Enterprise on-ramp. It is passed
as `SECUREVECTOR_ENROLL_TOKEN`; the published image's entrypoint must run
`securevector-app enroll` (then serve) for it to take effect. Leave empty to stay
fully self-hosted with no outbound enrollment.

## Teardown

```bash
terraform destroy
```

Removes the ECS service/cluster, ALB, EFS, IAM roles, and log group. No leftover
billable resources (set `deletion_protection = false`, the default).

## Related

- **Client SDKs:** [`securevector-sdk-langchain`](https://github.com/Secure-Vector/securevector-sdk-langchain) · [`-langgraph`](https://github.com/Secure-Vector/securevector-sdk-langgraph) · [`-crewai`](https://github.com/Secure-Vector/securevector-sdk-crewai)
- **Other clouds:** `terraform-google-securevector` · `terraform-azurerm-securevector` · `terraform-oci-securevector` — each ships the **identical** [`runtime.tf`](runtime.tf) (same supported clients, same env-var contract, same auth caveat). That file is the single source of truth for the client list and is kept byte-identical across all four cloud repos.
- **Engine source / container:** [`securevector-ai-threat-monitor`](https://github.com/Secure-Vector/securevector-ai-threat-monitor)

## License

[Apache-2.0](LICENSE). See [NOTICE](NOTICE) for trademark attributions.
