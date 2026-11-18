# Template Shape & Materialization Contract

This guide explains how templates under [`/templates`](../templates/README.md) are structured, parameterized, and materialized by the **Azure App Platform** canvas or standalone tooling.

Machine-readable metadata for every starter template, the complete Dealership E2E reference sample, and all capability building blocks lives in [`templates/catalog.json`](../templates/catalog.json).

---

## Starter & Reference Templates

| Template ID | Path | Pattern |
| --- | --- | --- |
| `builtin-sandbox-gateway-minimal-v1` | [`templates/sandbox-gateway-minimal`](../templates/sandbox-gateway-minimal) | **Sandboxes + AI Gateway Minimal**: 1 agent ready to scale to 2+ agents & skills, routing all model and sandboxed tool calls through AI Gateway with ACA Sandboxes egress proxy isolation. |
| `builtin-sandboxes-minimal-v1` | [`templates/sandboxes-minimal`](../templates/sandboxes-minimal) | **Sandboxes Minimal**: 1 agent calling its own sandboxed tools with ACA Sandboxes isolation and default-deny egress proxy, without a gateway. |
| `builtin-app-service-builder-vite-v1` | [`templates/app-service-builder-vite`](../templates/app-service-builder-vite) | **App Service Builder (Vite Starter)**: TypeScript + Vite web experience (`builder.yaml`), ready to expand with Hosted Skills. |
| `builtin-app-service-builder-ai-gateway-v1` | [`templates/app-service-builder-ai-gateway`](../templates/app-service-builder-ai-gateway) | **App Service Builder (Agent & AI Gateway)**: Python FastAPI + Microsoft Agent Framework streaming chat app (`builder.yaml`) wired to Azure AI Gateway. |
| `builtin-dealership-e2e-v1` | [`templates/dealership-e2e`](../templates/dealership-e2e) | **Dealership E2E Reference Sample**: Complete multi-tier reference app (`driveline-web`, `deal-finder` agent, AI Gateway, 4 MCP Hosted Skills, `prequal` ACA Sandbox, DTS approval workflows, and SRE Agent). |
| `builtin-empty-starter-v1` | [`templates/empty-starter-app`](../templates/empty-starter-app) | **Empty Starter App**: Minimal web + agent + Hosted Skill workspace shell ready to customize with capability building blocks. |

Capability building blocks added incrementally in the Build workspace live under [`templates/build-blocks/`](../templates/build-blocks) and shared port-allocation helpers live under [`templates/shared/`](../templates/shared).

---

## `.template` Files & Token Substitution

Files ending in `.template` are rendered with the `.template` suffix removed during materialization (for example, `src/agent/main.py.template` becomes `src/agent/main.py`). Files without `.template` keep their filenames unchanged. Relative Markdown links ending in `.template` are rewritten to their rendered paths automatically.

| Token | Description |
| --- | --- |
| `__APP_NAME__` | Validated application display name |
| `__APP_NAME_HTML_JSON__` | HTML-escaped JSON string literal of the display name |
| `__APP_SLUG__` | Lowercase, hyphenated application slug |
| `__PURPOSE__` / `__USER_INTENT__` | Validated application purpose |
| `__PURPOSE_JSON__` | JSON-escaped purpose string |
| `__PURPOSE_HTML_JSON__` | HTML-escaped JSON string literal of the purpose |
| `__AGENT_INSTRUCTIONS__` | Custom agent instructions (or purpose-based default) |
| `__EGRESS_ALLOW_DOMAIN__` | Validated exact hostname for reviewed outbound sandbox policy |
| `__SKILL_NAME__` | Lowercase hyphenated Hosted Skill name (`src/skills/__SKILL__` -> `src/skills/<name>`) |
| `__BLOCK_NAME__` | Lowercase hyphenated capability block name when adding blocks from `templates/build-blocks/` |

---

## Port Allocation & Local State

- Shared port loaders (`templates/shared/load-ports.sh` and `templates/shared/load-ports.ps1`) are copied into `<app>/scripts/` during materialization.
- Generated POSIX scripts (`scripts/dev-start.sh` and `scripts/dev-stop.sh`) are marked executable (`0755`).
- Workspace-specific ports (`.azure-app-platform/ports.env`), runtime logs (`.dev-run/`), credentials (`.env`, `src/agent/.env`, `local.settings.json`), and local virtual environments (`.venv/`, `node_modules/`) are gitignored local state and are never stored in templates.
