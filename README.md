# Azure App Platform Templates & Reference Architecture

<img src="docs/images/agentic-architecture.svg" alt="Agentic Cloud Application: front end to agent to AI Gateway, governing models, ACA Sandboxes, Hosted Skills, and human approval workflows" width="820" />

Official starter templates, end-to-end reference sample, and architecture documentation for **Azure App Platform**: an opinionated serverless and AI-native application platform built around **Azure App Service Builder**, **Microsoft Foundry Hosted Agents** / **Azure Container Apps**, **Azure AI Gateway**, **ACA Sandboxes**, **Azure Functions Hosted Skills (MCP)**, **Durable Task Scheduler (DTS)**, **Managed Connectors**, and **Azure SRE Agent**.

Every template follows three core design principles:

- **Single governed choke point (`AI Gateway`)**: Front ends talk to the agent, and every outbound call from the agent to models, sandboxes, Hosted Skills, and workflow/communication tools passes through **Azure AI Gateway** for authentication, Prompt Shields, quotas, routing, and OpenTelemetry tracing.
- **Environment safety (`ACA Sandboxes`)**: Sensitive PII computation and untrusted document/code execution run inside ephemeral microVMs with no host credentials and a default-deny egress proxy.
- **Operational self-awareness (`Azure SRE Agent`)**: Telemetry, continuous evaluations, and human-reviewed or autonomous remediation span every application tier from day one.

---

## Repository Layout

- [`templates/`](templates/README.md): All starter templates, the complete Dealership E2E reference app, capability building blocks (`build-blocks/`), shared port loaders (`shared/`), and the machine-readable [`templates/catalog.json`](templates/catalog.json) manifest.
- [`docs/`](docs/README.md): Architecture reference design, Sandbox & AI Gateway pattern guides, boundary validation steps, SRE Agent self-awareness walkthrough, and SVG architecture diagrams (`docs/images/`).

---

## Available Templates (`/templates`)

| Template | Path | Capabilities | What You Get |
| --- | --- | --- | --- |
| **Sandboxes & AI Gateway Starter** | [`templates/sandbox-gateway-minimal`](templates/sandbox-gateway-minimal) | Agent · ACA Sandboxes · AI Gateway | Headless Python agent + sandboxed document validation/redaction tool with all model and tool calls governed behind AI Gateway. |
| **Sandboxes Minimal Starter** | [`templates/sandboxes-minimal`](templates/sandboxes-minimal) | Agent · ACA Sandboxes | Single-agent starter dispatching untrusted work to ACA Sandboxes with default-deny egress proxy isolation. |
| **App Service Builder: Vite Starter** | [`templates/app-service-builder-vite`](templates/app-service-builder-vite) | Web (`builder.yaml`) | Fast Vite + TypeScript web starter configured for Azure App Service Builder and ready to extend with Hosted Skills. |
| **App Service Builder: Agent & AI Gateway** | [`templates/app-service-builder-ai-gateway`](templates/app-service-builder-ai-gateway) | Web (`builder.yaml`) · Agent · AI Gateway | Python FastAPI + Microsoft Agent Framework streaming chat app deployable to App Service Builder and wired to AI Gateway. |
| **Dealership E2E Reference Sample** | [`templates/dealership-e2e`](templates/dealership-e2e) | Web · Agent · AI Gateway · 4 Hosted Skills · Sandbox · DTS Workflows · Connectors · SRE Agent | Complete runnable car-buying application (`driveline-web`, `deal-finder`, `inventory-search`, `trade-in-value`, `rate-sheet`, `deal-doc`, `prequal` sandbox, and `loan-approval` + `InventoryReplenishment` DTS workflows). |
| **Empty Starter App** | [`templates/empty-starter-app`](templates/empty-starter-app) | Web · Agent · AI Gateway · Hosted Skill | Minimal multi-service workspace shell ready to assemble with [`templates/build-blocks`](templates/build-blocks). |

---

## Quickstart: Run the Dealership Reference App Locally

Try the buyer web experience right away in offline mock mode (no Azure resources required):

```shell
cd templates/dealership-e2e/src/web
npm install
npm run dev
```

Open `http://localhost:3000` and try:

```text
Find me an EV under $40,000 with at least 250 miles of range
```

To run the full local live stack (Azurite + all 4 Azure Functions MCP Hosted Skills + `deal-finder` agent + Next.js web app) against Azure AI Gateway, follow [`templates/dealership-e2e/TESTING.md`](templates/dealership-e2e/TESTING.md) and [`templates/dealership-e2e/src/README.md`](templates/dealership-e2e/src/README.md):

- **macOS / Linux**:
  ```bash
  cd templates/dealership-e2e
  ./scripts/dev-start.sh
  ```
- **Windows PowerShell 7**:
  ```powershell
  cd templates\dealership-e2e
  .\scripts\dev-start.ps1
  ```

---

## Documentation (`/docs`)

- [Architecture & Reference Design](docs/azure-app-platform-plan.md)
- [Sandbox & AI Gateway Pattern](docs/sandbox-gateway-pattern.md)
- [Sandbox Boundary Validation](docs/sandbox-boundary-validation.md)
- [SRE Agent Self-Awareness & Human-Approved Inventory Replenishment](docs/sre-agent-self-awareness.md)
- [Template Shape & Materialization Contract](docs/template-authoring.md)
- [Loan Application Document Demo](docs/demos/loan-application/README.md)
- [Inventory Data Sourcing (`fueleconomy.gov`)](docs/data-sourcing.md)
