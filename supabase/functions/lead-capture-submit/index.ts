// MAF CRM — lead-capture-submit Edge Function
// ============================================
// Public lead-capture endpoint. Turnstile-gated. Writes to public.lead_captures
// via direct Postgres (npm:postgres@3.4.4).
//
// HOME (G decision, 2026-09-10): scorecard quiz leads are SALES data — this
// function and the lead_captures table live in the maf-crm project
// (<your-project-ref>). The portal (MAF-Deploy) is client-first, post-sale
// only; migrated from functions/lead-capture-submit in the maf-deploy repo.
//
// Env: SUPABASE_DB_URL (required, fail-closed), TURNSTILE_SECRET (required,
// fail-closed).
//
// Hardening pass (2026-09-07, PR #17) — closes the four pre-existing findings
// from the PR #16 recovery audit:
//   1. Column allowlist: explicit INSERT column list (name, email,
//      constraint_id, scores) — the select-star json_populate_record path let
//      crafted payloads set ANY column (id, created_at backdating, etc.).
//      id and created_at are now impossible to supply — DB-assigned only.
//   2. Validation: constraint_id allowlist (demand | conversion, grounded in
//      live production data); email format check; name/email/constraint_id
//      required and length-capped; scores shape-checked (flat object of
//      number|string|boolean, max 16 keys, 256 chars per value).
//   3. Body-size cap: 8KB hard limit (request.body() is not size-limited by
//      the runtime; the previous version read unbounded JSON).
//   4. Error logging: insert failures now log sanitized error to
//      console.error for operator visibility (previously silent swallow).
// Plus: per-IP rate limiting (60 req / 5 min sliding window, in-memory,
// best-effort — bounded by runtime instance lifetime; Turnstile remains the
// primary abuse control).
//
// Recovery lineage: functions/lead-capture-submit/index.ts was recovered
// byte-identical from live v18 in PR #16; this diff is the first reviewed
// change to that source. Live v18 keeps serving until this deploys.

import postgres from "npm:postgres@3.4.4";

// Service-auth path (2026-09-08, G decision B): trusted server relays (the
// scorecard quiz's Vercel function) call this function server-to-server.
// A constant-time secret check replaces the browser captcha wall — the
// relay has ALREADY verified Turnstile itself. All other protections
// (validation, rate limit, body cap, error logging) apply identically.
import { constantTimeCompare, sanitizeError } from "../../_shared/auth.ts";

const SUPABASE_DB_URL = Deno.env.get("SUPABASE_DB_URL");
const TURNSTILE_SECRET = Deno.env.get("TURNSTILE_SECRET");
const SERVICE_SECRET = Deno.env.get("LEAD_CAPTURE_SERVICE_SECRET") || "";

if (!SUPABASE_DB_URL) throw new Error("SUPABASE_DB_URL is required");
if (!TURNSTILE_SECRET) throw new Error("TURNSTILE_SECRET is required");

const sql = postgres(SUPABASE_DB_URL, {
  prepare: true,
  max: 3,
  idle_timeout: 20,
  connect_timeout: 10,
});

// --- Hardening constants -----------------------------------------------------

const MAX_BODY_BYTES = 8 * 1024; // 8KB — lead form payloads are small
const MAX_NAME_LEN = 120;
const MAX_EMAIL_LEN = 254; // RFC 5321 max
const MAX_CONSTRAINT_ID_LEN = 32;
const MAX_SCORES_KEYS = 16;
const MAX_SCORES_VALUE_LEN = 256;

// Grounded in the scorecard quiz's actual vector domain (index.html vectors):
// demand, conversion, delivery, cashflow, retention, support. The original
// allowlist (demand/conversion) was grounded in lead_captures table data —
// which turned out to be build-period test data from before the RLS change,
// not the producer's real domain.
const ALLOWED_CONSTRAINT_IDS = [
  "demand",
  "conversion",
  "delivery",
  "cashflow",
  "retention",
  "support",
] as const;

// Per-IP sliding window: 60 requests / 5 minutes.
const RATE_LIMIT_MAX = 60;
const RATE_LIMIT_WINDOW_MS = 5 * 60 * 1000;
const RATE_WINDOW_MAX_BUCKETS = 1000;
const rateWindow: Map<string, number[]> = new Map();

// Simple email shape: local@domain with a dot in the domain. Deliberately
// permissive (no full RFC 5322) — the goal is rejecting junk, not mail-server
// validation.
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@.]+(\.[^\s@.]+)+$/;

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export function clientIp(req: Request): string | null {
  // cf-connecting-ip is set by Cloudflare and trustworthy when present;
  // x-forwarded-for is client-spoofable — used only as a fallback for
  // rate-limit bucketing, never for auth.
  return req.headers.get("cf-connecting-ip") ??
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? null;
}

