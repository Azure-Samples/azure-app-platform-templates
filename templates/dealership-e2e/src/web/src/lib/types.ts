export type ChatRole = "user" | "assistant";

export type DealStage =
  | "idle"
  | "shortlisted"
  | "pending_teams_approval"
  | "approved"
  | "offer_emailed";

export interface ChatMessage {
  id: string;
  role: ChatRole;
  content: string;
}

export interface Vehicle {
  id: string;
  year: number;
  make: string;
  model: string;
  priceUsd: number;
  rangeMiles: number;
  seats: number;
}

export interface ChatApiRequest {
  messages: ChatMessage[];
  email?: string;
  command?: "apply";
  action?: "apply";
  stage?: DealStage;
}

export type ReplySource = "agent" | "agent_error" | "workflow_unavailable";

export type ChatStreamEvent =
  | { type: "token"; value: string }
  | { type: "vehicles"; value: Vehicle[] }
  | { type: "status"; value: DealStage }
  | { type: "source"; value: ReplySource }
  | { type: "done" }
  | { type: "error"; value: string };

