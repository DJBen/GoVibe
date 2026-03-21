export interface RuntimeConfig {
  turnUrls: string[];
  turnUsernamePrefix: string;
  sessionTokenSecret: string;
  relayTokenSecret: string;
  turnSecret: string;
  sessionTtlSeconds: number;
  relayTokenTtlSeconds: number;
  graceTtlSeconds: number;
}

export function getConfig(): RuntimeConfig {
  const turnUrls = (process.env.TURN_URLS || "turn:turn.govibe.dev:3478?transport=udp")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);

  return {
    turnUrls,
    turnUsernamePrefix: process.env.TURN_USERNAME_PREFIX || "govibe",
    sessionTokenSecret: process.env.SESSION_TOKEN_SECRET || "dev-session-secret",
    relayTokenSecret: process.env.RELAY_TOKEN_SECRET || process.env.SESSION_TOKEN_SECRET || "dev-relay-secret",
    turnSecret: process.env.TURN_SECRET || "dev-turn-secret",
    sessionTtlSeconds: Number(process.env.SESSION_TTL_SECONDS || 3600),
    relayTokenTtlSeconds: Number(process.env.RELAY_TOKEN_TTL_SECONDS || 300),
    graceTtlSeconds: Number(process.env.GRACE_TTL_SECONDS || 180)
  };
}
