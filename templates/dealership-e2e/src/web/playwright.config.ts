import { defineConfig, devices } from "@playwright/test";

/**
 * E2E config for the driveline-web chat UI. Runs against a real `next start`
 * build with no runtime mock mode (`AGENT_URL` points to an unused loopback
 * port so the real `/api/chat` error-path test deterministically exercises
 * `agent_error`, while UI rendering tests stub `/api/chat` in `e2e/`).
 */
export default defineConfig({
  testDir: "./e2e",
  testIgnore: "dev-origin.spec.ts",
  fullyParallel: true,
  retries: process.env.CI ? 1 : 0,
  reporter: "list",
  use: {
    baseURL: "http://127.0.0.1:3100",
    trace: "on-first-retry"
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] }
    }
  ],
  webServer: {
    command: "npm run build && npm run start -- -p 3100",
    url: "http://127.0.0.1:3100",
    reuseExistingServer: false,
    timeout: 120_000,
    env: {
      AGENT_URL: "http://127.0.0.1:59999"
    }
  }
});
