import cors from "cors";
import express, { Request, Response } from "express";
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { z } from "zod";
import { getConfig } from "./config";
import { signToken, verifyToken } from "./crypto";
import { DeviceDoc, RelayRole, SessionDoc } from "./types";

initializeApp();

const firestore = getFirestore();
const auth = getAuth();
const app = express();
const cfg = getConfig();

app.use(cors({ origin: true }));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

async function requireAuth(req: Request): Promise<{ uid: string }> {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) {
    throw new Error("missing_bearer_token");
  }

  const token = header.slice("Bearer ".length);
  const decoded = await auth.verifyIdToken(token);
  return { uid: decoded.uid };
}

function parseDeviceProof(inputToken: string, expectedDeviceId: string): boolean {
  const payload = verifyToken(inputToken, cfg.sessionTokenSecret);
  if (!payload) {
    return false;
  }

  return payload.deviceId === expectedDeviceId;
}

function getTurnCredentials(sessionId: string): { username: string; credential: string; ttl: number; urls: string[] } {
  const expiresAt = Math.floor(Date.now() / 1000) + 600;
  const username = `${expiresAt}:${cfg.turnUsernamePrefix}:${sessionId}`;
  const credential = signToken({ username }, cfg.turnSecret, 600);

  return {
    username,
    credential,
    ttl: 600,
    urls: cfg.turnUrls
  };
}

function timestampToISOString(value?: Timestamp): string | null {
  return value ? value.toDate().toISOString() : null;
}

function omitUndefined<T extends object>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined)
  ) as T;
}

function isControlRoom(room: string, hostId: string): boolean {
  return room == `${hostId}-ctl`;
}

function isHostScopedSessionRoom(room: string, hostId: string): boolean {
  return room.startsWith(`${hostId}-`) && room !== `${hostId}-ctl`;
}

const sessionCreateSchema = z.object({
  ownerDeviceId: z.string().min(3),
  peerDeviceId: z.string().min(3),
  relayRequired: z.boolean().default(false),
  icePolicy: z.enum(["all", "relay"]).default("all"),
  deviceProof: z.string().optional()
});

app.post("/session/create", async (req: Request, res: Response) => {
  try {
    const { uid } = await requireAuth(req);
    const body = sessionCreateSchema.parse(req.body);
    if (body.deviceProof && !parseDeviceProof(body.deviceProof, body.ownerDeviceId)) {
      res.status(403).json({ error: "invalid_device_proof" });
      return;
    }

    const ownerRef = firestore.collection("devices").doc(body.ownerDeviceId);
    const ownerSnap = await ownerRef.get();
    if (!ownerSnap.exists) {
      res.status(404).json({ error: "owner_device_not_found" });
      return;
    }

    const owner = ownerSnap.data() as DeviceDoc;
    if (owner.ownerUid !== uid) {
      res.status(403).json({ error: "owner_device_not_owned_by_user" });
      return;
    }

    const peerRef = firestore.collection("devices").doc(body.peerDeviceId);
    const peerSnap = await peerRef.get();
    if (!peerSnap.exists) {
      res.status(404).json({ error: "peer_device_not_found" });
      return;
    }
    const peer = peerSnap.data() as DeviceDoc;
    if (peer.ownerUid !== uid) {
      res.status(403).json({ error: "peer_device_not_owned_by_user" });
      return;
    }

    const now = Timestamp.now();
    const sessionRef = firestore.collection("sessions").doc();
    const session: SessionDoc = {
      ownerUid: uid,
      ownerDeviceId: body.ownerDeviceId,
      peerDeviceId: body.peerDeviceId,
      state: "creating",
      createdAt: now,
      lastHeartbeat: now,
      icePolicy: body.icePolicy,
      relayRequired: body.relayRequired
    };

    await sessionRef.set(session);

    const sessionToken = signToken(
      {
        sessionId: sessionRef.id,
        ownerDeviceId: body.ownerDeviceId,
        peerDeviceId: body.peerDeviceId
      },
      cfg.sessionTokenSecret,
      cfg.sessionTtlSeconds
    );

    const turn = getTurnCredentials(sessionRef.id);

    res.json({
      sessionId: sessionRef.id,
      signalingPath: `sessions/${sessionRef.id}/signal`,
      token: sessionToken,
      ice: {
        policy: body.icePolicy,
        relayRequired: body.relayRequired,
        turn
      }
    });
  } catch (error) {
    res.status(400).json({
      error: "session_create_failed",
      detail: error instanceof Error ? error.message : "unknown"
    });
  }
});

