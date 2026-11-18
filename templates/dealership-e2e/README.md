# Dealership E2E Reference Sample

Complete multi-tier reference application for **Azure App Platform**: a conversational car-buying experience (`driveline-web` on App Service Builder) backed by the `deal-finder` hosted agent, **Azure AI Gateway** governing model and MCP tool traffic, four **Azure Functions Hosted Skills** (`inventory-search`, `trade-in-value`, `rate-sheet`, `deal-doc`), an isolated **ACA Sandbox** (`prequal`) for PII-safe loan pre-qualification, **Durable Task Scheduler (DTS)** human-in-the-loop approval workflows (`LoanApprovalOrchestrator` and `InventoryReplenishmentOrchestrator`), and **Azure SRE Agent** operational self-awareness.

## Quickstart (Mock Mode, No Azure Subscription Needed)

```shell
cd src/web
npm install
npm run dev
```

Open `http://localhost:3000` and try:

```text
Find me an EV under $40,000 with at least 250 miles of range
```

## Full Local Stack (Azurite + 4 Hosted Skills + Agent + Web)

1. Provision or connect an Azure AI Gateway so `src/agent/.env` contains `AI_GATEWAY_BASE_URL`, `AI_GATEWAY_API_KEY`, and `AI_GATEWAY_MODEL` (see [`src/README.md`](src/README.md) and [`TESTING.md`](TESTING.md)).
2. Start the full stack:
   - macOS / Linux:
     ```bash
     ./scripts/dev-start.sh
     ```
   - Windows PowerShell:
     ```powershell
     .\scripts\dev-start.ps1
     ```
3. Stop the local stack when finished:
   - macOS / Linux:
     ```bash
     ./scripts/dev-stop.sh
     ```
   - Windows PowerShell:
     ```powershell
     .\scripts\dev-stop.ps1
     ```

## Directory Layout

- `src/web/`: Next.js buyer chat & vehicle shortlist UI (`builder.yaml` for App Service Builder)
- `src/agent/`: Python Microsoft Agent Framework hosted agent (`deal-finder`, Responses protocol)
- `src/skills/`: Four Azure Functions MCP Hosted Skills (`inventory-search`, `trade-in-value`, `rate-sheet`, `deal-doc`)
- `src/sandbox/prequal/`: Hardware-isolated ACA Sandbox container for PII loan pre-qualification with default-deny egress
- `src/workflows/loan-approval/`: Durable Functions + DTS orchestrations for manager deal approval and inventory replenishment
- `infra-ai-gateway/`: Standalone `azd` + Bicep deployment for Azure AI Gateway and Foundry model deployments
- `infra/`: Modular Bicep infrastructure across all platform capabilities
- `TESTING.md`: End-to-end local and live verification guide
