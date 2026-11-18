export const dynamic = "force-dynamic";

export async function GET() {
  const configuredAgent = process.env.AGENT_URL?.trim();
  if (!configuredAgent) {
    return Response.json({ ok: true, service: "driveline-web" }, { status: 200 });
  }
  const agentUrl = configuredAgent.replace(/\/+$/, "");
  try {
    const response = await fetch(`${agentUrl}/readiness`, {
      cache: "no-store",
      signal: AbortSignal.timeout(10_000)
    });
    const ok = response.ok;
    return Response.json(
      { ok, service: "driveline-web", agent: { ok, status: response.status } },
      { status: ok ? 200 : 503 }
    );
  } catch {
    return Response.json(
      { ok: false, service: "driveline-web", agent: { ok: false } },
      { status: 503 }
    );
  }
}

