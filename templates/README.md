# Azure App Platform Templates

This directory contains all starter templates, the complete Dealership E2E reference sample, capability building blocks, and shared port-allocation helpers consumed by the **Azure App Platform** canvas and CLI materializer.

Machine-readable template and building-block definitions live in [`catalog.json`](catalog.json).

## App Templates

| Folder | Template ID | Capabilities | Description |
| --- | --- | --- | --- |
| [`sandbox-gateway-minimal/`](sandbox-gateway-minimal) | `builtin-sandbox-gateway-minimal-v1` | `agent`, `sandbox`, `gateway` | **Sandboxes & AI Gateway Starter**: Python agent + sandboxed document validation tool with all model and tool calls routed through Azure AI Gateway and ACA Sandboxes default-deny egress. |
| [`sandboxes-minimal/`](sandboxes-minimal) | `builtin-sandboxes-minimal-v1` | `agent`, `sandbox` | **Sandboxes Minimal Starter**: Single-agent starter calling sandboxed tools protected by ACA Sandboxes isolation and the Sandboxes egress proxy, without a gateway. |
| [`app-service-builder-vite/`](app-service-builder-vite) | `builtin-app-service-builder-vite-v1` | `web` | **App Service Builder - Vite Starter**: Vite + TypeScript web starter (`builder.yaml`) ready to deploy to Azure App Service Builder and expand with Hosted Skills. |
| [`app-service-builder-ai-gateway/`](app-service-builder-ai-gateway) | `builtin-app-service-builder-ai-gateway-v1` | `web`, `gateway` | **App Service Builder - Agent & AI Gateway**: Python FastAPI + Microsoft Agent Framework streaming chat app (`builder.yaml`) wired to Azure AI Gateway. |
| [`dealership-e2e/`](dealership-e2e) | `builtin-dealership-e2e-v1` | `web`, `agent`, `gateway`, `skills`, `sandbox`, `connectors`, `workflows`, `sre`, `data` | **Dealership E2E Reference Sample**: Complete runnable Contoso Auto car-buying app (`driveline-web`, `deal-finder`, AI Gateway, 4 MCP Hosted Skills, `prequal` ACA Sandbox, DTS approval workflows, and Azure SRE Agent). |
| [`empty-starter-app/`](empty-starter-app) | `builtin-empty-starter-v1` | `web`, `agent`, `gateway`, `skills` | **Empty Starter App**: Minimal multi-service workspace shell ready to customize with capability blocks. |

## Capability Building Blocks & Shared Helpers

- [`build-blocks/`](build-blocks): Composable capability blocks materialized into an existing workspace (`agent-instructions`, `connector`, `event-trigger`, `functions-base`, `http-trigger`, `operations`, `orchestration`, `queue-trigger`, `sandbox`, `timer-trigger`, `web`).
- [`shared/`](shared): Cross-platform port-loader scripts (`load-ports.sh`, `load-ports.ps1`) and Dealership workspace port-override helpers (`shared/dealer/`).

For `.template` token rules and materialization details, see [`../docs/template-authoring.md`](../docs/template-authoring.md).
