"""Focused MCP + AI Gateway boundary tests for the Empty Starter local agent."""

from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from urllib import error, request

AGENT_DIR = Path(__file__).resolve().parents[1]


def _load_agent_module(temp_root: Path):
    template_path = AGENT_DIR / "main.py.template"
    source_path = AGENT_DIR / "main.py"
    raw = (
        template_path.read_text(encoding="utf-8").replace("__SKILL_NAME__", "text-insights")
        if template_path.is_file()
        else source_path.read_text(encoding="utf-8")
    )
    rendered = temp_root / "src" / "agent" / "main.py"
    rendered.parent.mkdir(parents=True, exist_ok=True)
    rendered.write_text(raw, encoding="utf-8")

    (temp_root / "config").mkdir(parents=True, exist_ok=True)
    (temp_root / "config" / "domain.json").write_text(
        json.dumps({"name": "starter-pilot", "purpose": "Verify MCP wiring"}),
        encoding="utf-8",
    )
    prompts_dir = temp_root / "src" / "agent" / "prompts"
    prompts_dir.mkdir(parents=True, exist_ok=True)
    (prompts_dir / "system.md").write_text(
        "Ground every answer in deterministic analyze_text metrics.",
        encoding="utf-8",
    )

    spec = importlib.util.spec_from_file_location("starter_agent_main", rendered)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _http_json(url: str, *, method: str = "GET", payload: dict | None = None) -> tuple[int, dict]:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Content-Type": "application/json"} if payload is not None else {}
    req = request.Request(url, data=data, headers=headers, method=method)
    try:
        with request.urlopen(req, timeout=5.0) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8"))


