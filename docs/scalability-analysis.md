# GoVibe Backend Scalability Analysis

## Architecture Overview

```
iOS Client ──[HTTPS]──► Firebase Cloud Functions (max 50 instances)
                              │
                              ├──► Firestore (devices, sessions, relay_rooms)
                              └──► Relay Token signing

iOS Client ──[WSS]────► Cloud Run Relay Server (in-memory room state)
Mac Host   ──[WSS]────►       │
                              ├──► Firestore (presence/relay_rooms)
                              └──► FCM (push notifications)
```

---

## Component-by-Component Scaling

### 1. Firebase Cloud Functions — Hard ceiling at 50 instances

The API gateway is configured with `maxInstances: 50`. Each request requires Firebase token
verification (network round-trip) + 1–2 Firestore reads.

| Load | Requests/sec | Instances needed | Status |
|------|-------------|------------------|--------|
| 100 devices (30s heartbeat) | ~3 req/s | 1 | Fine |
| 1K devices | ~33 req/s | ~5 | Fine |
| 5K devices | ~167 req/s | ~25 | Fine |
| 10K devices | ~333 req/s | ~50 | **At hard ceiling** |
| 20K devices | ~667 req/s | 100 needed | **Breached** |

Session creation/discovery adds bursts on top of heartbeat baseline. The `maxInstances: 50` limit
is the first constraint you'll hit and it's a config value — easily raised, but needs to be
intentional.

---

### 2. Cloud Run Relay Server — PRIMARY architectural bottleneck

This is the critical constraint. The relay uses an **in-memory `Map`** for room state:

```js
const rooms = new Map() // room → Set<WebSocket>
```

**This means horizontal scaling breaks the architecture.** If Cloud Run spins up a second instance,
rooms on instance A are invisible to instance B. A host connecting to instance A and a client routed
to instance B can never exchange messages.

Memory per connection estimate:
- WebSocket overhead: ~8–15 KB per socket
- Message queue: up to 2,000 messages × ~0.5 KB avg = ~1 MB per active room (worst case)
- Typical active room: ~50 KB (mostly queue)

| Concurrent sessions | WebSocket connections | Relay RAM needed | Single-instance viable? |
|--------------------|-----------------------|------------------|------------------------|
| 50 | ~150 (2 per session + ctl) | ~50 MB | Yes |
| 200 | ~600 | ~200 MB | Yes (1 vCPU, 512 MB default) |
| 500 | ~1,500 | ~500 MB | Marginal — needs 1 GB instance |
| 1,000 | ~3,000 | ~1 GB | **No** — needs multiple instances |
| 5,000 | ~15,000 | ~5 GB | **Requires distributed state** |

**Network bandwidth is the second relay constraint.** Simulator and app-window sessions stream
binary video frames:

- Simulator at 30 fps @ ~30 KB/frame = ~900 KB/s per session
- 100 active simulator sessions = ~90 MB/s relay throughput
- 500 active simulator sessions = ~450 MB/s → exceeds typical Cloud Run egress at ~1,000 sessions

Terminal sessions are much lighter (~2–5 KB/s of PTY output under typical use).

---

### 3. Firestore — Scales well, with specific hot-spot risks

Firestore auto-scales reads/writes globally. The risk areas:

**`relay_rooms` collection** — Written on every peer join/leave by the relay server. At 500 active
sessions with frequent reconnects, this collection sees ~10–20 writes/second. Firestore handles 1
write/second *per document*, so this is safe as long as rooms are separate documents (they are —
keyed by room ID).

**`sessions` collection** — Each heartbeat via relay transport updates `lastHeartbeat`. At 1,000
active sessions, that's ~1,000 writes/minute. Fine for Firestore.

**`devices` collection** — Mac hosts heartbeat every 30s. At 1,000 hosts = ~33 writes/second
across distinct documents. Fine.

**Firestore pricing at scale:**
- 1K daily active users × 100 writes/day = 100K writes → $0.06 (near free)
- 10K DAU × 100 writes = 1M writes/day → $0.60/day → still cheap
- Relay room presence writes (join/leave) could be 10× the session volume

