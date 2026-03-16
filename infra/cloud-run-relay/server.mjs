import { initializeApp } from "firebase-admin/app";
import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import http from "node:http";
import { WebSocketServer } from "ws";

const port = Number(process.env.PORT || 8080);
const RELAY_ROOMS_COLLECTION = "relay_rooms";

// Auto-initializes from the Cloud Run service account.
initializeApp();
const firestore = getFirestore();

async function setRoomPresence(room, iosDeviceId) {
  try {
    const data = { connectedAt: Timestamp.now() };
    if (iosDeviceId) data.iosDeviceId = iosDeviceId;
    await firestore.collection(RELAY_ROOMS_COLLECTION).doc(room).set(data, { merge: true });
  } catch (err) {
    console.error(`[presence] set failed for ${room}:`, err.message);
  }
}

async function bindIOSDeviceToRoom(iosDeviceId, room) {
  if (!iosDeviceId) return;

  try {
    await firestore.collection("devices").doc(iosDeviceId).set({
      lastRelayRoomId: room,
      lastSeenAt: Timestamp.now(),
    }, { merge: true });
  } catch (err) {
    console.error(`[presence] device-room bind failed for device=${iosDeviceId} room=${room}:`, err.message);
  }
}

const server = http.createServer((req, res) => {
  if (req.url === "/healthz") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: "ok", service: "govibe-relay" }));
    return;
  }

  res.writeHead(404, { "content-type": "application/json" });
  res.end(JSON.stringify({ error: "not_found" }));
});

const rooms = new Map();

function roomKey(room) {
  return `room:${room}`;
}

const wss = new WebSocketServer({ server, path: "/relay" });

wss.on("connection", (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const room = url.searchParams.get("room") ?? url.searchParams.get("sessionId");
  const iosDeviceId = url.searchParams.get("iosDeviceId") ?? null;

  if (!room) {
    ws.close(1008, "missing_room");
    return;
  }

  const key = roomKey(room);
  const peers = rooms.get(key) || new Set();
  const existingPeers = [...peers];
  peers.add(ws);
  rooms.set(key, peers);

  // Write presence the first time any peer joins this room.
  // Always update iosDeviceId if the connecting peer supplies one.
  if (peers.size === 1) {
    setRoomPresence(room, iosDeviceId);
  } else if (iosDeviceId) {
    setRoomPresence(room, iosDeviceId);
  }
  if (iosDeviceId) {
    bindIOSDeviceToRoom(iosDeviceId, room);
  }

  if (existingPeers.length > 0) {
    const msg = JSON.stringify({ type: "peer_joined" });
    for (const peer of existingPeers) {
      if (peer.readyState === peer.OPEN) {
        peer.send(msg);
      }
    }
  }

  ws.on("message", (data, isBinary) => {
    if (!isBinary) {
      try {
        const parsed = JSON.parse(data.toString("utf8"));
        if (parsed.type === "push_notify") {
          console.log(`[relay] push_notify received for room=${room} event=${parsed.event}`);
          for (const peer of peers) {
            if (peer !== ws && peer.readyState === peer.OPEN) peer.send(data);
          }
          sendFCMForRoom(room, parsed.event).catch(console.error);
          return;
        }
      } catch (_) {}
    }
    for (const peer of peers) {
      if (peer !== ws && peer.readyState === peer.OPEN) {
        peer.send(data, { binary: isBinary });
      }
    }
  });

  ws.on("close", () => {
    peers.delete(ws);
    if (peers.size === 0) {
      rooms.delete(key);
    } else {
      const msg = JSON.stringify({ type: "peer_left" });
      for (const peer of peers) {
        if (peer.readyState === peer.OPEN) {
          peer.send(msg);
        }
      }
    }
  });
});

async function sendFCMForRoom(room, event) {
  const iosDeviceId = await resolveIOSDeviceIdForRoom(room);
  if (!iosDeviceId) {
    console.warn(`[fcm] no iosDeviceId for room ${room}, skipping`);
    return;
  }

  const deviceDoc = await firestore.collection("devices").doc(iosDeviceId).get();
  const fcmToken = deviceDoc.data()?.fcmToken;
  if (!fcmToken) {
    console.warn(`[fcm] no fcmToken for device ${iosDeviceId}, skipping`);
    return;
  }

  console.log(`[fcm] sending event=${event} to device=${iosDeviceId}`);
  const { title, body } = notificationCopyForEvent(event);

  await getMessaging().send({
    token: fcmToken,
    notification: { title, body },
    data: { event, room, roomId: room, sessionId: room },
    apns: { payload: { aps: { sound: "default" } } },
  });
  console.log(`[fcm] sent successfully to device=${iosDeviceId}`);
}

function notificationCopyForEvent(event) {
  const assistant = event?.startsWith("codex_") ? "Codex" : "Claude";

  switch (event) {
    case "claude_approval_required":
    case "codex_approval_required":
      return {
        title: `Unblock ${assistant} now`,
        body: `${assistant} requires your decision before proceeding`,
      };
    case "claude_turn_complete":
    case "codex_turn_complete":
      return {
        title: `${assistant} finished`,
        body: `${assistant} is waiting for your next prompt.`,
      };
    default:
      return {
        title: `${assistant} update`,
        body: `${assistant} is waiting for your input.`,
      };
  }
}

async function resolveIOSDeviceIdForRoom(room) {
  // Fast path: use the transient mapping written by the iOS relay peer.
  const roomDoc = await firestore.collection(RELAY_ROOMS_COLLECTION).doc(room).get();
  const presenceDeviceId = roomDoc.data()?.iosDeviceId;
  if (presenceDeviceId) {
    return presenceDeviceId;
  }

  // Fallback: room names are mac device IDs, so recover the owner iOS device from
  // the newest open session for that mac. This keeps pushes working even if the
  // relay presence document is missing or stale.
  const sessionsSnap = await firestore
    .collection("sessions")
    .where("peerDeviceId", "==", room)
    .where("state", "in", ["creating", "active", "grace"])
    .orderBy("createdAt", "desc")
    .limit(1)
    .get();

  const sessionDeviceId = sessionsSnap.docs[0]?.data()?.ownerDeviceId;
  if (sessionDeviceId) {
    console.log(`[fcm] recovered iosDeviceId=${sessionDeviceId} for room=${room} from sessions`);
    return sessionDeviceId;
  }

  const devicesSnap = await firestore
    .collection("devices")
    .where("lastRelayRoomId", "==", room)
    .limit(1)
    .get();

  const boundDeviceId = devicesSnap.docs[0]?.id;
  if (boundDeviceId) {
    console.log(`[fcm] recovered iosDeviceId=${boundDeviceId} for room=${room} from device binding`);
    return boundDeviceId;
  }

  return null;
}

server.listen(port, () => {
  console.log(`relay listening on :${port}`);
});