class FakeMcpAndGatewayServers:
    """In-test HTTP servers speaking real JSON-RPC MCP and OpenAI chat completions."""

    def __init__(self) -> None:
        self.mcp_calls: list[str] = []
        self.gateway_requests: list[dict] = []
        self._mcp_server: ThreadingHTTPServer | None = None
        self._gw_server: ThreadingHTTPServer | None = None

    def start(self) -> tuple[str, str]:
        outer = self

        class McpHandler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                msg = json.loads(self.rfile.read(length).decode("utf-8"))
                method = msg.get("method", "")
                outer.mcp_calls.append(method)
                if method == "initialize":
                    body = json.dumps(
                        {
                            "jsonrpc": "2.0",
                            "id": msg["id"],
                            "result": {
                                "protocolVersion": "2025-03-26",
                                "capabilities": {"tools": {}},
                                "serverInfo": {"name": "test-mcp", "version": "0.1.0"},
                            },
                        }
                    ).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Mcp-Session-Id", "session-test-1")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if method == "notifications/initialized":
                    self.send_response(202)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if method == "tools/list":
                    body = json.dumps(
                        {
                            "jsonrpc": "2.0",
                            "id": msg["id"],
                            "result": {
                                "tools": [
                                    {
                                        "name": "analyze_text",
                                        "description": "Deterministic metrics",
                                        "inputSchema": {
                                            "type": "object",
                                            "properties": {"text": {"type": "string"}},
                                            "required": ["text"],
                                        },
                                    }
                                ]
                            },
                        }
                    ).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if method == "tools/call":
                    text = msg["params"]["arguments"]["text"]
                    metrics = {
                        "characters": len(text),
                        "words": len(text.split()),
                        "lines": len(text.splitlines()),
                        "markdownHeadings": sum(1 for line in text.splitlines() if line.lstrip().startswith("#")),
                        "questions": text.count("?"),
                        "estimatedTokens": max(1, (len(text) + 3) // 4),
                    }
                    body = json.dumps(
                        {
                            "jsonrpc": "2.0",
                            "id": msg["id"],
                            "result": {
                                "content": [{"type": "text", "text": json.dumps(metrics)}]
                            },
                        }
                    ).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                self.send_error(400)

            def log_message(self, _fmt: str, *_args: object) -> None:
                return

        class GatewayHandler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
                outer.gateway_requests.append(payload)
                body = json.dumps(
                    {
                        "id": "chatcmpl-1",
                        "choices": [
                            {
                                "index": 0,
                                "message": {
                                    "role": "assistant",
                                    "content": "Grounded summary from deterministic MCP metrics.",
                                },
                            }
                        ],
                    }
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, _fmt: str, *_args: object) -> None:
                return

        self._mcp_server = ThreadingHTTPServer(("127.0.0.1", 0), McpHandler)
        self._gw_server = ThreadingHTTPServer(("127.0.0.1", 0), GatewayHandler)
        threading.Thread(target=self._mcp_server.serve_forever, daemon=True).start()
        threading.Thread(target=self._gw_server.serve_forever, daemon=True).start()
        mcp_port = self._mcp_server.server_address[1]
        gw_port = self._gw_server.server_address[1]
        return (
            f"http://127.0.0.1:{mcp_port}/runtime/webhooks/mcp",
            f"http://127.0.0.1:{gw_port}/default/models/openai/v1",
        )

    def stop(self) -> None:
        for srv in (self._mcp_server, self._gw_server):
            if srv is not None:
                srv.shutdown()
                srv.server_close()


class EmptyStarterAgentMcpTests(unittest.TestCase):
    def test_unconfigured_gateway_and_unreachable_mcp_fail_with_503(self) -> None:
        with tempfile.TemporaryDirectory(prefix="starter-agent-") as tmp:
            temp_root = Path(tmp)
            mod = _load_agent_module(temp_root)
            unused_port = _free_port()

            runtime_no_gw = mod.StarterAgentRuntime(
                app_root=temp_root,
                env_overrides={
                    "SKILL_TEXT_INSIGHTS_PORT": str(unused_port),
                    "AI_GATEWAY_BASE_URL": "",
                    "AZURE_AI_GATEWAY_ENDPOINT": "",
                    "AZURE_AI_GATEWAY_HOST": "",
                    "AI_GATEWAY_API_KEY": "",
                    "AZURE_AI_GATEWAY_API_KEY": "",
                },
            )
            srv = mod.create_server("127.0.0.1", 0, runtime=runtime_no_gw)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            base_url = f"http://127.0.0.1:{srv.server_address[1]}"
            try:
                status, health = _http_json(f"{base_url}/health")
                self.assertEqual(status, 200)
                self.assertFalse(health["gatewayConfigured"])
                self.assertEqual(
                    health["mcpSkillUrl"],
                    f"http://127.0.0.1:{unused_port}/runtime/webhooks/mcp",
                )

                resp_status, resp_body = _http_json(
                    f"{base_url}/responses",
                    method="POST",
                    payload={"message": "# Title\nCheck?"},
                )
                self.assertEqual(resp_status, 503)
                self.assertEqual(resp_body["error"]["code"], "gateway_not_configured")

                tool_status, tool_body = _http_json(
                    f"{base_url}/api/tools/analyze_text",
                    method="POST",
                    payload={"text": "# Title\nCheck?"},
                )
                self.assertEqual(tool_status, 503)
                self.assertEqual(tool_body["error"]["code"], "mcp_skill_unavailable")
            finally:
                srv.shutdown()
                srv.server_close()
                runtime_no_gw.close()

            runtime_no_mcp = mod.StarterAgentRuntime(
                app_root=temp_root,
                env_overrides={
                    "MCP_SKILL_URL": f"http://127.0.0.1:{unused_port}/runtime/webhooks/mcp",
                    "AI_GATEWAY_BASE_URL": "https://gw.example.test/default/models/openai/v1",
                    "AI_GATEWAY_API_KEY": "test-key",
                },
            )
            srv2 = mod.create_server("127.0.0.1", 0, runtime=runtime_no_mcp)
            threading.Thread(target=srv2.serve_forever, daemon=True).start()
            base_url2 = f"http://127.0.0.1:{srv2.server_address[1]}"
            try:
                resp_status2, resp_body2 = _http_json(
                    f"{base_url2}/responses",
                    method="POST",
                    payload={"message": "# Title\nCheck?"},
                )
                self.assertEqual(resp_status2, 503)
                self.assertEqual(resp_body2["error"]["code"], "mcp_skill_unavailable")
            finally:
                srv2.shutdown()
                srv2.server_close()
                runtime_no_mcp.close()

    def test_persistent_mcp_action_and_gateway_turn_reuse_session(self) -> None:
        with tempfile.TemporaryDirectory(prefix="starter-agent-live-") as tmp:
            temp_root = Path(tmp)
            mod = _load_agent_module(temp_root)
            upstreams = FakeMcpAndGatewayServers()
            mcp_url, gw_url = upstreams.start()
            runtime = mod.StarterAgentRuntime(
                app_root=temp_root,
                env_overrides={
                    "MCP_SKILL_URL": mcp_url,
                    "AI_GATEWAY_BASE_URL": gw_url,
                    "AI_GATEWAY_API_KEY": "test-key",
                    "AI_GATEWAY_MODEL": "gpt-5-mini",
                },
            )
            srv = mod.create_server("127.0.0.1", 0, runtime=runtime)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            base_url = f"http://127.0.0.1:{srv.server_address[1]}"
            try:
                st1, action1 = _http_json(
                    f"{base_url}/api/tools/analyze_text",
                    method="POST",
                    payload={"text": "# Doc\nOne question?"},
                )
                self.assertEqual(st1, 200)
                self.assertEqual(action1["metrics"]["markdownHeadings"], 1)
                self.assertEqual(action1["metrics"]["questions"], 1)
                self.assertEqual(len(upstreams.gateway_requests), 0)

                st2, turn = _http_json(
                    f"{base_url}/responses",
                    method="POST",
                    payload={"message": "# Doc\nSecond question?"},
                )
                self.assertEqual(st2, 200)
                self.assertEqual(turn["tool"], "analyze_text")
                self.assertEqual(turn["toolResult"]["questions"], 1)
                self.assertIn("Grounded summary", turn["message"])
                self.assertEqual(len(upstreams.gateway_requests), 1)
                self.assertEqual(runtime.mcp_client.initialize_count, 1)
                self.assertEqual(upstreams.mcp_calls.count("initialize"), 1)
                self.assertEqual(upstreams.mcp_calls.count("tools/call"), 2)
            finally:
                srv.shutdown()
                srv.server_close()
                runtime.close()
                upstreams.stop()


if __name__ == "__main__":
    unittest.main()
