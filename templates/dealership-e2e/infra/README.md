# Azure App Platform infrastructure

This directory is the `azd`/Bicep precursor for the Contoso Auto Dealership reference application.
`main.bicep` deploys at subscription scope, creates the POC resource group, and
then invokes one resource-group-scoped module per platform tier:

| Module | POC responsibility |
| --- | --- |
| `gateway.bicep` | AI Gateway (API Management) placeholder |
| `agent.bicep` | Foundry account/project for the hosted agent |
| `skills.bicep` | Python skill Function Apps on Flex Consumption |
| `sandbox.bicep` | Container Apps SandboxGroup |
| `workflows.bicep` | Durable Task Scheduler and workflow Function App |
| `web.bicep` | App Service Builder / ACA Express-compatible web placeholder |
| `connectors.bicep` | Connector Namespace |
| `sre-agent.bicep` | Azure SRE Agent resource |

The modules intentionally leave product-specific policy, connections, and RBAC
as TODOs. In particular, the Gateway module must be replaced with the proven
Bicep and lifecycle hooks from
[`Azure-Samples/simple-foundry-hosted-agent-python-aigateway`](https://github.com/Azure-Samples/simple-foundry-hosted-agent-python-aigateway).
API Management deletion includes soft-delete, purge, and identity-cleanup
phases; treating name availability as completed cleanup can block reprovisioning
for days.

## Run

Install the Azure Developer CLI and the Foundry extension, then authenticate
with Microsoft Entra ID:

```sh
azd ext install microsoft.foundry
azd auth login
azd env new dealership-demo
azd up
```

No application or infrastructure path should use access keys. Local development,
CI, and Azure workloads use developer identity, workload identity federation,
or managed identity.

## Region pinning

The primary location is fixed to `eastus2`. The only exception is Connector
Namespace, which `connectors.bicep` explicitly pins to `westcentralus`. Do not
make Connector Namespace inherit the resource group's location. Re-check preview
regional availability before production use.

## Modular layout

Each platform capability lives in its own Bicep module under `infra/modules/` so application teams can reuse the same infrastructure substrate across scenarios.
