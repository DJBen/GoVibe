import cors from "cors";
import express, { Request, Response } from "express";
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { z } from "zod";
import { getConfig } from "./config";
import { signToken, verifyToken } from "./crypto";
import { DeviceDoc, SessionDoc } from "./types";

initializeApp();

const firestore = getFirestore();
const auth = getAuth();
const app = express();
const cfg = getConfig();

app.use(cors({ origin: true }));
app.use(express.json());

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

app.get("/healthz", (_req: Request, res: Response) => {
  res.json({ status: "ok", service: "govibe-api" });
});

export const api = onRequest(
  {
    region: "us-west1",
    timeoutSeconds: 60,
    maxInstances: 50
  },
  app
);
