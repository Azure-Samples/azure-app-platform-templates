# Azure App Platform Documentation

Architecture, security boundaries, operational self-awareness, and template authoring guides for **Azure App Platform**.

## Architecture & Patterns

- [**Architecture & Reference Design**](azure-app-platform-plan.md): End-to-end platform architecture, capability tiers, Microsoft Entra identity model, AI Gateway single-choke-point topology, progressive diagrams, and Dealership E2E walkthrough.
- [**Sandbox & AI Gateway Pattern**](sandbox-gateway-pattern.md): When to use **Sandboxes Minimal** (1 agent + ACA Sandboxes egress proxy) vs **Sandboxes + AI Gateway Minimal** (multiple agents/skills sharing governed tools and models behind AI Gateway).
- [**Sandbox Boundary Validation**](sandbox-boundary-validation.md): Credential isolation, `egress-policy.yaml` Transform rules, runtime inspection without leaking secrets, and outbound denial verification.
- [**SRE Agent Self-Awareness & Inventory Replenishment**](sre-agent-self-awareness.md): How Azure SRE Agent monitors infrastructure telemetry and domain stock health, triggering human-approved Durable Task Scheduler (DTS) workflows.

## Templates & Data Notes

- [**Template Shape & Materialization Contract**](template-authoring.md): Directory layout, `.template` token substitution rules, port loaders, and `templates/catalog.json` schema.
- [**Loan Application Document Demo**](demos/loan-application/README.md): Walkthrough of untrusted document validation, prompt-injection blocking, and PII redaction in `templates/sandbox-gateway-minimal`.
- [**Inventory Data Sourcing**](data-sourcing.md): Real EPA `fueleconomy.gov` range/MPG specifications vs synthetic pricing and dealer fields in `inventory-search`.
