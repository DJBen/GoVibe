export type Platform = "mac" | "ios";

export type SessionState = "creating" | "active" | "grace" | "closed";

export interface DeviceDoc {
  ownerUid: string;
  platform: Platform;
  pubKey: string;
  createdAt: FirebaseFirestore.Timestamp;
  lastSeenAt: FirebaseFirestore.Timestamp;
}

export interface SessionDoc {
  ownerUid: string;
  ownerDeviceId: string;
  peerDeviceId: string;
  state: SessionState;
  createdAt: FirebaseFirestore.Timestamp;
  graceUntil?: FirebaseFirestore.Timestamp;
  closedAt?: FirebaseFirestore.Timestamp;
  lastHeartbeat: FirebaseFirestore.Timestamp;
  icePolicy: "all" | "relay";
  relayRequired: boolean;
}