const sessionResumeSchema = z.object({
  sessionId: z.string().min(5),
  deviceId: z.string().min(3),
  deviceProof: z.string().optional()
});

app.post("/session/resume", async (req: Request, res: Response) => {
  try {
    const { uid } = await requireAuth(req);
    const body = sessionResumeSchema.parse(req.body);
    if (body.deviceProof && !parseDeviceProof(body.deviceProof, body.deviceId)) {
      res.status(403).json({ error: "invalid_device_proof" });
      return;
    }

    const sessionRef = firestore.collection("sessions").doc(body.sessionId);
    const sessionSnap = await sessionRef.get();
    if (!sessionSnap.exists) {
      res.status(404).json({ error: "session_not_found" });
      return;
    }

    const session = sessionSnap.data() as SessionDoc;
    if (session.ownerUid !== uid) {
      res.status(403).json({ error: "session_not_owned_by_user" });
      return;
    }

    if (![session.ownerDeviceId, session.peerDeviceId].includes(body.deviceId)) {
      res.status(403).json({ error: "device_not_in_session" });
      return;
    }

    const now = Timestamp.now();
    if (session.state === "closed") {
      res.status(410).json({ error: "session_closed" });
      return;
    }

    if (session.graceUntil && now.toMillis() > session.graceUntil.toMillis()) {
      res.status(410).json({ error: "grace_window_expired" });
      return;
    }

    await sessionRef.update({
      state: "active",
      lastHeartbeat: now
    });

    const token = signToken(
      {
        sessionId: body.sessionId,
        deviceId: body.deviceId
      },
      cfg.sessionTokenSecret,
      cfg.sessionTtlSeconds
    );

    res.json({
      sessionId: body.sessionId,
      status: "active",
      token
    });
  } catch (error) {
    res.status(400).json({
      error: "session_resume_failed",
      detail: error instanceof Error ? error.message : "unknown"
    });
  }
});

const sessionCloseSchema = z.object({
  sessionId: z.string().min(5),
  deviceId: z.string().min(3),
  toGrace: z.boolean().default(false)
});

app.post("/session/close", async (req: Request, res: Response) => {
  try {
    const { uid } = await requireAuth(req);
    const body = sessionCloseSchema.parse(req.body);

    const sessionRef = firestore.collection("sessions").doc(body.sessionId);
    const sessionSnap = await sessionRef.get();
    if (!sessionSnap.exists) {
      res.status(404).json({ error: "session_not_found" });
      return;
    }

    const session = sessionSnap.data() as SessionDoc;
    if (session.ownerUid !== uid) {
      res.status(403).json({ error: "session_not_owned_by_user" });
      return;
    }

    if (![session.ownerDeviceId, session.peerDeviceId].includes(body.deviceId)) {
      res.status(403).json({ error: "device_not_in_session" });
      return;
    }

    const now = Timestamp.now();
    if (body.toGrace) {
      await sessionRef.update({
        state: "grace",
        graceUntil: Timestamp.fromMillis(now.toMillis() + cfg.graceTtlSeconds * 1000),
        lastHeartbeat: now
      });
      res.json({
        sessionId: body.sessionId,
        state: "grace",
        graceUntil: Timestamp.fromMillis(now.toMillis() + cfg.graceTtlSeconds * 1000)
          .toDate()
          .toISOString()
      });
      return;
    }

    await sessionRef.update({
      state: "closed",
      closedAt: now,
      lastHeartbeat: now
    });

    res.json({
      sessionId: body.sessionId,
      state: "closed"
    });
  } catch (error) {
    res.status(400).json({
      error: "session_close_failed",
      detail: error instanceof Error ? error.message : "unknown"
    });
  }
});

const sessionDiscoverSchema = z.object({
  ownerDeviceId: z.string().min(3).optional()
});

