export type MessageType =
  | "TerminalDiff"
  | "TerminalSnapshot"
  | "InputEvent"
  | "SessionEvent"
  | "PtyChunk"
  | "Telemetry";

export interface Envelope<T extends MessageType, P> {
  type: T;
  seq: number;
  ts: number;
  payload: P;
}

export interface CellDelta {
  row: number;
  col: number;
  text: string;
  fg?: string;
  bg?: string;
  attrs?: string[];
}

export interface TerminalDiffPayload {
  rows: number;
  cols: number;
  cursorRow: number;
  cursorCol: number;
  dirtyRegions: Array<{ top: number; left: number; bottom: number; right: number }>;
  cellsDelta: CellDelta[];
}

export interface TerminalSnapshotPayload {
  rows: number;
  cols: number;
  cursorRow: number;
  cursorCol: number;
  lines: string[];
}

export interface InputEventPayload {
  kind: "text" | "key" | "paste" | "resize" | "signal";
  text?: string;
  key?: string;
  ctrl?: boolean;
  alt?: boolean;
  shift?: boolean;
  rows?: number;
  cols?: number;
  signal?: "INT" | "TERM" | "HUP";
}

export interface SessionEventPayload {
  status: "connected" | "backgrounded" | "resuming" | "terminated";
  reason?: string;
}
