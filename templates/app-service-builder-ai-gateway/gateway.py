from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Callable, Sequence
import json
from typing import Any, Protocol

from agent_framework import Agent, MCPStreamableHTTPTool, Message, SupportsChatGetResponse
from agent_framework.openai import OpenAIChatCompletionClient
from azure.core.credentials import TokenCredential
from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
import httpx

from config import SampleConfig

AGENT_NAME = "app-service-builder-agent"
MCP_SKILL_NAME = "text-insights"
MCP_TOOL_NAME = "analyze_text"
AGENT_INSTRUCTIONS = (
    "You are a concise Azure App Service Builder and Azure AI Gateway document assistant. "
    "Use the deterministic `analyze_text` MCP tool from `text-insights` to obtain exact structural metrics "
    "(characters, words, lines, markdownHeadings, questions, estimatedTokens) before summarizing or answering "
    "questions about text or attached documents. Ground your reply in the tool outputs and never invent metrics."
)
REQUEST_TIMEOUT_SECONDS = 30.0
CONNECT_TIMEOUT_SECONDS = 5.0
OPENAI_NO_BEARER_AUTH = "workload-identity-auth"


class GatewayNotConfiguredError(RuntimeError):
    """Raised when Azure AI Gateway is not configured."""


class McpSkillUnavailableError(RuntimeError):
    """Raised when the MCP Hosted Skill endpoint cannot be connected or queried."""


class McpToolInputError(ValueError):
    """Raised when deterministic MCP tool validation rejects caller input."""


def _strip_placeholder_bearer_auth(chat_client: object) -> None:
    raw_client = getattr(chat_client, "client", None)
    if raw_client is None or not hasattr(raw_client, "_prepare_request"):
        return
    orig_prepare_request = raw_client._prepare_request

    async def _prepare_request_without_placeholder_bearer(request):
        await orig_prepare_request(request)
        if request.headers.get("authorization") == f"Bearer {OPENAI_NO_BEARER_AUTH}":
            del request.headers["authorization"]

    raw_client._prepare_request = _prepare_request_without_placeholder_bearer


def _extract_mcp_text(result: Any) -> str:
    if isinstance(result, str):
        return result
    if isinstance(result, Sequence):
        for item in result:
            text_val = getattr(item, "text", None)
            if isinstance(text_val, str) and text_val:
                return text_val
    return str(result or "")


class AgentStreamProvider(Protocol):
    async def aclose(self) -> None: ...

    def stream_text(self, messages: Sequence[dict[str, str]]) -> AsyncIterator[str]: ...


