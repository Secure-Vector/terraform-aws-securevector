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

Every resource this module creates — the Fargate task, the ALB, the EFS persistence volume, and the CloudWatch log group — lives in the region you set above. The engine processes and stores agent activity, threats, tool-audit, and governance data **only in your own AWS account and region**. This module does not replicate it to another region.

> **Important — cloud ML analysis.** If you turn on **Cloud Mode** (cloud ML threat analysis), the engine sends the **prompt text** to SecureVector's cloud scan service (`scan.securevector.io`, processed in the **US**). That content is **not stored or logged** by the cloud (metadata-only retention), but it **is transmitted to and processed in the US** — so it leaves your region. A setting to keep all prompt analysis local ("EU data residency" mode) is planned for v4.8.0; until it ships, **leave Cloud Mode off for strict EU data residency** (local detection — bundled rules + the on-device model — still runs).

If you later enable Cloud Connect to view your governance posture in the SecureVector cloud, only metadata + hashes (never raw text) are forwarded, and only after you explicitly accept the governance terms. Keeping the deployment in an EU region keeps the resident copy of your data in the EU.
