# Free-tier "try it" — SecureVector engine on AWS Fargate

The cheapest credible way to stand up the SecureVector engine on AWS: one
always-on Fargate task behind a public Application Load Balancer, EFS
persistence on, deployed into your account's **default VPC**.

```bash
terraform init
terraform apply -var="region=us-east-1" -var="securevector_api_key=$(openssl rand -hex 24)"
terraform output dashboard_url      # http://<alb-dns> — local engine, device-level detection
terraform output -raw runtime_snippet
terraform destroy                   # clean teardown
```

> **Not free at idle.** Unlike Cloud Run, Fargate has no scale-to-zero and an
> ALB bills ~hourly, so expect a few dollars/month while it runs. `terraform
> destroy` removes everything.

> **Open endpoint.** This example serves plain HTTP with no auth — fine for a
> quick trial. For anything internet-facing, set `ingress_token` (app-layer
> auth), `certificate_arn` (HTTPS), and/or `allow_unauthenticated = false` with
> `ingress_cidrs` (restrict who can reach the ALB).

See the [module README](../../README.md) for all inputs and the Option 1 vs
Option 2 (fleet + advanced cloud ML) paths.
