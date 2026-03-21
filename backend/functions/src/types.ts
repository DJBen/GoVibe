export type Platform = "mac" | "ios";
export type RelayRole = "host-control" | "client-control" | "host-session" | "client-session";

export type SessionState = "creating" | "active" | "grace" | "closed";

export interface DeviceDoc {
  ownerUid: string;
  platform: Platform;
  pubKey: string;
  createdAt: FirebaseFirestore.Timestamp;
  lastSeenAt: FirebaseFirestore.Timestamp;
  lastOnlineAt?: FirebaseFirestore.Timestamp;
  displayName?: string;
  isHost?: boolean;
  discoveryVisible?: boolean;
  capabilities?: string[];
  appVersion?: string;
  osVersion?: string;
  fcmToken?: string;
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
