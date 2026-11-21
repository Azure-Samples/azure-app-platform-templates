import { expect, test, type Page } from "@playwright/test";

// End-to-end coverage for the driveline-web chat UI against a real `next start`
// build with zero runtime simulation:
// - Unintercepted requests hit the real `/api/chat` route, which returns
//   `source: "agent_error"` with startup guidance when `AGENT_URL` is
//   unreachable.
// - Pure UI rendering tests stub `/api/chat` strictly inside this E2E harness
//   via `page.route("**/api/chat", ...)`.

const TEST_VEHICLES = [
  {
    id: "ioniq-5-limited",
    year: 2023,
    make: "Hyundai",
    model: "IONIQ 5 Limited AWD",
    priceUsd: 37990,
    rangeMiles: 303,
    seats: 5
  },
  {
    id: "mach-e-select",
    year: 2022,
    make: "Ford",
    model: "Mustang Mach-E Select",
    priceUsd: 36450,
    rangeMiles: 312,
    seats: 5
  },
  {
    id: "tesla-model-3",
    year: 2022,
    make: "Tesla",
    model: "Model 3 Long Range",
    priceUsd: 37800,
    rangeMiles: 333,
    seats: 5
  }
];

function ndjsonBody(events: Array<Record<string, unknown>>): string {
  return events.map((event) => JSON.stringify(event)).join("\n") + "\n";
}

async function installUiChatHarness(page: Page, onRequestBody?: (body: unknown) => void) {
  await page.route("**/api/chat", async (route) => {
    const body = route.request().postDataJSON() as {
      messages?: Array<{ content: string }>;
    };
    onRequestBody?.(body);
    const latest = (body.messages?.at(-1)?.content ?? "").toLowerCase();

    if (latest.includes("compare")) {
      await route.fulfill({
        contentType: "application/x-ndjson",
        body: ndjsonBody([
          { type: "source", value: "agent" },
          {
            type: "token",
            value:
              "Here's a quick comparison:\n\n" +
              "| Model | Price | Range |\n" +
              "| --- | --- | --- |\n" +
              "| IONIQ 5 Limited AWD | $37,990 | 303 mi |\n" +
              "| Mustang Mach-E Select | $36,450 | 312 mi |\n\n" +
              "**IONIQ 5** has the most cargo room."
          },
          { type: "vehicles", value: TEST_VEHICLES },
          { type: "status", value: "shortlisted" },
          { type: "done" }
        ])
      });
      return;
    }

    if (latest.includes("payment") || latest.includes("monthly")) {
      await route.fulfill({
        contentType: "application/x-ndjson",
        body: ndjsonBody([
          { type: "source", value: "agent" },
          {
            type: "token",
            value: "Estimated payment: $589/month for 72 months at 6.4% APR with $2,500 down."
          },
          { type: "status", value: "shortlisted" },
          { type: "done" }
        ])
      });
      return;
    }

    await route.fulfill({
      contentType: "application/x-ndjson",
      body: ndjsonBody([
        { type: "source", value: "agent" },
        {
          type: "token",
          value: "I found three EVs under $38k with 250+ miles of range."
        },
        { type: "vehicles", value: TEST_VEHICLES },
        { type: "status", value: "shortlisted" },
        { type: "done" }
      ])
    });
  });
}

