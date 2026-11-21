# driveline-web

Buyer-facing chat UI scaffold for Contoso Auto Dealership Demo (car-buying).  
This is tier **① Surface** from the platform plan, implemented as a TypeScript + Next.js App Router app.

## What this scaffold includes

- Chat interface for shopper prompts (streaming-friendly UI)
- `/api/chat` route that calls the live `deal-finder` agent (`AGENT_URL`) and
  surfaces `source: "agent_error"` with startup guidance when the agent is
  unreachable (zero runtime simulation)
- Vehicle shortlist results grid
- Deal status panel with visibly disabled customer email and `Apply (Unavailable)` controls (`Loan application submission workflow is not connected.`), backed by server-side `workflow_unavailable` defense-in-depth
- `builder.yaml` manifest for Azure App Service Builder (`standalone` Next.js runtime and `/api/health` readiness check)

## Run locally

In an Azure App Platform-created Dealer workspace, configure Azure AI Gateway
and run the repository-level `./scripts/dev-start.sh` or `.\scripts\dev-start.ps1`
launcher so Azurite, the four Hosted Skills, the `deal-finder` agent, and Next.js
all start together. The launcher supplies the allocated `WEB_PORT` to Next.js
and sets server-only `AGENT_URL` from the allocated `AGENT_PORT`; `3000` and
`8088` remain the fallbacks for manual runs.

## Live mode: calling the real deal-finder agent

`src/app/api/chat/route.ts` calls the agent (`src/agent`, `ResponsesHostServer`)
server-side via `src/lib/agent-client.ts`: this must happen server-side (not
from the browser) because the agent server sends no CORS headers.

Start the real agent alongside the web app:

```bash
# needs real AI Gateway credentials in src/agent/.env: see ../agent/README.md
cd src/agent
uv run main.py
```

Then `npm run dev` (in another terminal) and chat: replies come from the
real model/agent. `AGENT_URL` in `.env.example` defaults to
`http://127.0.0.1:8088`, matching the agent's default port; override it in
`.env.local` if your agent runs elsewhere. When `AGENT_URL` is unreachable,
`/api/chat` returns `source: "agent_error"` instructing you to start the full
stack with `./scripts/dev-start.sh`.
Live turns allow 120 seconds by default because they may include multiple
Hosted Skills/model calls. Override the deadline with `AGENT_TIMEOUT_MS`.

Once both terminals are running, use this prompt to verify the live agent
path end-to-end: the chat panel shows it above the input with a **"Copy &
fill"** button (copies it to your clipboard and drops it into the input box)
so you don't have to retype it:

```
Find me an EV under $40,000 with at least 250 miles of range
```

Watch the badge in the top-right of the page header: it reflects the
actual per-response `source` reported by `/api/chat`: **"Live agent"** with an
Octicon dot (green) means the reply came from the real agent, **"Live agent
request failed"** with an Octicon `x-circle` (red) means the agent was
unreachable or failed, and **"Approval unavailable"** means loan submission is
not connected.

Authored status and copy-feedback icons use the official
`@primer/octicons-react` package. Message content is not rewritten. The car
illustration on vehicle cards is resource imagery, not a control icon;
Octicons has no car/vehicle equivalent.

Tool-grounded updates from hosted skills (`inventory-search`, `rate-sheet`,
etc.) and approval-status events from the Durable Task Scheduler workflow are
still not wired into the chat/grid events: only the base agent reply is
live today. The same streaming event contract (`token`, `vehicles`, `status`,
`done`) is used either way, so UI components don't need to change as more of
the backend comes online.

## End-to-end tests

```bash
cd src/web
npm install
npx playwright install --with-deps chromium  # first run only
npm run test:e2e
npm run test:e2e:dev
```

The first command tests a production build. The second tests the development
server at `127.0.0.1`. UI rendering checks stub `/api/chat` inside `e2e/` via
`page.route("**/api/chat", ...)`, while real `/api/chat` checks verify
`agent_error` when `AGENT_URL` is unreachable and `workflow_unavailable` when
`apply` is posted. The development check also verifies that an untrusted origin
cannot load development assets.
