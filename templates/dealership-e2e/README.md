# Dealership E2E Reference Sample

Local reference app for **Azure App Platform**. It includes a car-buying chat,
the `deal-finder` agent, and four Hosted Skills. The web app has zero runtime
agent simulation: chat requests always call the configured `deal-finder` agent
(`AGENT_URL`) and surface `agent_error` with startup guidance if the agent is
not running. Unwired loan-application submission controls stay visibly disabled
in the UI (`Apply (Unavailable)`), while synthetic vehicle inventory
(`inventory.json`) and synthetic pre-qualification credit fixtures
(`synthetic_credit_fixtures.py`) are preserved as test/sample data. The cloud
infrastructure in `infra/` is a precursor and is not ready for an end-to-end
deployment.

## Full Local Stack (Azurite + 4 Hosted Skills + Agent + Web)

1. Provision or connect an Azure AI Gateway so `src/agent/.env` contains `AZURE_AI_GATEWAY_ENDPOINT`, `AZURE_AI_GATEWAY_API_KEY`, and `AZURE_AI_GATEWAY_MODEL` (see [`src/README.md`](src/README.md) and [`TESTING.md`](TESTING.md)).
2. Start the full stack:
   - macOS / Linux:
     ```bash
     ./scripts/dev-start.sh
     ```
   - Windows PowerShell:
     ```powershell
     .\scripts\dev-start.ps1
     ```
3. Open `http://localhost:3000` and try:
   ```text
   Find me an EV under $40,000 with at least 250 miles of range
   ```
4. Stop the local stack when finished:
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
- `src/sandbox/prequal/`: Synthetic pre-qualification example; ACA isolation requires separate configuration
- `src/workflows/loan-approval/`: Durable Functions workflow examples; Teams delivery is a stub
- `infra-ai-gateway/`: Standalone `azd` + Bicep deployment for Azure AI Gateway and Foundry model deployments
- `infra/`: Incomplete Bicep infrastructure precursor
- `TESTING.md`: End-to-end local and live verification guide