app.post("/session/discover", async (req: Request, res: Response) => {
  try {
    const { uid } = await requireAuth(req);
    const body = sessionDiscoverSchema.parse(req.body ?? {});

    const ownedDevicesSnap = await firestore
      .collection("devices")
      .where("ownerUid", "==", uid)
      .get();

    const ownedDevices = ownedDevicesSnap.docs.map((doc) => ({ id: doc.id, ...(doc.data() as DeviceDoc) }));

    if (body.ownerDeviceId && !ownedDevices.some((device) => device.id === body.ownerDeviceId)) {
      res.status(403).json({ error: "owner_device_not_owned_by_user" });
      return;
    }

    const iosDevices = ownedDevices.filter((device) => device.platform === "ios");
    if (body.ownerDeviceId) {
      const hasOwnerDevice = iosDevices.some((device) => device.id === body.ownerDeviceId);
      if (!hasOwnerDevice) {
        res.status(403).json({ error: "owner_device_not_owned_by_user" });
        return;
      }
    }

    const roomIds = new Set<string>(
      ownedDevices
        .filter((device) => device.platform === "mac")
        .map((device) => device.id)
    );

    const openSessionsSnap = await firestore
      .collection("sessions")
      .where("ownerUid", "==", uid)
      .where("state", "in", ["creating", "active", "grace"])
      .get();
    for (const doc of openSessionsSnap.docs) {
      const session = doc.data() as SessionDoc;
      roomIds.add(session.peerDeviceId);
    }

    res.json({
      roomIds: Array.from(roomIds).sort(),
      count: roomIds.size
    });
  } catch (error) {
    res.status(400).json({
      error: "session_discover_failed",
      detail: error instanceof Error ? error.message : "unknown"
    });
  }
});

const fcmTokenSchema = z.object({
  deviceId: z.string().min(3),
  fcmToken: z.string().min(1)
});

const deviceRegisterSchema = z.object({
  deviceId: z.string().min(3),
  platform: z.enum(["mac", "ios"]),
  displayName: z.string().trim().min(1).max(120).optional(),
  isHost: z.boolean().default(false),
  discoveryVisible: z.boolean().default(false),
  capabilities: z.array(z.string().trim().min(1).max(64)).max(32).default([]),
  appVersion: z.string().trim().min(1).max(64).optional(),
  osVersion: z.string().trim().min(1).max(64).optional(),
  pubKey: z.string().optional()
});

app.post("/device/register", async (req: Request, res: Response) => {
  try {
    const { uid } = await requireAuth(req);
    const body = deviceRegisterSchema.parse(req.body);

    const now = Timestamp.now();
    const deviceRef = firestore.collection("devices").doc(body.deviceId);
    const existingSnap = await deviceRef.get();
    const existing = existingSnap.exists ? (existingSnap.data() as DeviceDoc) : null;

    if (existing && existing.ownerUid !== uid) {
      res.status(403).json({ error: "device_not_owned_by_user" });
      return;
    }

    const device = omitUndefined<DeviceDoc>({
      ownerUid: uid,
      platform: body.platform,
      pubKey: body.pubKey ?? existing?.pubKey ?? "",
      createdAt: existing?.createdAt ?? now,
      lastSeenAt: now,
      lastOnlineAt: now,
      fcmToken: existing?.fcmToken,
      displayName: body.displayName ?? existing?.displayName,
      isHost: body.isHost,
      discoveryVisible: body.discoveryVisible,
      capabilities: body.capabilities,
      appVersion: body.appVersion,
      osVersion: body.osVersion
    });

    await deviceRef.set(device, { merge: true });

    res.json({
      ok: true,
      deviceId: body.deviceId,
      ownerUid: uid,
      platform: device.platform,
      isHost: device.isHost ?? false,
      discoveryVisible: device.discoveryVisible ?? false,
      lastSeenAt: timestampToISOString(device.lastSeenAt)
    });
  } catch (error) {
    res.status(400).json({
      error: "device_register_failed",
      detail: error instanceof Error ? error.message : "unknown"
    });
  }
});

const deviceHeartbeatSchema = z.object({
  deviceId: z.string().min(3),
  discoveryVisible: z.boolean().optional(),
  capabilities: z.array(z.string().trim().min(1).max(64)).max(32).optional(),
  appVersion: z.string().trim().min(1).max(64).optional(),
  osVersion: z.string().trim().min(1).max(64).optional()
});

