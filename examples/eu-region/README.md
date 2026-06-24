# EU-region example (AWS)

Deploys the SecureVector engine into an **EU AWS region** for data residency. Identical to [`../free-tier`](../free-tier) except the region defaults to `eu-west-1` (Ireland).

```bash
terraform init
terraform apply -var="region=eu-west-1" -var="securevector_api_key=$(openssl rand -hex 24)"
terraform output -raw runtime_snippet
terraform destroy
```

Use `-var="region=eu-central-1"` for Frankfurt.

## Data residency

Every resource this module creates — the Fargate task, the ALB, the EFS persistence volume, and the CloudWatch log group — lives in the region you set above. The engine processes and stores agent activity, threats, tool-audit, and governance data **only in your own AWS account and region**. SecureVector does not receive that data, and this module does not replicate it to any other region.

If you later enable Cloud Connect to view your governance posture in the SecureVector cloud, only metadata + hashes (never raw text) are forwarded, and only after you explicitly accept the governance terms. Keeping the deployment in an EU region keeps the resident copy of your data in the EU.