export function rateLimited(ip: string): boolean {
  const now = Date.now();
  const cutoff = now - RATE_LIMIT_WINDOW_MS;
  const hits = (rateWindow.get(ip) ?? []).filter((t) => t > cutoff);
  if (hits.length >= RATE_LIMIT_MAX) {
    rateWindow.set(ip, hits);
    return true;
  }
  hits.push(now);
  rateWindow.set(ip, hits);
  // Audit fold r2: hard memory bound under spoofed-XFF floods — evict the
  // oldest entry whenever the map exceeds its cap (in addition to the
  // existing stale-bucket sweep).
  if (rateWindow.size > RATE_WINDOW_MAX_BUCKETS) {
    let oldestKey: string | null = null;
    let oldestTime = Infinity;
    for (const [key, times] of rateWindow) {
      const first = times.length > 0 ? times[0] : Infinity;
      if (first < oldestTime) {
        oldestTime = first;
        oldestKey = key;
      }
    }
    if (oldestKey !== null) rateWindow.delete(oldestKey);
  }
  return false;
}

// Turnstile verification — server-side siteverify with the secret. Fail-closed
// on upstream error. (Unchanged from v18: the audit confirmed this path is
// sound and not bypassable.)
async function verifyTurnstile(token: string, ip?: string | null) {
  const body = new URLSearchParams({
    secret: TURNSTILE_SECRET!,
    response: token,
  });

  if (ip) body.set("remoteip", ip);

  const res = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });

  if (!res.ok) {
    // consume the body so the connection is released (resource hygiene —
    // surfaced by deno's test leak detection)
    await res.text();
    return false;
  }
  const result = await res.json();
  return result?.success === true;
}

// --- Payload validation ------------------------------------------------------

export interface ValidLead {
  name: string;
  email: string;
  constraint_id: string;
  scores: Record<string, string | number | boolean | number[]>;
}

export function validateLead(payload: Record<string, unknown>): {
  lead: ValidLead | null;
  error: string | null;
} {
  // Control/zero-width chars rejected for data hygiene (audit fold r2:
  // NUL/newline/zero-width were accepted; harmless to the DB but junk in it).
  // Built via code points, not a regex literal, to satisfy no-control-regex.
  const CONTROL_CHARS = [
    ...Array.from({ length: 0x20 }, (_, i) => String.fromCharCode(i)), // C0: \x00-\x1F
    String.fromCharCode(0x7F), // DEL
    ...Array.from({ length: 5 }, (_, i) => String.fromCharCode(0x200B + i)), // ZWSP family
    String.fromCharCode(0x2028), // line separator
    String.fromCharCode(0x2029), // paragraph separator
  ];
  const hasControl = (s: string) => CONTROL_CHARS.some((c) => s.includes(c));

  const name = payload.name;
  if (typeof name !== "string" || name.trim().length === 0) {
    return { lead: null, error: "Invalid name" };
  }
  if (name.length > MAX_NAME_LEN || hasControl(name)) {
    return { lead: null, error: "Invalid name" };
  }

  const email = payload.email;
  if (typeof email !== "string" || !EMAIL_RE.test(email)) {
    return { lead: null, error: "Invalid email" };
  }
  if (email.length > MAX_EMAIL_LEN || hasControl(email)) {
    return { lead: null, error: "Invalid email" };
  }

  const constraintId = payload.constraint_id;
  if (
    typeof constraintId !== "string" ||
    !ALLOWED_CONSTRAINT_IDS.includes(constraintId as typeof ALLOWED_CONSTRAINT_IDS[number])
  ) {
    return { lead: null, error: "Invalid constraint_id" };
  }
  if (constraintId.length > MAX_CONSTRAINT_ID_LEN) {
    return { lead: null, error: "Invalid constraint_id" };
  }

  // Scores arrive in two shapes from the known producer set:
  //  - scorecard quiz: array of 6 finite numbers (one per vector), stored
  //    as { values: [...] } to keep the jsonb flat-object convention
  //  - future/detail forms: flat object of primitives (validated below)
  let scores: Record<string, string | number | boolean | number[]> = {};
  if ("scores" in payload && payload.scores !== undefined && payload.scores !== null) {
    if (Array.isArray(payload.scores)) {
      // Array form (scorecard quiz): EXACTLY 6 integers 0-3 — the array is
      // positional (one per vector: demand, conversion, delivery, cashflow,
      // retention, support), so a partial array would be ambiguous garbage.
      const arr = payload.scores as unknown[];
      if (arr.length !== 6) {
        return { lead: null, error: "Invalid scores" };
      }
      for (const v of arr) {
        if (
          typeof v !== "number" || !Number.isInteger(v) || v < 0 || v > 3
        ) {
          return { lead: null, error: "Invalid scores" };
        }
      }
      scores = { values: arr as number[] };
    } else if (typeof payload.scores === "object") {
      const raw = payload.scores as Record<string, unknown>;
      const keys = Object.keys(raw);
      if (keys.length > MAX_SCORES_KEYS) {
        return { lead: null, error: "Invalid scores" };
      }
      // Reserve the 'values' key — array-form submissions are stored as
      // { values: [...] }, so a flat object carrying a 'values' key would be
      // ambiguous for downstream jsonb readers.
      if (Object.hasOwn(raw, "values")) {
        return { lead: null, error: "Invalid scores" };
      }
      for (const k of keys) {
        const v = raw[k];
        if (
          typeof v !== "string" && typeof v !== "number" && typeof v !== "boolean"
        ) {
          return { lead: null, error: "Invalid scores" };
        }
        // Audit fold r2: NaN/Infinity silently serialized to JSON null by
        // JSON.stringify — reject non-finite numbers at the door.
        if (typeof v === "number" && !Number.isFinite(v)) {
          return { lead: null, error: "Invalid scores" };
        }
        if (typeof v === "string" && v.length > MAX_SCORES_VALUE_LEN) {
          return { lead: null, error: "Invalid scores" };
        }
      }
      scores = raw as Record<string, string | number | boolean>;
    } else {
      // scores must be an array (quiz) or a flat object — anything else
      // (string, number, boolean) is junk. This branch existed in the
      // original hardening and was lost in the r3 array-form fold; the
      // "rejects bad scores shapes" test caught it.
      return { lead: null, error: "Invalid scores" };
    }
  }

  return {
    lead: { name: name.trim(), email, constraint_id: constraintId, scores },
    error: null,
  };
}