---

### 4. Session Types — Scaling Profiles Differ Significantly

**Terminal sessions** — Light on relay, heavy on Mac host CPU
- PTY output: ~2–10 KB/s under normal use, spikes during builds
- Relay CPU: Mostly base64 passthrough, negligible per-message cost
- Bottleneck: Mac host's CPU/RAM for the terminal process itself
- Scale concern: None at the relay/backend level

**Simulator sessions** — High bandwidth relay consumers
- Frame data: ~30–900 KB/s depending on content change rate
- Relay acts as dumb forwarder for binary frames, but throughput matters
- 100 concurrent simulator sessions ≈ 90 MB/s through the relay server
- Hits network egress limits before CPU limits

**App-window sessions** — Similar to simulator, slightly lower framerate
- macOS window capture tends to be lower resolution than full simulator
- Similar bandwidth profile, slightly lighter

---

### 5. Firebase Auth Token Verification — Latency tax per request

Every API call hits Firebase's token verification endpoint. This adds ~50–150ms of network latency
per request on top of Firestore reads. At 50 Cloud Functions instances each handling one
request/100ms, theoretical throughput is ~500 req/s. Realistic sustained throughput accounting for
token verification is ~200–300 req/s.

Acceptable up to ~10K devices on 30-second heartbeat intervals.

---

### 6. FCM Push Notifications — Not a bottleneck

FCM default rate limit is 10K messages/minute per project. At 1K concurrent users each receiving 1
notification per minute, you're at 10% of quota. Not a concern until 10K+ concurrent users all
receiving high-frequency notifications.

---

## Scaling Thresholds Summary

| Users | Terminal sessions | Simulator sessions | Status | Primary constraint |
|-------|------------------|-------------------|--------|-------------------|
| <100 | <100 | <50 | Fine | None |
| ~500 | <500 | <100 | Fine | Relay RAM at ~512 MB |
| ~1,000 | <1,000 | <200 | Warning | Relay hits single-instance RAM limit |
| ~2,000 | any | any | **Relay architecture breaks** | In-memory state prevents horizontal scale |
| ~10,000 | any | any | **Cloud Functions ceiling** | 50-instance limit hit |

---

## The Two Structural Issues to Solve First

### Issue 1: Stateful relay prevents horizontal scaling

The relay's `const rooms = new Map()` is the architectural ceiling. To go beyond ~1,000 concurrent
sessions, you need one of:

- **Redis pub/sub** backing the room state (Cloud Memorystore for Redis, ~$50/month for a small
  instance)
- **Consistent hash routing** — a load balancer hashes `room` to always hit the same relay
  instance (works but creates uneven load and single points of failure per shard)
