import { AgentClientError, fetchAgentReply, getAgentBaseUrl } from "@/lib/agent-client";
import type { ChatApiRequest, ChatStreamEvent, DealStage, ReplySource, Vehicle } from "@/lib/types";

const encoder = new TextEncoder();

interface ChatTurnResult {
  assistantReply: string;
  vehicles?: Vehicle[];
  stage?: DealStage;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function POST(request: Request) {
  const body = (await request.json()) as ChatApiRequest;

  let result: ChatTurnResult;
  let agentError: string | undefined;
  let source: ReplySource;

  if (body.action === "apply" || body.command === "apply") {
    source = "workflow_unavailable";
    agentError = "Application submission is not connected. No application was sent.";
    result = { assistantReply: "", stage: body.stage ?? "idle" };
  } else {
    // Call the live deal-finder agent server (`src/agent`, ResponsesHostServer)
    // server-side from the Next.js route handler so the browser never needs
    // cross-origin access. There is no runtime mock fallback: unreachable or
    // failed agent requests always surface `agent_error` with guidance.
    try {
      const assistantReply = await fetchAgentReply(body.messages);
      source = "agent";
      result = { assistantReply, stage: body.stage ?? "idle" };
    } catch (error) {
      const isUnreachable = error instanceof AgentClientError && error.kind === "unreachable";
      source = "agent_error";
      agentError = isUnreachable
        ? `Deal-finder agent is unavailable at ${getAgentBaseUrl()}. Start the full stack with ./scripts/dev-start.sh after configuring Azure AI Gateway.`
        : error instanceof Error
          ? error.message
          : String(error);
      result = { assistantReply: "", stage: body.stage ?? "idle" };
    }
  }

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const push = (event: ChatStreamEvent) => {
        controller.enqueue(encoder.encode(`${JSON.stringify(event)}\n`));
      };

      // Emit before tokens so the UI can label the reply as it streams in,
      // not just after the fact.
      push({ type: "source", value: source });

      if (agentError) {
        push({ type: "error", value: agentError });
        push({ type: "done" });
        controller.close();
        return;
      }

      const tokens = result.assistantReply.split(" ");
      for (const token of tokens) {
        push({ type: "token", value: `${token} ` });
        await sleep(16);
      }

      if (result.vehicles) {
        push({ type: "vehicles", value: result.vehicles });
      }

      if (result.stage) {
        push({ type: "status", value: result.stage });
      }

      push({ type: "done" });
      controller.close();
    }
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "application/x-ndjson; charset=utf-8",
      "Cache-Control": "no-store"
    }
  });
}