// Import-safety (PR-#12 serve-guard convention): bind the port only when run
// as the entrypoint — unit tests import the pure helpers without starting a
// server. Supabase's runtime runs the file as main; behavior is unchanged
// in deployment.
// Injectable collaborators (2026-09-08): tests override these to exercise
// the full serve path — the previously unreachable 500+log branch is now
// behaviorally testable (final audit nit from PR #17 closed).
export const _internals = {
  verifyTurnstile,
  insertLead: async (lead: ValidLead): Promise<void> => {
    await sql`
      insert into public.lead_captures (name, email, constraint_id, scores)
      values (${lead.name}, ${lead.email}, ${lead.constraint_id}, ${
      JSON.stringify(lead.scores)
    }::jsonb)
    `;
  },
};

export async function handler(req: Request): Promise<Response> {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const ip = clientIp(req);
  if (ip && rateLimited(ip)) {
    return json({ error: "Too many requests" }, 429);
  }

  // Service-auth branch (trusted relays): constant-time secret in the
  // Authorization header. The relay has ALREADY verified Turnstile — skip
  // the captcha wall, keep every other protection.
  const authHeader = req.headers.get("authorization") || "";
  const isServiceAuth = SERVICE_SECRET !== "" &&
    authHeader.startsWith("Bearer ") &&
    constantTimeCompare(authHeader.slice(7), SERVICE_SECRET);

  // Hard body-size cap before parsing (audit fold r2: byte-true length, not
  // UTF-16 code units — a multibyte body could exceed 8KB actual bytes under
  // the old raw.length check).
  const contentLength = req.headers.get("content-length");
  if (contentLength && parseInt(contentLength, 10) > MAX_BODY_BYTES) {
    return json({ error: "Payload too large" }, 413);
  }
  const raw = await req.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) {
    return json({ error: "Payload too large" }, 413);
  }

  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(raw);
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
    return json({ error: "Invalid JSON body" }, 400);
  }

  if (isServiceAuth) {
    // Trusted relay — no captchaToken expected. Straight to validation.
    const { lead, error } = validateLead(payload);
    if (error || !lead) return json({ error }, 400);

    try {
      await _internals.insertLead(lead);
      return json({ ok: true }, 200);
    } catch (e) {
      const msg = e instanceof Error ? e.message : "unknown error";
      console.error(
        `[lead-capture-submit] insert failed: ${sanitizeError(msg).slice(0, 200)}`,
      );
      return json({ error: "Insert failed" }, 500);
    }
  }

  // Browser path: Turnstile wall, then validation, then insert.
  const captchaToken = payload.captchaToken;
  if (typeof captchaToken !== "string" || captchaToken.length < 10) {
    return json({ error: "Captcha token is required" }, 400);
  }

  const captchaOk = await _internals.verifyTurnstile(captchaToken, ip);
  if (!captchaOk) return json({ error: "Captcha verification failed" }, 403);

  delete payload.captchaToken;

  const { lead, error } = validateLead(payload);
  if (error || !lead) return json({ error }, 400);

  try {
    await _internals.insertLead(lead);
    return json({ ok: true }, 200);
  } catch (e) {
    // Sanitized error logging — operators can see insert failures in logs
    // without leaking connection-string fragments or SQL internals.
    const msg = e instanceof Error ? e.message : "unknown error";
    console.error(
      `[lead-capture-submit] insert failed: ${sanitizeError(msg).slice(0, 200)}`,
    );
    return json({ error: "Insert failed" }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handler);
}