app.post("/device/heartbeat", async (req: Request, res: Response) => {
  try {
    const { uid } = await requireAuth(req);
    const body = deviceHeartbeatSchema.parse(req.body);

    const deviceRef = firestore.collection("devices").doc(body.deviceId);
    const deviceSnap = await deviceRef.get();
    if (!deviceSnap.exists) {
      res.status(404).json({ error: "device_not_found" });
      return;
    }

    const device = deviceSnap.data() as DeviceDoc;
    if (device.ownerUid !== uid) {
      res.status(403).json({ error: "device_not_owned_by_user" });
      return;
    }

    const now = Timestamp.now();
    const update = omitUndefined<Partial<DeviceDoc>>({
      lastSeenAt: now,
      lastOnlineAt: now
    });
    if (body.discoveryVisible !== undefined) {
      update.discoveryVisible = body.discoveryVisible;
    }
    if (body.capabilities !== undefined) {
      update.capabilities = body.capabilities;
    }
    if (body.appVersion !== undefined) {
      update.appVersion = body.appVersion;
    }
    if (body.osVersion !== undefined) {
      update.osVersion = body.osVersion;
    }

    await deviceRef.update(update);

    res.json({
      ok: true,
      deviceId: body.deviceId,
      lastSeenAt: timestampToISOString(now)
    });
  } catch (error) {
    res.status(400).json({
      error: "device_heartbeat_failed",
      detail: error instanceof Error ? error.message : "unknown"
    });
  }
});

const relayTokenSchema = z.object({
  deviceId: z.string().min(3),
  hostId: z.string().min(3),
  room: z.string().min(3),
  role: z.enum(["host-control", "client-control", "host-session", "client-session"])
});

app.post("/relay/token", async (req: Request, res: Response) => {
  try {
    const { uid } = await requireAuth(req);
    const body = relayTokenSchema.parse(req.body);

    const deviceRef = firestore.collection("devices").doc(body.deviceId);
    const hostRef = firestore.collection("devices").doc(body.hostId);
    const [deviceSnap, hostSnap] = await Promise.all([deviceRef.get(), hostRef.get()]);

    if (!deviceSnap.exists) {
      res.status(404).json({ error: "device_not_found" });
      return;
    }
    if (!hostSnap.exists) {
      res.status(404).json({ error: "host_not_found" });
      return;
    }

    const device = deviceSnap.data() as DeviceDoc;
    const host = hostSnap.data() as DeviceDoc;
    if (device.ownerUid !== uid || host.ownerUid !== uid) {
      res.status(403).json({ error: "device_not_owned_by_user" });
      return;
    }
    if (host.platform !== "mac" || host.isHost === false) {
      res.status(403).json({ error: "invalid_host_device" });
      return;
    }

    const role = body.role as RelayRole;
    switch (role) {
      case "host-control":
        if (body.deviceId !== body.hostId || device.platform !== "mac" || !isControlRoom(body.room, body.hostId)) {
          res.status(403).json({ error: "invalid_relay_scope" });
          return;
        }
        break;
      case "client-control":
        if (device.platform !== "ios" || !isControlRoom(body.room, body.hostId)) {
          res.status(403).json({ error: "invalid_relay_scope" });
          return;
        }
        break;
      case "host-session":
        if (body.deviceId !== body.hostId || device.platform !== "mac" || !isHostScopedSessionRoom(body.room, body.hostId)) {
          res.status(403).json({ error: "invalid_relay_scope" });
          return;
        }
        break;
      case "client-session":
        if (device.platform !== "ios" || !isHostScopedSessionRoom(body.room, body.hostId)) {
          res.status(403).json({ error: "invalid_relay_scope" });
          return;
        }
        break;
      default:
        res.status(403).json({ error: "invalid_relay_scope" });
        return;
    }

    const token = signToken(
      {
        typ: "relay_join",
        uid,
        deviceId: body.deviceId,
        hostId: body.hostId,
        room: body.room,
        role
      },
      cfg.relayTokenSecret,
      cfg.relayTokenTtlSeconds
    );

    res.json({
      token,
      room: body.room,
      role,
      expiresInSeconds: cfg.relayTokenTtlSeconds
    });
  } catch (error) {
    res.status(400).json({
      error: "relay_token_failed",
      detail: error instanceof Error ? error.message : "unknown"
    });
  }
});

app.post("/device/fcmToken", async (req: Request, res: Response) => {
  try {
    const { uid } = await requireAuth(req);
    const body = fcmTokenSchema.parse(req.body);

    const deviceRef = firestore.collection("devices").doc(body.deviceId);
    const deviceSnap = await deviceRef.get();

    if (deviceSnap.exists) {
      const device = deviceSnap.data() as DeviceDoc;
      if (device.ownerUid !== uid) {
        res.status(403).json({ error: "device_not_owned_by_user" });
        return;
      }
      await deviceRef.update({ fcmToken: body.fcmToken });
    } else {
      // Auto-register iOS device on first FCM token registration.
      const now = Timestamp.now();
      const newDevice: DeviceDoc = {
        ownerUid: uid,
        platform: "ios",
        pubKey: "",
        createdAt: now,
        lastSeenAt: now,
        fcmToken: body.fcmToken
      };
      await deviceRef.set(newDevice);
    }

    res.json({ ok: true });
  } catch (error) {
    res.status(400).json({
      error: "fcm_token_update_failed",
      detail: error instanceof Error ? error.message : "unknown"
    });
  }
});

