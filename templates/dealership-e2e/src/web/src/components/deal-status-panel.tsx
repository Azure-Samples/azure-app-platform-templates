"use client";

import type { DealStage } from "@/lib/types";
import { Button } from "@fluentui/react-headless-components-preview/button";
import { Card } from "@fluentui/react-headless-components-preview/card";
import { Input } from "@fluentui/react-headless-components-preview/input";
import { Label } from "@fluentui/react-headless-components-preview/label";

interface DealStatusPanelProps {
  stage: DealStage;
  email: string;
  onEmailChange: (value: string) => void;
  onApply: () => Promise<void>;
  isApplying: boolean;
  isStreaming: boolean;
}

const STAGES: Array<{ id: DealStage; label: string }> = [
  { id: "pending_teams_approval", label: "Pending Teams approval" },
  { id: "approved", label: "Approved" },
  { id: "offer_emailed", label: "Offer emailed" }
];

const stageRank: Record<DealStage, number> = {
  idle: -1,
  shortlisted: -1,
  pending_teams_approval: 0,
  approved: 1,
  offer_emailed: 2
};

export function DealStatusPanel({
  stage,
  email,
  onEmailChange
}: DealStatusPanelProps) {
  return (
    <Card className="rounded-token-2xl border border-border bg-surface-elev p-5 shadow-token-2">
      <h3 className="font-display text-lg font-semibold text-ink">Deal workflow</h3>
      <p className="mt-1 text-sm text-ink-muted">
        Loan application submission workflow is not connected.
      </p>

      <div className="mt-4 space-y-2">
        <Label className="block text-sm font-medium text-ink-muted" htmlFor="email">
          Customer email
        </Label>
        <Input
          id="email"
          type="email"
          value={email}
          disabled={true}
          aria-disabled="true"
          onChange={(_event, data) => onEmailChange(data.value)}
          placeholder="paul@example.com"
          root={{ className: "block w-full" }}
          input={{
            "aria-disabled": "true",
            className:
              "w-full cursor-not-allowed rounded-token-lg border border-border bg-surface-soft px-3 py-2 text-sm text-ink-muted opacity-60 outline-none"
          }}
        />
      </div>

      <Button
        className="mt-4 w-full cursor-not-allowed rounded-token-lg border border-border bg-surface-soft px-4 py-2 text-sm font-semibold text-ink-muted opacity-60"
        disabled={true}
        aria-disabled="true"
      >
        Apply (Unavailable)
      </Button>

      <ol className="mt-6 space-y-3">
        {STAGES.map((item) => {
          const current = stageRank[stage];
          const target = stageRank[item.id];
          const isComplete = current >= target && current !== -1;
          const isCurrent = current === target;

          return (
            <li
              key={item.id}
              aria-current={isCurrent ? "step" : undefined}
              className={`rounded-token-lg border px-3 py-2 text-sm font-medium ${
                isCurrent
                  ? "border-status-warning bg-status-warning-soft text-status-warning"
                  : isComplete
                    ? "border-status-success bg-status-success-soft text-status-success"
                    : "border-border bg-surface-soft text-ink-muted"
              }`}
            >
              {item.label}
            </li>
          );
        })}
      </ol>
    </Card>
  );
}