class GatewayAgentService:
    def __init__(
        self,
        config: SampleConfig,
        *,
        chat_client: SupportsChatGetResponse | None = None,
        mcp_tool: Any | None = None,
        credential_factory: Callable[[str], TokenCredential] = ManagedIdentityCredential,
        http_client: httpx.AsyncClient | None = None,
        request_timeout: float = REQUEST_TIMEOUT_SECONDS,
    ) -> None:
        self._config = config
        self._owns_http_client = http_client is None
        self._http_client = http_client or httpx.AsyncClient(
            timeout=httpx.Timeout(request_timeout, connect=CONNECT_TIMEOUT_SECONDS),
            trust_env=False,
        )
        self._owns_chat_client = chat_client is None
        self._owns_mcp_tool = mcp_tool is None
        self._request_timeout = request_timeout
        self._mcp_lock = asyncio.Lock()

        if chat_client is None and config.gateway_configured:
            if config.api_key:
                chat_client = OpenAIChatCompletionClient(
                    model=config.model,
                    base_url=config.model_url,
                    api_key=OPENAI_NO_BEARER_AUTH,
                    default_headers={"api-key": config.api_key},
                )
                _strip_placeholder_bearer_auth(chat_client)
            elif config.client_id:
                credential = credential_factory(client_id=config.client_id)
                chat_client = OpenAIChatCompletionClient(
                    model=config.model,
                    base_url=config.model_url,
                    credential=credential,
                )
            else:
                credential = DefaultAzureCredential()
                chat_client = OpenAIChatCompletionClient(
                    model=config.model,
                    base_url=config.model_url,
                    credential=credential,
                )

        self._chat_client = chat_client
        self._mcp_tool = (
            mcp_tool
            if mcp_tool is not None
            else MCPStreamableHTTPTool(
                name=MCP_SKILL_NAME,
                url=config.mcp_skill_url,
                allowed_tools=[MCP_TOOL_NAME],
                load_prompts=False,
                request_timeout=int(request_timeout),
            )
        )
        self._agent = (
            Agent(
                client=chat_client,
                name=AGENT_NAME,
                instructions=AGENT_INSTRUCTIONS,
                tools=[self._mcp_tool],
            )
            if chat_client is not None
            else None
        )

    @property
    def mcp_tool(self) -> Any:
        return self._mcp_tool

    async def _ensure_mcp_connected(self) -> None:
        if getattr(self._mcp_tool, "is_connected", False):
            return
        async with self._mcp_lock:
            if getattr(self._mcp_tool, "is_connected", False):
                return
            try:
                await self._mcp_tool.connect()
                functions = list(getattr(self._mcp_tool, "functions", ()))
                if not functions:
                    raise McpSkillUnavailableError(
                        f"MCP skill '{MCP_SKILL_NAME}' at {self._config.mcp_skill_url} exposed no tools."
                    )
            except McpSkillUnavailableError:
                raise
            except Exception as exc:
                raise McpSkillUnavailableError(
                    f"MCP Hosted Skill '{MCP_SKILL_NAME}' is unavailable at {self._config.mcp_skill_url}: {exc}"
                ) from exc

    async def ensure_ready(self) -> None:
        if self._agent is None:
            raise GatewayNotConfiguredError(
                "Azure AI Gateway is not configured. Set AI_GATEWAY_BASE_URL (or AZURE_AI_GATEWAY_HOST) and credentials."
            )
        await self._ensure_mcp_connected()

    async def analyze_text(self, text: str) -> dict[str, Any]:
        if not isinstance(text, str) or not text.strip():
            raise McpToolInputError("empty_text")
        await self._ensure_mcp_connected()
        try:
            raw_result = await self._mcp_tool.call_tool(MCP_TOOL_NAME, text=text)
        except Exception as exc:
            msg = str(exc)
            if any(token in msg.lower() for token in ("non-empty", "exceed", "nul or control", "must be a utf-8")):
                raise McpToolInputError(msg) from exc
            try:
                await self._mcp_tool.connect(reset=True)
                raw_result = await self._mcp_tool.call_tool(MCP_TOOL_NAME, text=text)
            except Exception as retry_exc:
                retry_msg = str(retry_exc)
                if any(token in retry_msg.lower() for token in ("non-empty", "exceed", "nul or control", "must be a utf-8")):
                    raise McpToolInputError(retry_msg) from retry_exc
                raise McpSkillUnavailableError(
                    f"MCP Hosted Skill '{MCP_SKILL_NAME}' failed at {self._config.mcp_skill_url}: {retry_exc}"
                ) from retry_exc

        text_payload = _extract_mcp_text(raw_result).strip()
        try:
            parsed = json.loads(text_payload)
        except json.JSONDecodeError as exc:
            raise McpToolInputError(text_payload or "invalid_mcp_tool_output") from exc
        if not isinstance(parsed, dict):
            raise McpToolInputError("invalid_mcp_tool_output")
        if "error" in parsed and "characters" not in parsed:
            raise McpToolInputError(str(parsed["error"]))
        return parsed

    async def aclose(self) -> None:
        if hasattr(self._mcp_tool, "close") and (
            self._owns_mcp_tool or getattr(self._mcp_tool, "is_connected", False)
        ):
            try:
                await self._mcp_tool.close()
            except Exception:
                pass
        if self._owns_chat_client and self._chat_client is not None and hasattr(self._chat_client, "close"):
            await self._chat_client.close()
        if self._owns_http_client:
            await self._http_client.aclose()

    async def stream_text(self, messages: Sequence[dict[str, str]]) -> AsyncIterator[str]:
        await self.ensure_ready()
        assert self._agent is not None
        agent_messages = [Message(item["role"], [item["content"]]) for item in messages]
        stream = self._agent.run(agent_messages, stream=True)
        iterator = stream.__aiter__()
        async with asyncio.timeout(self._request_timeout):
            while True:
                try:
                    update = await iterator.__anext__()
                except StopAsyncIteration:
                    break
                text = getattr(update, "text", "") or ""
                if text:
                    yield text

