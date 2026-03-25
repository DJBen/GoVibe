/**
 * Redis pub/sub backplane for cross-instance room message routing.
 *
 * When REDIS_URL is set, every relay instance subscribes to Redis channels
 * for its active rooms and publishes messages so peers on other instances
 * receive them. When REDIS_URL is unset, all exports are silent no-ops and
 * the relay operates in local-only mode (current behaviour).
 */

import Redis from "ioredis";
import { randomUUID } from "node:crypto";

export const instanceId = randomUUID();

let pub = null;
let sub = null;
let alive = false;

// channel → { onData, onPresence }
const roomHandlers = new Map();

// ── helpers ──────────────────────────────────────────────────────────────

function dataChannel(roomKey) {
  return `relay:${roomKey}`;
}

function presenceChannel(roomKey) {
  return `relay:${roomKey}:presence`;
}

const TEXT_PREFIX = 0x00;
const BIN_PREFIX = 0x01;
const ID_LEN = 36; // UUID length

function encodeText(data) {
  return JSON.stringify({ src: instanceId, data });
}

function encodeBinary(buf) {
  const header = Buffer.alloc(1 + ID_LEN);
  header[0] = BIN_PREFIX;
  header.write(instanceId, 1, "ascii");
  return Buffer.concat([header, buf]);
}

// ── public API ───────────────────────────────────────────────────────────

export function init(redisUrl) {
  if (!redisUrl) {
    console.log("[backplane] no REDIS_URL, local-only mode");
    return;
  }

  const common = {
    lazyConnect: true,
    maxRetriesPerRequest: null, // infinite retry for subscriber
    retryStrategy(times) {
      return Math.min(times * 200, 5000);
    },
  };

  pub = new Redis(redisUrl, { ...common, maxRetriesPerRequest: 3 });
  sub = new Redis(redisUrl, { ...common });

  function updateAlive() {
    alive = pub?.status === "ready" && sub?.status === "ready";
  }

  for (const client of [pub, sub]) {
    client.on("ready", () => {
      updateAlive();
      console.log(`[backplane] ${client === pub ? "pub" : "sub"} connected`);
    });
    client.on("close", () => {
      updateAlive();
    });
    client.on("error", (err) => {
      updateAlive();
      console.error(`[backplane] ${client === pub ? "pub" : "sub"} error:`, err.message);
    });
  }

  // Re-subscribe all active channels on reconnect.
  sub.on("ready", () => {
    const channels = [...roomHandlers.keys()].flatMap((rk) => [
      dataChannel(rk),
      presenceChannel(rk),
    ]);
    if (channels.length > 0) {
      sub.subscribe(...channels).catch((err) => {
        console.error("[backplane] re-subscribe failed:", err.message);
      });
    }
  });

  // Route incoming messages to the correct room handler.
  sub.on("messageBuffer", (channelBuf, messageBuf) => {
    const channel = channelBuf.toString();

    // Determine which room this channel belongs to and whether it's presence.
    const isPresence = channel.endsWith(":presence");
    // Strip "relay:" prefix and optional ":presence" suffix to recover roomKey.
    const roomKey = isPresence
      ? channel.slice(6, -9) // "relay:".length=6, ":presence".length=9
      : channel.slice(6);

    const handler = roomHandlers.get(roomKey);
    if (!handler) return;

    if (isPresence) {
      try {
        const msg = JSON.parse(messageBuf.toString());
        if (msg.src === instanceId) return; // skip self
        handler.onPresence(msg);
      } catch (_) {}
    } else {
      // Data channel — detect text vs binary from first byte.
      if (messageBuf[0] === BIN_PREFIX) {
        const src = messageBuf.toString("ascii", 1, 1 + ID_LEN);
        if (src === instanceId) return;
        const payload = messageBuf.subarray(1 + ID_LEN);
        handler.onData(payload, true);
      } else {
        try {
          const msg = JSON.parse(messageBuf.toString());
          if (msg.src === instanceId) return;
          handler.onData(msg.data, false);
        } catch (_) {}
      }
    }
  });

  pub.connect();
  sub.connect();
  console.log("[backplane] initializing with Redis");
}

export function isAlive() {
  return alive;
}

/**
 * Subscribe to a room's data and presence channels.
 * @param {string} roomKey  e.g. "room:host1-ctl"
 * @param {(data: Buffer|string, isBinary: boolean) => void} onData
 * @param {(msg: {type: string}) => void} onPresence
 */
export function subscribe(roomKey, onData, onPresence) {
  if (!sub) return;
  roomHandlers.set(roomKey, { onData, onPresence });
  sub.subscribe(dataChannel(roomKey), presenceChannel(roomKey)).catch((err) => {
    console.error(`[backplane] subscribe ${roomKey} failed:`, err.message);
  });
}

export function unsubscribe(roomKey) {
  if (!sub) return;
  roomHandlers.delete(roomKey);
  sub.unsubscribe(dataChannel(roomKey), presenceChannel(roomKey)).catch((err) => {
    console.error(`[backplane] unsubscribe ${roomKey} failed:`, err.message);
  });
}

/**
 * Publish a data message to all other instances subscribed to this room.
 */
export function publishData(roomKey, data, isBinary) {
  if (!alive) return;
  const channel = dataChannel(roomKey);
  if (isBinary) {
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
    pub.publishBuffer(channel, encodeBinary(buf));
  } else {
    const str = typeof data === "string" ? data : data.toString();
    pub.publish(channel, encodeText(str));
  }
}

/**
 * Publish a presence event (peer_joined / peer_left) to other instances.
 */
export function publishPresence(roomKey, type, localCount) {
  if (!alive) return;
  pub.publish(
    presenceChannel(roomKey),
    JSON.stringify({ src: instanceId, type, localCount }),
  );
}