app.post("/hosts/discover", async (req: Request, res: Response) => {
  try {
    const { uid } = await requireAuth(req);

    const devicesSnap = await firestore
      .collection("devices")
      .where("ownerUid", "==", uid)
      .where("platform", "==", "mac")
      .get();

    const hosts = devicesSnap.docs
      .map((doc) => ({ id: doc.id, ...(doc.data() as DeviceDoc) }))
      .filter((device) => device.isHost && device.discoveryVisible !== false)
      .sort((lhs, rhs) => rhs.lastSeenAt.toMillis() - lhs.lastSeenAt.toMillis())
      .map((device) => ({
        deviceId: device.id,
        displayName: device.displayName ?? device.id,
        capabilities: device.capabilities ?? [],
        appVersion: device.appVersion ?? null,
        osVersion: device.osVersion ?? null,
        lastSeenAt: timestampToISOString(device.lastSeenAt),
        lastOnlineAt: timestampToISOString(device.lastOnlineAt),
        isOnline: Date.now() - device.lastSeenAt.toMillis() <= 60_000
      }));

    res.json({
      hosts,
      count: hosts.length
    });
  } catch (error) {
    res.status(400).json({
      error: "hosts_discover_failed",
      detail: error instanceof Error ? error.message : "unknown"
    });
  }
});

app.post("/user/reset", async (req: Request, res: Response) => {
  try {
    const { uid } = await requireAuth(req);

    const batch = firestore.batch();
    let deletedCount = 0;

    // 1. Delete all devices owned by this user and their hostedSessions subcollections.
    const devicesSnap = await firestore
      .collection("devices")
      .where("ownerUid", "==", uid)
      .get();
    for (const deviceDoc of devicesSnap.docs) {
      const hostedSnap = await deviceDoc.ref.collection("hostedSessions").get();
      for (const hosted of hostedSnap.docs) {
        batch.delete(hosted.ref);
        deletedCount++;
      }
      batch.delete(deviceDoc.ref);
      deletedCount++;
    }

    // 2. Delete all sessions owned by this user and their signal subcollections.
    const sessionsSnap = await firestore
      .collection("sessions")
      .where("ownerUid", "==", uid)
      .get();
    for (const sessionDoc of sessionsSnap.docs) {
      const signalSnap = await sessionDoc.ref.collection("signal").get();
      for (const signal of signalSnap.docs) {
        batch.delete(signal.ref);
        deletedCount++;
      }
      batch.delete(sessionDoc.ref);
      deletedCount++;
    }

    await batch.commit();

    res.json({
      ok: true,
      deletedDocuments: deletedCount
    });
  } catch (error) {
    res.status(400).json({
      error: "user_reset_failed",
      detail: error instanceof Error ? error.message : "unknown"
    });
  }
});

// Apple Sign-In OAuth callback for macOS Developer ID host app.
// Apple form-posts (code, id_token, state, user) after user authenticates.
// We redirect to a custom URL scheme so ASWebAuthenticationSession can capture the result.
app.post("/apple-auth/callback", (req: Request, res: Response) => {
  const { id_token, code, state, user } = req.body;

  if (!id_token && !code) {
    res.status(400).send("Missing id_token and code from Apple");
    return;
  }

  const params = new URLSearchParams();
  if (id_token) params.set("id_token", id_token);
  if (code) params.set("code", code);
  if (state) params.set("state", state);
  if (user) params.set("user", typeof user === "string" ? user : JSON.stringify(user));

  res.redirect(302, `govibe-host://apple-callback?${params.toString()}`);
});

app.get("/healthz", (_req: Request, res: Response) => {
  res.json({ status: "ok", service: "govibe-api" });
});

export const api = onRequest(
  {
    region: "us-west1",
    timeoutSeconds: 60,
    maxInstances: 50,
    secrets: ["SESSION_TOKEN_SECRET", "TURN_SECRET", "RELAY_TOKEN_SECRET"]
  },
  app
);