test.describe("deal-finder chat", () => {
  test("renders the initial assistant greeting", async ({ page }) => {
    await page.goto("/");

    await expect(page.getByTestId("chat-message-assistant").first()).toContainText(
      "Application submission is not connected yet."
    );
    await expect(page.getByText("Demo conversation")).toBeVisible();
  });

  test("returns agent_error with startup guidance from real /api/chat when AGENT_URL is unreachable", async ({
    page,
    request
  }) => {
    const apiResponse = await request.post("/api/chat", {
      data: {
        messages: [{ id: "u1", role: "user", content: "Find me an EV" }]
      }
    });
    expect(apiResponse.status()).toBe(200);
    const rawLines = (await apiResponse.text()).trim().split("\n").map((line) => JSON.parse(line));
    expect(rawLines[0]).toEqual({ type: "source", value: "agent_error" });
    expect(rawLines[1]).toEqual({
      type: "error",
      value:
        "Deal-finder agent is unavailable at http://127.0.0.1:59999. Start the full stack with ./scripts/dev-start.sh after configuring Azure AI Gateway."
    });

    await page.goto("/");
    await page.getByTestId("chat-input").fill("Find me an EV");
    await page.getByTestId("chat-send").click();

    await expect(page.getByTestId("reply-source-badge")).toHaveText("Live agent request failed");
    await expect(page.getByTestId("chat-message-assistant").last()).toContainText(
      "Deal-finder agent is unavailable at http://127.0.0.1:59999. Start the full stack with ./scripts/dev-start.sh after configuring Azure AI Gateway."
    );
  });

  test("shortlists vehicles for a car-shopping prompt", async ({ page }) => {
    await installUiChatHarness(page);
    await page.goto("/");

    await page.getByTestId("chat-input").fill(
      "Find me an EV under $40,000 with at least 250 miles of range"
    );
    await page.getByTestId("chat-send").click();

    await expect(page.getByTestId("chat-message-assistant").last()).toContainText(
      "three EVs",
      { timeout: 10_000 }
    );
    await expect(page.getByTestId("reply-source-badge")).toHaveText("Live agent");

    // Vehicle shortlist grid should render from the "vehicles" stream event.
    await expect(page.getByText("IONIQ 5")).toBeVisible();
  });

  test("uses an accessible Octicon for starter-prompt confirmation", async ({ page }) => {
    await page.goto("/");
    const copy = page.getByTestId("starter-prompt-copy");
    await copy.click();
    await expect(copy).toHaveText("Copied");
    await expect(copy.locator("svg.octicon-check")).toBeVisible();
    await expect(copy.locator("svg")).toHaveAttribute("aria-hidden", "true");
    await expect(page.getByTestId("chat-input")).toHaveValue(/Find me an EV/);
  });

  for (const [source, icon, label] of [
    ["agent", "dot-fill", "Live agent"],
    ["agent_error", "x-circle", "Live agent request failed"],
    ["workflow_unavailable", "x-circle", "Approval unavailable"]
  ] as const) {
    test(`uses the official ${icon} icon for ${source} replies`, async ({ page }) => {
      await page.route("**/api/chat", (route) =>
        route.fulfill({
          contentType: "application/x-ndjson",
          body: ndjsonBody([
            { type: "source", value: source },
            source === "agent"
              ? { type: "token", value: "A test response." }
              : { type: "error", value: "Action or agent unavailable." },
            { type: "done" }
          ])
        })
      );
      await page.goto("/");
      await page.getByTestId("chat-input").fill("Test status");
      await page.getByTestId("chat-send").click();
      const badge = page.getByTestId("reply-source-badge");
      await expect(badge).toContainText(label);
      if (source !== "agent") {
        await expect(page.getByTestId("chat-message-assistant").last()).toContainText(
          "Action or agent unavailable."
        );
      }
      await expect(badge.locator(`svg.octicon-${icon}`)).toBeVisible();
      await expect(badge.locator("svg")).toHaveAttribute("aria-hidden", "true");
    });
  }

  test("keeps the conversation running across multiple turns", async ({ page }) => {
    await installUiChatHarness(page);
    await page.goto("/");

    await page.getByTestId("chat-input").fill(
      "Find me an EV under $40,000 with at least 250 miles of range"
    );
    await page.getByTestId("chat-send").click();
    await expect(page.getByTestId("chat-message-assistant").last()).toContainText(
      "three EVs",
      { timeout: 10_000 }
    );

    await page.getByTestId("chat-input").fill("what would the monthly payment be?");
    await page.getByTestId("chat-send").click();

    await expect(page.getByTestId("chat-message-assistant").last()).toContainText(
      "$589/month",
      { timeout: 10_000 }
    );

    const userMessages = page.getByTestId("chat-message-user");
    await expect(userMessages).toHaveCount(2);
    await expect(userMessages.first()).toContainText("under $40,000");
    await expect(userMessages.last()).toContainText("monthly payment");
  });

  test("sends the full message history to /api/chat on every turn", async ({ page }) => {
    const requestBodies: unknown[] = [];
    await installUiChatHarness(page, (body) => requestBodies.push(body));

    await page.goto("/");

    await page.getByTestId("chat-input").fill("first message");
    await page.getByTestId("chat-send").click();
    await expect(page.getByTestId("chat-input")).toBeEnabled({ timeout: 10_000 });

    await page.getByTestId("chat-input").fill("second message");
    await page.getByTestId("chat-send").click();
    await expect(page.getByTestId("chat-input")).toBeEnabled({ timeout: 10_000 });

    expect(requestBodies).toHaveLength(2);

    const firstRequest = requestBodies[0] as { messages: Array<{ content: string }> };
    const secondRequest = requestBodies[1] as { messages: Array<{ content: string }> };

    expect(firstRequest.messages.map((m) => m.content)).toEqual(
      expect.arrayContaining(["first message"])
    );

    const secondContents = secondRequest.messages.map((m) => m.content);
    expect(secondContents).toEqual(expect.arrayContaining(["first message", "second message"]));
    expect(secondRequest.messages.length).toBeGreaterThan(firstRequest.messages.length);
  });

  test("renders markdown replies as formatted HTML, not raw syntax", async ({ page }) => {
    await installUiChatHarness(page);
    await page.goto("/");

    await page.getByTestId("chat-input").fill("compare the top two EVs side by side");
    await page.getByTestId("chat-send").click();

    const lastAssistantMessage = page.getByTestId("chat-message-assistant").last();
    await expect(lastAssistantMessage).toContainText("IONIQ 5", { timeout: 10_000 });

    await expect(lastAssistantMessage.locator("table")).toBeVisible();
    await expect(lastAssistantMessage.locator("td", { hasText: "$37,990" })).toBeVisible();
    await expect(lastAssistantMessage.locator("strong", { hasText: "IONIQ 5" })).toBeVisible();

    const bubbleText = await lastAssistantMessage.innerText();
    expect(bubbleText).not.toContain("**");
    expect(bubbleText).not.toContain("| ---");
  });

  test("keeps loan application controls visibly unavailable and enforces workflow_unavailable on the server", async ({
    page,
    request
  }) => {
    await page.goto("/");

    await expect(
      page.getByText("Loan application submission workflow is not connected.")
    ).toBeVisible();

    const emailInput = page.getByLabel("Customer email");
    await expect(emailInput).toBeDisabled();
    await expect(emailInput).toHaveAttribute("aria-disabled", "true");

    const applyButton = page.getByRole("button", { name: "Apply (Unavailable)" });
    await expect(applyButton).toBeVisible();
    await expect(applyButton).toBeDisabled();
    await expect(applyButton).toHaveAttribute("aria-disabled", "true");
    await expect(page.locator("li[aria-current='step']")).toHaveCount(0);

    for (const payload of [
      { messages: [{ id: "1", role: "user", content: "Apply" }], action: "apply" },
      { messages: [{ id: "1", role: "user", content: "Apply" }], command: "apply" }
    ]) {
      const response = await request.post("/api/chat", { data: payload });
      expect(response.status()).toBe(200);
      const events = (await response.text()).trim().split("\n").map((line) => JSON.parse(line));
      expect(events[0]).toEqual({ type: "source", value: "workflow_unavailable" });
      expect(events[1]).toEqual({
        type: "error",
        value: "Application submission is not connected. No application was sent."
      });
    }
  });
});
