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

> **EU data residency is enforced in this example.** It sets `extra_env = { SV_DATA_RESIDENCY = "eu" }`, which the **v4.8+ engine** honors by keeping **all prompt analysis local**: even with Cloud Mode on, prompts are **not** sent to SecureVector's cloud scan service (`scan.securevector.io`, US) — the local-only analysis toggle is locked on and cannot be disabled. No prompt text leaves your region. (The module pulls the `:latest` engine image; ensure it is **v4.8 or newer** for this enforcement. On older images the flag is a harmless no-op — leave Cloud Mode off for strict residency until you're on v4.8+.)

If you later enable Cloud Connect to view your governance posture in the SecureVector cloud, only metadata + hashes (never raw text) are forwarded, and only after you explicitly accept the governance terms. Keeping the deployment in an EU region keeps the resident copy of your data in the EU. Forwarded metadata can include identifiers (device, agent, and session IDs) that may be personal data under GDPR and is processed by SecureVector in the US — treat its use as your DPO's assessment.
