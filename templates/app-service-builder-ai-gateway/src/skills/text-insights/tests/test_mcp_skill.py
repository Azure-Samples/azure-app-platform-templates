"""Unit and live Streamable HTTP MCP integration tests for the MCP Hosted Skill."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from urllib import error, request

SKILL_ROOT = Path(__file__).resolve().parents[1]
if str(SKILL_ROOT) not in sys.path:
    sys.path.insert(0, str(SKILL_ROOT))

from azure_functions_agents.discovery.tools import clear_tool_discovery_cache, discover_project_tools
from tools.analyze_text import MAX_TEXT_LENGTH, analyze_text, compute_text_metrics


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _parse_mcp_payload(raw_bytes: bytes, content_type: str) -> dict:
    body = raw_bytes.decode("utf-8").strip()
    if "text/event-stream" in content_type.lower() or body.startswith(("event:", "data:")):
        data_lines: list[str] = []
        messages: list[dict] = []
        for line in body.splitlines():
            if line.startswith("data:"):
                data_lines.append(line[5:].lstrip())
            elif not line.strip() and data_lines:
                joined = "\n".join(data_lines).strip()
                data_lines.clear()
                if joined:
                    messages.append(json.loads(joined))
        if data_lines:
            joined = "\n".join(data_lines).strip()
            if joined:
                messages.append(json.loads(joined))
        for msg in reversed(messages):
            if isinstance(msg, dict) and ("result" in msg or "error" in msg):
                return msg
        return messages[-1] if messages else {}
    return json.loads(body) if body else {}


def _mcp_post(
    mcp_url: str,
    payload: dict,
    *,
    session_id: str | None = None,
    expect_result: bool = True,
    timeout: float = 5.0,
) -> tuple[int, dict[str, str], dict]:
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    req = request.Request(
        mcp_url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with request.urlopen(req, timeout=timeout) as resp:
        resp_headers = {k.lower(): v for k, v in resp.headers.items()}
        content_type = resp_headers.get("content-type", "application/json")
        if not expect_result or resp.status == 202:
            return resp.status, resp_headers, {}
        if "text/event-stream" in content_type.lower():
            data_lines: list[str] = []
            while True:
                raw_line = resp.readline()
                if not raw_line:
                    break
                line = raw_line.decode("utf-8").rstrip("\r\n")
                if line.startswith("data:"):
                    data_lines.append(line[5:].lstrip())
                elif line == "" and data_lines:
                    joined = "\n".join(data_lines).strip()
                    data_lines.clear()
                    if joined:
                        msg = json.loads(joined)
                        if isinstance(msg, dict) and ("result" in msg or "error" in msg):
                            return resp.status, resp_headers, msg
            return resp.status, resp_headers, {}
        raw = resp.read()
        parsed = _parse_mcp_payload(raw, content_type) if raw.strip() else {}
        return resp.status, resp_headers, parsed


def _prepare_runnable_skill_dir(source_root: Path, temp_root: Path, *, force_copy: bool = False) -> Path:
    if not force_copy and (source_root / "pyproject.toml").is_file() and (source_root / "agents").is_dir():
        has_materialized_agent = any((source_root / "agents").glob("*.agent.md"))
        if has_materialized_agent and (source_root / "local.settings.json").is_file():
            return source_root

    target = temp_root / "text-insights"
    shutil.copytree(
        source_root,
        target,
        ignore=shutil.ignore_patterns(".venv", ".dev-temp", "__pycache__", ".pytest_cache"),
    )
    for template_path in list(target.rglob("*.template")):
        rendered_text = template_path.read_text(encoding="utf-8").replace("__SKILL_NAME__", "text-insights").replace("__BLOCK_NAME__", "text-insights")
        rendered_path = template_path.with_suffix("")
        rendered_path.write_text(rendered_text, encoding="utf-8")
        template_path.unlink()

    for plain_file in (target / "infra" / "main.bicep",):
        if plain_file.is_file():
            plain_file.write_text(
                plain_file.read_text(encoding="utf-8").replace("__SKILL_NAME__", "text-insights"),
                encoding="utf-8",
            )

    settings_file = target / "local.settings.json"
    example_file = target / "local.settings.json.example"
    if not settings_file.is_file() and example_file.is_file():
        shutil.copyfile(example_file, settings_file)
    return target


class AnalyzeTextUnitTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        clear_tool_discovery_cache()

    def test_valid_markdown_metrics_are_deterministic(self) -> None:
        sample = "# Overview\n\nHow fast is MCP?\n## Details\nPure Python execution!"
        metrics = compute_text_metrics(sample)
        self.assertEqual(metrics["characters"], len(sample))
        self.assertEqual(metrics["words"], 11)
        self.assertEqual(metrics["lines"], 5)
        self.assertEqual(metrics["markdownHeadings"], 2)
        self.assertEqual(metrics["questions"], 1)
        self.assertEqual(metrics["estimatedTokens"], (len(sample) + 3) // 4)
        self.assertEqual(json.loads(analyze_text(text=sample)), metrics)

    def test_rejects_empty_whitespace_oversized_and_nul_characters(self) -> None:
        with self.assertRaisesRegex(ValueError, "non-empty"):
            compute_text_metrics("")
        with self.assertRaisesRegex(ValueError, "non-empty"):
            compute_text_metrics("   \n\t  ")
        with self.assertRaisesRegex(ValueError, "NUL or control"):
            compute_text_metrics("hello\x00world")
        with self.assertRaisesRegex(ValueError, str(MAX_TEXT_LENGTH)):
            compute_text_metrics("a" * (MAX_TEXT_LENGTH + 1))

    async def test_runtime_discovers_analyze_text_tool(self) -> None:
        discovered = discover_project_tools(SKILL_ROOT)
        tools_by_name = {item.name: item for item in discovered.user_tools}
        self.assertIn("analyze_text", tools_by_name)
        raw = await tools_by_name["analyze_text"].invoke(
            arguments={"text": "# Title\nReady?"},
        )
        raw_text = raw if isinstance(raw, str) else getattr(raw[0], "text", str(raw))
        parsed = json.loads(raw_text)
        self.assertEqual(parsed["markdownHeadings"], 1)
        self.assertEqual(parsed["questions"], 1)


def _resolve_func_binary() -> str | None:
    user_func_dir = Path.home() / ".azure-functions"
    candidates: list[str] = []
    for name in ("func.cmd", "func.exe", "func"):
        candidate = user_func_dir / name
        if candidate.is_file():
            candidates.append(str(candidate))
    for name in ("func.cmd", "func"):
        found = shutil.which(name)
        if found and found not in candidates:
            if os.name == "nt" and found.lower().endswith(r"\azure functions core tools\func.exe"):
                dll = Path(found).with_name("Azure.Security.KeyVault.Secrets.dll")
                if not dll.is_file():
                    continue
            candidates.append(found)
    return candidates[0] if candidates else None


class LiveFunctionsMcpIntegrationTests(unittest.TestCase):
    def test_func_start_streamable_http_mcp_roundtrip(self) -> None:
        uv_bin = shutil.which("uv")
        func_bin = _resolve_func_binary()
        if not uv_bin or not func_bin:
            self.skipTest("uv and Azure Functions Core Tools (func) are required for live MCP test.")

        ver_proc = subprocess.run([func_bin, "--version"], capture_output=True, text=True, check=False)
        is_func_v5 = ver_proc.stdout.strip().startswith("5.")

        with tempfile.TemporaryDirectory(prefix="mcp-skill-", ignore_cleanup_errors=True) as temp_dir_str:
            temp_root = Path(temp_dir_str)
            runnable_dir = _prepare_runnable_skill_dir(
                SKILL_ROOT,
                temp_root,
                force_copy=is_func_v5 and (SKILL_ROOT / "requirements.txt").is_file(),
            )
            if runnable_dir != SKILL_ROOT and (SKILL_ROOT / "local.settings.json").is_file():
                shutil.copyfile(SKILL_ROOT / "local.settings.json", runnable_dir / "local.settings.json")
            elif runnable_dir == SKILL_ROOT and not (SKILL_ROOT / "local.settings.json").is_file():
                shutil.copyfile(SKILL_ROOT / "local.settings.json.example", SKILL_ROOT / "local.settings.json")
                self.addCleanup(lambda: (SKILL_ROOT / "local.settings.json").unlink(missing_ok=True))

            port = _free_port()
            env = os.environ.copy()
            env.pop("VIRTUAL_ENV", None)
            func_temp = temp_root / "func-temp"
            func_temp.mkdir(parents=True, exist_ok=True)
            env["TEMP"] = str(func_temp)
            env["TMP"] = str(func_temp)
            index_url = env.get("PIP_INDEX_URL") or env.get("UV_INDEX_URL") or env.get("UV_DEFAULT_INDEX")
            if index_url:
                env["PIP_INDEX_URL"] = index_url
                env["UV_INDEX_URL"] = index_url
                env["UV_DEFAULT_INDEX"] = index_url

            if (runnable_dir / "pyproject.toml").is_file():
                subprocess.run([uv_bin, "sync"], cwd=str(runnable_dir), env=env, check=True)
                if is_func_v5 and runnable_dir != SKILL_ROOT:
                    (runnable_dir / "requirements.txt").unlink(missing_ok=True)

            func_args = [uv_bin, "run", "--no-sync", func_bin, "start", "--port", str(port)]
            if is_func_v5:
                func_args.extend(["--no-tui", "--no-azurite", "--offline"])

            log_path = temp_root / "func.log"
            with log_path.open("w", encoding="utf-8") as log_file:
                proc = subprocess.Popen(
                    func_args,
                    cwd=str(runnable_dir),
                    env=env,
                    stdout=log_file,
                    stderr=subprocess.STDOUT,
                    start_new_session=(os.name != "nt"),
                )
                try:
                    mcp_url = f"http://127.0.0.1:{port}/runtime/webhooks/mcp"
                    health_url = f"http://127.0.0.1:{port}/api/health"
                    session_id: str | None = None
                    init_payload = {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "protocolVersion": "2025-03-26",
                            "capabilities": {},
                            "clientInfo": {"name": "mcp-skill-test", "version": "0.1.0"},
                        },
                    }
                    deadline = time.monotonic() + 90.0
                    init_result = None
                    while time.monotonic() < deadline:
                        if proc.poll() is not None:
                            output = log_path.read_text(encoding="utf-8", errors="replace")
                            self.fail(f"func start exited early ({proc.returncode}):\n{output}")
                        try:
                            status, headers, parsed = _mcp_post(mcp_url, init_payload, timeout=2.0)
                            if status == 200 and isinstance(parsed.get("result"), dict):
                                session_id = headers.get("mcp-session-id")
                                init_result = parsed["result"]
                                break
                        except (error.URLError, TimeoutError, ConnectionError, json.JSONDecodeError):
                            pass
                        time.sleep(0.2)

                    if init_result is None:
                        output = log_path.read_text(encoding="utf-8", errors="replace")
                        self.fail(f"MCP endpoint did not become ready on port {port}:\n{output}")

                    with request.urlopen(health_url, timeout=5.0) as health_resp:
                        self.assertEqual(health_resp.status, 200)
                        health_json = json.loads(health_resp.read().decode("utf-8"))
                        self.assertEqual(health_json["status"], "ok")

                    _mcp_post(
                        mcp_url,
                        {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
                        session_id=session_id,
                        expect_result=False,
                    )

                    list_status, _, list_body = _mcp_post(
                        mcp_url,
                        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
                        session_id=session_id,
                    )
                    self.assertEqual(list_status, 200)
                    tools_list = list_body["result"]["tools"]
                    tool_names = [t["name"] for t in tools_list]
                    self.assertIn("analyze_text", tool_names)

                    sample_md = "# Release Checklist\n\nIs the MCP endpoint deterministic?\n## Verification\nAll metrics match."
                    expected = compute_text_metrics(sample_md)

                    t0 = time.perf_counter()
                    call_status, _, call_body = _mcp_post(
                        mcp_url,
                        {
                            "jsonrpc": "2.0",
                            "id": 3,
                            "method": "tools/call",
                            "params": {
                                "name": "analyze_text",
                                "arguments": {"text": sample_md},
                            },
                        },
                        session_id=session_id,
                    )
                    elapsed_ms = (time.perf_counter() - t0) * 1000.0
                    self.assertEqual(call_status, 200)
                    call_result = call_body["result"]
                    self.assertFalse(call_result.get("isError", False), call_result)
                    content_items = call_result.get("content", [])
                    self.assertTrue(content_items)
                    returned_metrics = json.loads(content_items[0]["text"])
                    self.assertEqual(returned_metrics, expected)
                    self.assertLess(elapsed_ms, 5000.0)
                finally:
                    if proc.poll() is None:
                        if os.name == "nt":
                            subprocess.run(
                                ["taskkill.exe", "/F", "/T", "/PID", str(proc.pid)],
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL,
                                check=False,
                            )
                            try:
                                proc.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                proc.kill()
                                proc.wait(timeout=5)
                        else:
                            try:
                                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                            try:
                                proc.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                try:
                                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                                except ProcessLookupError:
                                    pass
                                proc.wait(timeout=5)

            close_deadline = time.monotonic() + 5.0
            port_open = True
            while time.monotonic() < close_deadline:
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as check_sock:
                    check_sock.settimeout(0.2)
                    if check_sock.connect_ex(("127.0.0.1", port)) != 0:
                        port_open = False
                        break
                time.sleep(0.1)
            self.assertFalse(port_open, f"func start child process left port {port} open after cleanup")


if __name__ == "__main__":
    unittest.main()
