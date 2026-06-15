// Autenticación OAuth2 con service account de GCP para la Route Optimization
// API (que NO acepta API key, a diferencia de computeRoutes).
//
// Firma un JWT RS256 con la private key del service account (Web Crypto nativo
// de Deno, sin dependencias) y lo intercambia por un access_token. El token se
// cachea en memoria del módulo (~1h) para no re-firmar en cada invocación.

export interface ServiceAccountKey {
  client_email: string;
  private_key: string;
  token_uri?: string;
  project_id: string;
}

let cached: { token: string; expSec: number } | null = null;

function base64url(data: Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

/** Devuelve un access_token válido para la Route Optimization API. */
export async function getAccessToken(sa: ServiceAccountKey): Promise<string> {
  const nowSec = Math.floor(Date.now() / 1000);
  if (cached && cached.expSec - 60 > nowSec) return cached.token;

  const tokenUri = sa.token_uri || "https://oauth2.googleapis.com/token";
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/cloud-platform",
    aud: tokenUri,
    iat: nowSec,
    exp: nowSec + 3600,
  };
  const unsigned = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned)),
  );
  const jwt = `${unsigned}.${base64url(sig)}`;

  const res = await fetch(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });
  const data = await res.json();
  if (!data.access_token) {
    throw new Error(`OAuth token error: ${data.error_description ?? data.error ?? res.status}`);
  }
  cached = { token: data.access_token, expSec: nowSec + (data.expires_in ?? 3600) };
  return data.access_token;
}

/** Solo para tests: limpia el cache del token. */
export function _resetTokenCache(): void {
  cached = null;
}