- **Separation by session type** — terminal rooms vs simulator rooms routed to different relay
  clusters (see [Session Type Separation](#session-type-separation) below)

### Issue 2: Cloud Functions `maxInstances: 50`

This is just a config value in `backend/functions/src/index.ts`. Raising it to 200–500 costs
nothing until instances are actually allocated, and removes the hard ceiling on API throughput.

---

## What Holds Up Well

- **Firestore** — designed for this pattern; the collections and document structure are appropriate;
  will scale to millions of sessions without changes
- **Firebase Auth** — completely managed; no scaling concern
- **FCM** — not a bottleneck at projected scale
- **The session state machine** (creating → active ↔ grace → closed) — clean; Firestore handles
  the state durably
- **Mac host session isolation** — each terminal/simulator/window session runs independently
  per-host; the backend doesn't coordinate across hosts

---

## Session Type Separation

Separating relay traffic by session type is the most practical path to scale without introducing
Redis or a stateful coordination layer. The insight is that terminal and simulator/window sessions
have radically different resource profiles and can be independently scaled.

### Terminal Session Relay — RAM Budget for 5,000 Concurrent Users

Terminal sessions are CPU-light and bandwidth-light. The relay is a pure message router for PTY
output (base64 text) and keyboard input.

**Per-session memory breakdown:**
```
2 WebSocket sockets (host + client):     20 KB
1 control-channel socket (host):         10 KB
Message queue (2,000 msgs × 200 B avg): 400 KB  ← dominates
Relay room metadata + buffers:           10 KB
Total per session:                      ~440 KB
```

The 200 B average per message is intentionally conservative for terminal output — most frames are
small incremental diffs. A saturated tmux session during a build could burst to 4 KB/message, but
the queue drains faster than it fills under normal conditions.

**RAM for 5,000 concurrent terminal sessions:**

| Component | Per-session | × 5,000 | Total |
|-----------|------------|---------|-------|
| WebSocket sockets (3 per session) | 30 KB | × 5,000 | 150 MB |
| Message queues | 400 KB | × 5,000 | 2,000 MB |
| Node.js runtime + overhead | — | — | 200 MB |
| OS/kernel socket buffers | ~4 KB | × 15,000 | 60 MB |
| **Total** | | | **~2.4 GB** |

**Recommended Cloud Run configuration for a terminal relay:**

```
Memory:  4 GB  (2.4 GB working + 40% headroom for burst queues)
CPU:     2 vCPU
Max concurrency: 1000 sessions per instance
Instances needed: 5 (5,000 ÷ 1,000)
Min instances: 2 (avoid cold start on reconnect)
```

**Network bandwidth for 5,000 terminal sessions:**
- Avg PTY output: 5 KB/s per active session (conservative; idle sessions near 0)
- 5,000 sessions × 5 KB/s = 25 MB/s relay throughput
- Cloud Run instance egress cap: ~1 Gbps = 125 MB/s per instance
- 5 instances provide 625 MB/s headroom — completely fine

**Cost estimate (us-central1):**
- 5 × 4 GB / 2 vCPU Cloud Run instances, ~$0.10/hour each at full utilization
- At 5,000 concurrent users: ~$0.50/hour = ~$360/month for compute
- Plus egress: 25 MB/s × 2,592,000 s/month = ~64 TB/month → ~$640/month at $0.01/GB
- **Total terminal relay: ~$1,000/month at 5,000 sustained concurrent users**

The in-memory architecture still applies per instance. With 5 instances, you need consistent hash
routing (hash of `room` ID → instance index). This is a single nginx/Envoy config change and adds
no stateful coordination.

---

### Simulator / App-Window Session Relay — Dedicated Setup

Simulator and window sessions are **bandwidth-dominated**, not RAM-dominated. The relay forwards
opaque binary frames — it does no processing, just fans out to connected peers.

**Per-session bandwidth profile:**
```
Simulator (30 fps, moderate content change):
  Frame size: 15–60 KB compressed (JPEG/WebP)
  Throughput: 450 KB/s – 1.8 MB/s per session

App window (30 fps, lower resolution):
  Frame size: 8–30 KB compressed
  Throughput: 240 KB/s – 900 KB/s per session

Keyboard/pointer input (reverse direction):
  Throughput: ~1 KB/s (negligible)
```

**RAM per simulator session:**
```
2 WebSocket sockets:                     20 KB
Message queue (2,000 × 30 KB avg):   60,000 KB  ← massive if queue backs up
Relay room metadata:                     10 KB
Total per session (queue drained):      ~30 KB
Total per session (queue saturated):   ~60 MB
```

The message queue is the risk. If a client is slow to consume frames, the 2,000-message queue for
a 30 KB/frame simulator session uses 60 MB per room. The relay's current FIFO drop (oldest frame
evicted first) is the right behavior — stale video frames are worthless.

**Recommended architecture for simulator/window relay:**

Option A — **Regional Cloud Run with large instances, strict concurrency limit**

```
Memory:  8 GB per instance
CPU:     4 vCPU
Max concurrency: 100 sessions per instance  ← hard limit, not soft
Min instances: 2 per region
Autoscale trigger: concurrency > 80 sessions
```

| Concurrent sim sessions | Instances needed | RAM in use | Network per instance |
|------------------------|-----------------|------------|---------------------|
| 100 | 1 | ~1 GB | ~90 MB/s |
| 500 | 5 | ~5 GB | ~90 MB/s each |
| 1,000 | 10 | ~10 GB | ~90 MB/s each |
| 5,000 | 50 | ~50 GB | ~90 MB/s each |

Network is the binding constraint: 100 sessions × 900 KB/s avg = 90 MB/s per instance. A single
Cloud Run instance with 4 vCPU gets a higher network tier (~2 Gbps), so 100-session concurrency
leaves comfortable headroom.

**Cost estimate for 1,000 concurrent simulator sessions:**
- 10 × 8 GB / 4 vCPU instances: ~$0.40/hour each = $4/hour
- Egress: 1,000 × 900 KB/s = 900 MB/s × 2,592,000 s/month = ~2.3 PB — this is extreme
- In practice: simulator sessions average 30 min, not 24/7; assume 20% active at peak
- Realistic: 200 truly-active sessions = 180 MB/s = ~46 TB/month → ~$460/month egress
- **Total simulator relay: ~$750/month at 1,000 peak / 200 sustained concurrent sessions**

Option B — **WebRTC peer-to-peer for simulator/window sessions (bypass relay entirely)**

The relay is purely a signaling/forwarding layer. Simulator and window sessions are ideal
candidates for WebRTC DataChannel or MediaStream delivery directly between Mac host and iOS client:

```
Current:  Mac Host → Relay (Cloud Run) → iOS Client   [relay pays egress twice]
WebRTC:   Mac Host ─────────────────── iOS Client      [STUN/TURN only for NAT]
```

Benefits:
- Relay egress cost drops to near zero for video frames
- Latency improves (no relay hop)
- TURN server handles NAT traversal; only falls back when direct path fails (~15–20% of cases)
- TURN traffic is much cheaper than relay egress because most connections go direct

The session infrastructure (signaling, tokens, session state) already exists in Firestore. The
relay would still handle signaling/control messages; only the binary frame stream moves to WebRTC.

This is the recommended long-term path for simulator and window sessions at scale.

---

## Recommended Separation Architecture

```
┌─────────────────────────────────────────────────────┐
│              Load Balancer / API Gateway             │
│         (route by room prefix or session type)      │
└──────┬──────────────────────────┬────────────────────┘
       │                          │
       ▼                          ▼
┌─────────────┐           ┌──────────────────┐
│  Terminal   │           │ Simulator/Window │
│   Relay     │           │     Relay        │
│             │           │                  │
│  5 × 4 GB   │           │  10 × 8 GB       │
│  instances  │           │  instances       │
│  (hashed)   │           │  (hashed)        │
│             │           │                  │
│ ~5,000 ccx  │           │ ~1,000 ccx       │
└─────────────┘           └──────────────────┘
       │                          │
       └──────────┬───────────────┘
                  ▼
         Firestore + FCM
         (unchanged, shared)
```

**Room naming drives routing** — terminal rooms already differ from session rooms by naming
convention (`{hostId}-ctl` vs `{hostId}-{sessionId}`). Add a session type field to the relay token
payload and use it at the load balancer to select the appropriate relay cluster.

**Within each cluster**, consistent hash routing on `room` ensures the same room always reaches
the same instance — no Redis required until you need cross-instance failover.

---

## Implementation Sequence

1. **Immediate (free):** Raise `maxInstances` from 50 → 500 in Cloud Functions config
2. **~500 concurrent sessions:** Add 4 GB RAM to relay Cloud Run instance; set `concurrency: 1000`
3. **~1,000 concurrent sessions:** Split relay into terminal and simulator clusters; add nginx
   consistent-hash routing on `room` query param
4. **~2,000+ concurrent sessions:** Add Redis-backed room state OR move simulator frames to WebRTC
5. **~10,000 concurrent sessions:** Full WebRTC for video, Redis pub/sub for terminal relay,
   regional deployment
