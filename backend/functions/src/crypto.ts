import { createHash, createHmac, randomBytes } from "node:crypto";

export function randomCode(length = 6): string {
  const digits = "0123456789";
  let code = "";
  for (let i = 0; i < length; i += 1) {
    const idx = randomBytes(1)[0] % digits.length;
    code += digits[idx];
  }
  return code;
}

export function sha256(input: string): string {
  return createHash("sha256").update(input).digest("hex");
}

export function signToken(payload: Record<string, unknown>, secret: string, ttlSeconds: number): string {
  const now = Math.floor(Date.now() / 1000);
  const body = {
    ...payload,
    iat: now,
    exp: now + ttlSeconds,
    jti: randomBytes(8).toString("hex")
  };
  const encoded = Buffer.from(JSON.stringify(body), "utf8").toString("base64url");
  const signature = createHmac("sha256", secret).update(encoded).digest("base64url");
  return `${encoded}.${signature}`;
}

export function verifyToken(token: string, secret: string): Record<string, unknown> | null {
  const [encoded, signature] = token.split(".");
  if (!encoded || !signature) {
    return null;
  }

  const expected = createHmac("sha256", secret).update(encoded).digest("base64url");
  if (expected !== signature) {
    return null;
  }

  const payload = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")) as Record<string, unknown>;
  const exp = typeof payload.exp === "number" ? payload.exp : 0;
  if (Math.floor(Date.now() / 1000) >= exp) {
    return null;
  }

  return payload;
}
