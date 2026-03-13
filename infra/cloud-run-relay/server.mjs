import http from "node:http";
import { WebSocketServer } from "ws";

const port = Number(process.env.PORT || 8080);

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

  if (!room) {
    ws.close(1008, "missing_room");
    return;
  }

  const key = roomKey(room);
  const peers = rooms.get(key) || new Set();
  const existingPeers = [...peers];
  peers.add(ws);
  rooms.set(key, peers);

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
    }
  });
});

server.listen(port, () => {
  console.log(`relay listening on :${port}`);
});
