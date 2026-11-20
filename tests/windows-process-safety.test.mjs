import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { cp, link, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const templates = fileURLToPath(new URL("../templates", import.meta.url));

for (const name of [
  "empty-starter-app", "app-service-builder-vite", "app-service-builder-ai-gateway",
  "sandboxes-minimal", "sandbox-gateway-minimal", "dealership-e2e", "shared/dealer",
]) {
  test(`${name} stops only a process with a matching creation time`, {
    skip: process.platform !== "win32" && "Windows process identity test",
    timeout: 30_000,
  }, async t => {
    const root = await mkdtemp(path.join(tmpdir(), "template-process-safety-"));
    const scripts = path.join(root, "scripts");
    const run = path.join(root, ".dev-run");
    await mkdir(scripts);
    await mkdir(run);
    const sourceFile = name === "dealership-e2e" || name === "shared/dealer"
      ? "dev-stop.ps1" : "dev-stop.ps1.template";
    await cp(path.join(templates, name, "scripts", sourceFile), path.join(scripts, "dev-stop.ps1"));
    const state = path.join(run, "processes.json");
    const child = spawn(process.execPath, ["-e", "console.log('ready'); setInterval(() => {}, 1000)"], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    const exited = once(child, "exit");
    t.after(async () => {
      if (child.exitCode === null && child.signalCode === null) child.kill();
      await exited;
      await rm(root, { recursive: true, force: true });
    });
    await once(child.stdout, "data");
    const identity = spawnSync("pwsh", [
      "-NoProfile", "-Command", `(Get-Process -Id ${child.pid}).StartTime.ToUniversalTime().ToString('O')`,
    ], { encoding: "utf8" });
    assert.equal(identity.status, 0, identity.stderr);
    const startedAt = identity.stdout.trim();
    const env = { ...process.env };
    delete env.DEALER_REPO_ROOT;
    const stop = () => spawnSync("pwsh", ["-NoProfile", "-File", path.join(scripts, "dev-stop.ps1")], {
      encoding: "utf8", env,
    });
    const record = value => JSON.stringify([{ name: "fixture", port: 4321, pid: child.pid, ...value }]);

    await writeFile(state, record({}));
    const missingIdentity = stop();
    assert.notEqual(missingIdentity.status, 0);
    assert.match(missingIdentity.stderr, /no recorded start identity/i);
    const retained = JSON.parse(await readFile(state, "utf8"));
    assert.equal((Array.isArray(retained) ? retained[0] : retained).pid, child.pid);
    assert.doesNotThrow(() => process.kill(child.pid, 0));

    await writeFile(state, record({ startedAt: "2000-01-01T00:00:00.0000000Z" }));
    const staleIdentity = stop();
    assert.equal(staleIdentity.status, 0, staleIdentity.stderr);
    assert.match(staleIdentity.stdout, /PID was reused/i);
    assert.doesNotThrow(() => process.kill(child.pid, 0));

    await mkdir(run, { recursive: true });
    await writeFile(state, record({ startedAt }));
    const owned = stop();
    assert.equal(owned.status, 0, owned.stderr);
    await exited;
    await assert.rejects(readFile(state), { code: "ENOENT" });
  });
}

test("the Vite starter records and stops its own process while preserving package policy", {
  skip: process.platform !== "win32" && "Windows process lifecycle test",
  timeout: 60_000,
}, async t => {
  const root = await mkdtemp(path.join(tmpdir(), "vite-lifecycle-"));
  const scripts = path.join(root, "scripts");
  const bin = path.join(root, "bin");
  const state = path.join(root, ".dev-run", "processes.json");
  for (const dir of [scripts, bin, path.join(root, "node_modules", "vite"), path.join(root, "dist")]) {
    await mkdir(dir, { recursive: true });
  }
  await writeFile(path.join(root, "dist", "index.html"), "fixture");
  await writeFile(path.join(scripts, "load-ports.ps1"), "function Import-AppPorts($Root) {}\n");
  for (const script of ["dev-start", "dev-stop"]) {
    await cp(path.join(templates, "app-service-builder-vite", "scripts", `${script}.ps1.template`),
      path.join(scripts, `${script}.ps1`));
  }
  await writeFile(path.join(bin, "web.cjs"), [
    "require('node:http').createServer((_req,res) => {",
    "res.end(JSON.stringify({ index: process.env.UV_INDEX_URL, offline: process.env.UV_OFFLINE }));",
    "}).listen(Number(process.env.WEB_PORT), '127.0.0.1');",
  ].join("\n"));
  await writeFile(path.join(bin, "npx.cmd"), `@echo off\r\n"${process.execPath}" "%~dp0web.cjs"\r\n`);
  const probe = net.createServer();
  await new Promise((resolve, reject) => probe.once("error", reject).listen(0, "127.0.0.1", resolve));
  const port = probe.address().port;
  await new Promise((resolve, reject) => probe.close(error => error ? reject(error) : resolve()));
  const env = {
    ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, WEB_PORT: String(port),
    PIP_INDEX_URL: "https://packages.example.test/simple", UV_INDEX_URL: "https://other.example.test/simple",
    UV_DEFAULT_INDEX: "", UV_OFFLINE: "1",
  };
  delete env.DEALER_REPO_ROOT;
  const invoke = async script => {
    const runner = spawn("pwsh", ["-NoProfile", "-File", path.join(scripts, `${script}.ps1`)], {
      env, stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    runner.stdout.on("data", data => { output += data; });
    runner.stderr.on("data", data => { output += data; });
    const [code] = await once(runner, "exit");
    runner.stdout.destroy();
    runner.stderr.destroy();
    return { code, output };
  };
  t.after(async () => {
    try { await readFile(state); }
    catch (error) { if (error.code === "ENOENT") return rm(root, { recursive: true, force: true }); throw error; }
    const stopped = await invoke("dev-stop");
    assert.equal(stopped.code, 0, stopped.output);
    await rm(root, { recursive: true, force: true });
  });

  const started = await invoke("dev-start");
  assert.equal(started.code, 0, started.output);
  const response = await fetch(`http://127.0.0.1:${port}/`);
  assert.deepEqual(await response.json(), { index: "https://packages.example.test/simple", offline: "1" });
  const records = JSON.parse(await readFile(state, "utf8"));
  const record = Array.isArray(records) ? records[0] : records;
  assert.ok(record.pid > 0 && record.startedAt);
  const stopped = await invoke("dev-stop");
  assert.equal(stopped.code, 0, stopped.output);
  await assert.rejects(readFile(state), { code: "ENOENT" });
  await assert.rejects(fetch(`http://127.0.0.1:${port}/`));
});

test("the Vite starter stops when dependency installation fails", {
  skip: process.platform !== "win32" && "Windows startup test",
  timeout: 30_000,
}, async t => {
  const root = await mkdtemp(path.join(tmpdir(), "vite-install-failure-"));
  const scripts = path.join(root, "scripts");
  const bin = path.join(root, "bin");
  await mkdir(scripts);
  await mkdir(bin);
  await writeFile(path.join(scripts, "load-ports.ps1"), "function Import-AppPorts($Root) {}\n");
  for (const script of ["dev-start", "dev-stop"]) {
    await cp(path.join(templates, "app-service-builder-vite", "scripts", `${script}.ps1.template`),
      path.join(scripts, `${script}.ps1`));
  }
  await writeFile(path.join(bin, "npm.cmd"), "@echo off\r\nexit /b 21\r\n");
  await writeFile(path.join(bin, "npx.cmd"), `@echo off\r\necho started>"${path.join(root, "web-started")}"\r\nexit /b 1\r\n`);
  t.after(() => rm(root, { recursive: true, force: true }));
  const result = spawnSync("pwsh", ["-NoProfile", "-File", path.join(scripts, "dev-start.ps1")], {
    encoding: "utf8", env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}` },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /dependency installation failed \(exit 21\)/i);
  await assert.rejects(readFile(path.join(root, "web-started")), { code: "ENOENT" });
});

test("the Builder gateway starter does not launch web when its agent stays unhealthy", {
  skip: process.platform !== "win32" && "Windows startup test",
  timeout: 70_000,
}, async t => {
  const root = await mkdtemp(path.join(tmpdir(), "builder-agent-unhealthy-"));
  const scripts = path.join(root, "scripts");
  const agent = path.join(root, "src", "agent");
  const bin = path.join(root, "bin");
  for (const dir of [scripts, agent, bin]) await mkdir(dir, { recursive: true });
  await writeFile(path.join(scripts, "load-ports.ps1"), "function Import-AppPorts($Root) {}\n");
  for (const script of ["dev-start", "dev-stop"]) {
    await cp(path.join(templates, "app-service-builder-ai-gateway", "scripts", `${script}.ps1.template`),
      path.join(scripts, `${script}.ps1`));
  }
  await link(process.execPath, path.join(bin, "uv.exe"));
  await writeFile(path.join(agent, "main.py"), "# fixture\n");
  await writeFile(path.join(agent, "run"), [
    "require('node:http').createServer((_req,res) => { res.statusCode=503; res.end('not ready'); })",
    ".listen(Number(process.env.AGENT_PORT), '127.0.0.1');",
  ].join("\n"));
  await writeFile(path.join(root, "run"), [
    `require('node:fs').writeFileSync(${JSON.stringify(path.join(root, "web-started"))}, 'started');`,
    "require('node:http').createServer((_req,res) => res.end('ok'))",
    ".listen(Number(process.env.WEB_PORT), '127.0.0.1');",
  ].join("\n"));
  const ports = [];
  for (let i = 0; i < 2; i++) {
    const probe = net.createServer();
    await new Promise((resolve, reject) => probe.once("error", reject).listen(0, "127.0.0.1", resolve));
    ports.push(probe.address().port);
    await new Promise((resolve, reject) => probe.close(error => error ? reject(error) : resolve()));
  }
  const env = {
    ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`,
    AGENT_PORT: String(ports[0]), WEB_PORT: String(ports[1]),
  };
  const invoke = async script => {
    const runner = spawn("pwsh", ["-NoProfile", "-File", path.join(scripts, `${script}.ps1`)], {
      env, stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    runner.stdout.on("data", data => { output += data; });
    runner.stderr.on("data", data => { output += data; });
    const [code] = await once(runner, "exit");
    runner.stdout.destroy();
    runner.stderr.destroy();
    return { code, output };
  };
  const state = path.join(root, ".dev-run", "processes.json");
  t.after(async () => {
    try { await readFile(state); }
    catch (error) { if (error.code === "ENOENT") return rm(root, { recursive: true, force: true }); throw error; }
    const stopped = await invoke("dev-stop");
    assert.equal(stopped.code, 0, stopped.output);
    await rm(root, { recursive: true, force: true });
  });
  const result = await invoke("dev-start");
  assert.notEqual(result.code, 0);
  assert.match(result.output, /agent did not become ready.*HTTP 503/i);
  await assert.rejects(readFile(path.join(root, "web-started")), { code: "ENOENT" });
  await assert.rejects(readFile(state), { code: "ENOENT" });
  await assert.rejects(fetch(`http://127.0.0.1:${ports[0]}/healthz`));
});
