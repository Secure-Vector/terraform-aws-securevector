###############################################################################
# SHARED runtime / client contract
#
# >>> KEEP THIS FILE BYTE-IDENTICAL ACROSS ALL terraform-<cloud>-securevector
#     REPOS (aws / azurerm / google / oci). <<<
#
# It defines which SecureVector clients are supported and the copy-paste wiring
# snippet emitted for each. Its only external dependency is local.base_url (the
# deployed engine's HTTPS URL), which every cloud module defines in its own
# main.tf. Change the supported-client list or snippets HERE, then sync the file
# to every cloud repo so all clouds expose the identical contract.
#
# Verified client contract (securevector-ai-threat-monitor):
#   Base URL (per family):
#     SDKs (langchain/langgraph/crewai)             -> SECUREVECTOR_SDK_APP_URL (+ SECUREVECTOR_SDK_MODE)
#     JS-hook plugins (claude-code/cursor/codex/copilot-cli)
#                                                   -> SV_BASE_URL (hooks) / SECUREVECTOR_URL (statusline)
#     openclaw                                      -> SECUREVECTOR_URL
#   Credential (forwarded by the client):
#     When the module sets var.ingress_token, the engine REQUIRES a matching
#     credential on every request (Authorization: Bearer <token> or
#     X-Api-Key: <token>) — validated by the ingress_auth middleware in
#     threat-monitor. EVERY client forwards it via SECUREVECTOR_API_KEY: the
#     SDKs (Config.api_key) and all plugins (claude-code/cursor/codex/
#     copilot-cli/openclaw) send Authorization: Bearer. (Forwarding ships with
#     the engine-image release; ensure your SDK/plugin is recent.)
#     Tokens are never interpolated into snippets (sensitive) — shown as
#     <placeholders> only.
###############################################################################

variable "securevector_runtime" {
  description = "Which SecureVector client to emit a copy-paste wiring snippet for as a Terraform output. SDKs: langchain, langgraph, crewai. Plugins: claude-code, cursor, codex, copilot-cli, openclaw. Or none."
  type        = string
  default     = "none"

  validation {
    condition = contains([
      "none",
      # SDKs
      "langchain", "langgraph", "crewai",
      # plugins (securevector-ai-threat-monitor/src/securevector/plugins)
      "claude-code", "cursor", "codex", "copilot-cli", "openclaw",
    ], var.securevector_runtime)
    error_message = "securevector_runtime must be one of: none | langchain | langgraph | crewai | claude-code | cursor | codex | copilot-cli | openclaw."
  }
}

locals {
  runtime_snippets = {
    none = <<-EOT
      Your SecureVector engine is live at:
        ${local.base_url}

      Point a client at it. Base-URL env var depends on the client family:
        SDKs     -> export SECUREVECTOR_SDK_APP_URL=${local.base_url}
        plugins  -> export SV_BASE_URL=${local.base_url}
        openclaw -> export SECUREVECTOR_URL=${local.base_url}

      If the module set ingress_token, forward it as the credential
      (Authorization: Bearer / X-Api-Key); all clients forward it:
        export SECUREVECTOR_API_KEY=<= ingress_token>
    EOT

    langchain = <<-EOT
      pip install securevector-sdk-langchain
      export SECUREVECTOR_SDK_APP_URL=${local.base_url}
      export SECUREVECTOR_SDK_MODE=enforce
      export SECUREVECTOR_API_KEY=<api key / token>      # = ingress_token if set; forwarded as Authorization: Bearer

      # in your agent:
      from securevector_sdk_langchain import secure_middleware
      from langchain.agents import create_agent
      agent = create_agent(model, tools, middleware=[secure_middleware(mode="enforce")])
    EOT

    langgraph = <<-EOT
      pip install securevector-sdk-langgraph
      export SECUREVECTOR_SDK_APP_URL=${local.base_url}
      export SECUREVECTOR_SDK_MODE=enforce
      export SECUREVECTOR_API_KEY=<api key / token>      # = ingress_token if set; forwarded as Authorization: Bearer

      # in your agent:
      from securevector_sdk_langgraph import secure_middleware
      from langchain.agents import create_agent
      agent = create_agent(model, tools, middleware=[secure_middleware(mode="enforce")])
    EOT

    crewai = <<-EOT
      pip install securevector-sdk-crewai
      export SECUREVECTOR_SDK_APP_URL=${local.base_url}
      export SECUREVECTOR_SDK_MODE=enforce
      export SECUREVECTOR_API_KEY=<api key / token>      # = ingress_token if set; forwarded as Authorization: Bearer

      # wrap your crew's tools before kickoff:
      from securevector_sdk_crewai import secure_tools
      crew = Crew(agents=agents, tasks=tasks, tools=secure_tools(tools, mode="enforce"))
    EOT

    claude-code = <<-EOT
      # Install the SecureVector Claude Code plugin, then point its hooks here:
      export SV_BASE_URL=${local.base_url}
      export SECUREVECTOR_URL=${local.base_url}              # read by the statusline
      export SECUREVECTOR_API_KEY=<api key / token>      # = ingress_token if set; forwarded as Authorization: Bearer
    EOT

    cursor = <<-EOT
      # Install the SecureVector Cursor plugin, then point its hooks here:
      export SV_BASE_URL=${local.base_url}
      export SECUREVECTOR_URL=${local.base_url}              # read by the statusline
      export SECUREVECTOR_API_KEY=<api key / token>      # = ingress_token if set; forwarded as Authorization: Bearer
    EOT

    codex = <<-EOT
      # Install the SecureVector Codex plugin, then point its hooks here:
      export SV_BASE_URL=${local.base_url}
      export SECUREVECTOR_URL=${local.base_url}              # read by the statusline
      export SECUREVECTOR_API_KEY=<api key / token>      # = ingress_token if set; forwarded as Authorization: Bearer
    EOT

    copilot-cli = <<-EOT
      # Install the SecureVector GitHub Copilot CLI plugin, then point it here:
      export SV_BASE_URL=${local.base_url}
      export SECUREVECTOR_URL=${local.base_url}              # read by the statusline
      export SECUREVECTOR_API_KEY=<api key / token>      # = ingress_token if set; forwarded as Authorization: Bearer
    EOT

    openclaw = <<-EOT
      # Point the SecureVector OpenClaw guard here (openclaw.json or env):
      export SECUREVECTOR_URL=${local.base_url}
      export SECUREVECTOR_API_KEY=<api key / token>      # = ingress_token if set; forwarded as Authorization: Bearer
    EOT
  }

  runtime_snippet = lookup(local.runtime_snippets, var.securevector_runtime, local.runtime_snippets["none"])
}

output "runtime_snippet" {
  description = "Copy-paste snippet wiring the chosen SecureVector SDK/plugin (var.securevector_runtime) to this engine."
  value       = local.runtime_snippet
}
