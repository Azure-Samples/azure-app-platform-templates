# Dealership SRE Agent Self-Awareness & Human-Approved Inventory Replenishment

The Contoso Auto Dealership reference application (`templates/dealership-e2e`) pairs Azure infrastructure observability with domain-level operational self-awareness. A dedicated **Azure SRE Agent** (`sre-dealership-agent`) monitors the application's Azure Monitor, Application Insights, and Log Analytics layers while continuously evaluating dealership vehicle inventory levels. When stock in any vehicle category falls below threshold, the SRE Agent initiates a **Durable Task Scheduler (DTS)** replenishment workflow (`InventoryReplenishmentOrchestrator`) that pauses at a human approval gate before committing wholesale vehicle orders.

---

## Key Capabilities

1. **Dedicated Azure SRE Agent (`sre-dealership-agent`)**:
   - Provisioned as a `Microsoft.App/agents` resource via `infra/modules/sre-agent.bicep` or the Azure SRE CLI.
   - Managed identity granted `Reader` and `Monitoring Contributor` across the application resource group (App Service Builder web app, Application Insights, Log Analytics, AI Gateway, Hosted Skills, and Foundry backing resources).

2. **Dealership Inventory Health & Restock Endpoints (`templates/dealership-e2e/src/skills/inventory-search/`)**:
   - `evaluate_inventory_health()` and `apply_inventory_restock()` in `src/skills/inventory-search/tools/inventory_search.py`.
   - Exposed via `GET /api/inventory/health`, `POST /api/inventory/restock`, and the `@tool(name="inventory-health-check")` Hosted Skill MCP tool in `src/skills/inventory-search/function_app.py`.
   - Evaluates category stock against operational minimums:
     - **Total vehicles**: minimum `28` (default seed: `25` -> deficit `3`)
     - **Three-Row Family EVs** (`body_style = Three-Row EV`): minimum `4` (default seed: `2` -> deficit `2`)
     - **Hybrid Inventory** (`fuel_type = Hybrid`): minimum `5` (default seed: `3` -> deficit `2`)
   - Produces a deterministic wholesale replenishment recommendation for **4 vehicles ($166,400 USD total)**:
     - `2x 2025 Kia EV9 Wind AWD` (`Three-Row EV`, `$53,900` unit cost)
     - `2x 2025 Toyota RAV4 Hybrid XLE` (`Hybrid`, `$29,300` unit cost)

3. **Durable Task Scheduler (DTS) Replenishment Workflow with Human Approval (`templates/dealership-e2e/src/workflows/loan-approval/`)**:
   - `InventoryReplenishmentOrchestrator` in `src/workflows/loan-approval/function_app.py` and pure decision resolution (`resolve_replenishment_decision()`) in `src/workflows/loan-approval/orchestrator_logic.py`.
   - Stages the replenishment order (`PrepareReplenishmentOrder`), then pauses on `context.wait_for_external_event("ReplenishmentApprovalDecision")` with a 72-hour expiration timer.
   - HTTP endpoints:
     - `POST /api/inventory/replenish/start`: Starts `InventoryReplenishmentOrchestrator` and returns `instanceId`, `status: "awaiting_human_approval"`, and `decisionEndpoint`.
     - `POST /api/inventory/replenish/{instanceId}/decision`: Raises `ReplenishmentApprovalDecision` (`approve` or `reject`) with `approvedBy` and `notes`.
     - `GET /api/inventory/replenish/pending`: Lists orchestrations currently waiting in `Running` / `Pending` state.

4. **SRE Agent Tools, Skill, Sub-Agent, and Automations**:
   - **Tools (`PythonFunctionTool`)**:
     - `check_dealership_inventory_health` (`allow`: runs automatically during investigations and scheduled checks)
     - `start_inventory_replenishment_workflow` (`ask`: requires human confirmation in `review` mode)
     - `approve_inventory_replenishment_workflow` (`ask`: requires human manager approval before raising `ReplenishmentApprovalDecision`)
   - **Skill**: `dealership-inventory-steward` combining App Service / AI Gateway / Hosted Skills telemetry playbooks with the low-inventory DTS replenishment procedure.
   - **Sub-Agent**: `dealership-inventory-specialist` with tool and skill bindings.
   - **Scheduled Task**: `dealership-inventory-health-monitor` (`0 */6 * * *`, `agentMode: "review"`).
   - **HTTP Trigger**: `low-inventory-replenishment-webhook` (`agentMode: "review"`).

---

## Architecture

```text
+-----------------------------------------------------------------------------------+
|                        Azure SRE Agent (sre-dealership-agent)                     |
|  Sub-Agent: dealership-inventory-specialist  |  Skill: dealership-inventory-steward|
|  Scheduled Task: dealership-inventory-health-monitor (every 6h, review mode)      |
+-------------------+-----------------------------------+---------------------------+
                    |                                   |
     1. Azure Monitor / App Insights         2. Domain Self-Awareness Tools
        (Reader + Monitoring Contributor)       (check_dealership_inventory_health)
                    |                                   |
                    v                                   v
+-----------------------------------+   +-------------------------------------------+
|  Dealership Infrastructure Layers |   |  Inventory Search Hosted Skill (Port 7071)|
|  - App Service Builder web app    |   |  - GET  /api/inventory/health             |
|  - App Insights & Log Analytics   |   |  - POST /api/inventory/restock            |
|  - AI Gateway & Foundry Agent     |   |  - MCP Tool: inventory-health-check       |
+-----------------------------------+   +---------------------+---------------------+
                                                              |
                                                              | Low stock detected:
                                                              | Three-Row EV (2/4)
                                                              | Hybrid SUV (3/5)
                                                              v
                                        +-------------------------------------------+
                                        |  DTS Workflow App (src/workflows/...)     |
                                        |  - POST /api/inventory/replenish/start    |
                                        |  - InventoryReplenishmentOrchestrator     |
                                        |    1. PrepareReplenishmentOrder ($166.4k) |
                                        |    2. wait_for_external_event(            |
                                        |       "ReplenishmentApprovalDecision")    |
                                        |       <-- PAUSED FOR HUMAN APPROVAL       |
                                        |    3. ExecuteInventoryReplenishment       |
                                        +-------------------------------------------+
```

---

## Verification & Local Unit Tests

Inspect a deployed SRE Agent configuration with the Azure CLI SRE extension:

```shell
# Show the SRE Agent and its data-plane endpoint
az sre agent show -g <resource-group> -n sre-dealership-agent
az sre endpoint show -g <resource-group> --agent-name sre-dealership-agent

# List custom inventory & DTS workflow tools, skill, and subagent
az sre tool list -g <resource-group> --agent-name sre-dealership-agent -o table
az sre skill show -g <resource-group> --agent-name sre-dealership-agent -n dealership-inventory-steward
az sre subagent show -g <resource-group> --agent-name sre-dealership-agent -n dealership-inventory-specialist

# Inspect the scheduled task and HTTP trigger
az sre automation scheduled-task show -g <resource-group> --agent-name sre-dealership-agent -n dealership-inventory-health-monitor
az sre automation http-trigger show -g <resource-group> --agent-name sre-dealership-agent -n low-inventory-replenishment-webhook
```

Run the local inventory-health and DTS workflow unit tests:

```shell
cd templates/dealership-e2e/src/workflows/loan-approval
uv run pytest -q
```
