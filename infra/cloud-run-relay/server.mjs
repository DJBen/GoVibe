import { initializeApp } from "firebase-admin/app";
import { Timestamp, getFirestore } from "firebase-admin/firestore";
import http from "node:http";
import { WebSocketServer } from "ws";

const port = Number(process.env.PORT || 8080);
const RELAY_ROOMS_COLLECTION = "relay_rooms";
const HEARTBEAT_INTERVAL_MS = 60_000;

// Auto-initializes from the Cloud Run service account.
initializeApp();
const firestore = getFirestore();

async function setRoomPresence(room) {
  try {
    await firestore.collection(RELAY_ROOMS_COLLECTION).doc(room).set({
      connectedAt: Timestamp.now(),
      lastHeartbeat: Timestamp.now(),
    });
  } catch (err) {
    console.error(`[presence] set failed for ${room}:`, err.message);
  }
}

async function updateRoomHeartbeat(room) {
  try {
    await firestore.collection(RELAY_ROOMS_COLLECTION).doc(room).update({
      lastHeartbeat: Timestamp.now(),
    });
  } catch (err) {
    console.error(`[presence] heartbeat failed for ${room}:`, err.message);
  }
}

async function deleteRoomPresence(room) {
  try {
    await firestore.collection(RELAY_ROOMS_COLLECTION).doc(room).delete();
  } catch (err) {
    console.error(`[presence] delete failed for ${room}:`, err.message);
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

// Refresh lastHeartbeat for every live room so the backend can filter stale entries.
setInterval(() => {
  for (const key of rooms.keys()) {
    updateRoomHeartbeat(key.slice("room:".length));
  }
}, HEARTBEAT_INTERVAL_MS);

const wss = new WebSocketServer({ server, path: "/relay" });

wss.on("connection", (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const room = url.searchParams.get("room") ?? url.searchParams.get("sessionId");

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
  if (peers.size === 1) {
    setRoomPresence(room);
  }

  if (existingPeers.length > 0) {
    const msg = JSON.stringify({ type: "peer_joined" });
    for (const peer of existingPeers) {
      if (peer.readyState === peer.OPEN) {
        peer.send(msg);
      }
    }
  }

  ws.on("message", (data) => {
    for (const peer of peers) {
      if (peer !== ws && peer.readyState === peer.OPEN) {
        peer.send(data);
      }
    }
  });

  ws.on("close", () => {
    peers.delete(ws);
    if (peers.size === 0) {
      rooms.delete(key);
      deleteRoomPresence(room);
    }
  });
});

server.listen(port, () => {
  console.log(`relay listening on :${port}`);
});
