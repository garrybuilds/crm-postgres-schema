// supabase/functions/smartlead-webhook/index.ts
// Speed-to-Lead Bot receiver (spec 03, P1+P2) — 2026-09-03.
//
// Flow (spec §4): verify secret → parse → raw-payload audit → dedupe →
// classify (replies) → crm_activities write → 200 OK fast.
//
// HARD RULES (spec §4 storage + CRM touchpoints):
//   - NO creates of contacts/companies/deals. Contact lookup is READ-ONLY.
//   - NO deal stage mutations (spec: "no status/field mutations without Garry").
//   - NO outbound sends of any kind. This function has zero send capability.
//   - Dedupe key (external_id, activity_type) enforced BEFORE notify/write;
//     DB unique index idx_activities_external_dedup is the backstop.
//   - Fail toward attention: unclassifiable reply → treated as positive.
//
// Deploy (staged — Garry runs; config.toml has verify_jwt=false):
//   supabase functions deploy smartlead-webhook --project-ref <your-project-ref>
//   supabase secrets set SMARTLEAD_WEBHOOK_SECRET=<secret>   (then append ?secret=… to webhook URL)
//
// Audit tables:
//   - sys_processed_webhooks (EXISTS) — idempotency ledger, one row per processed event.
//   - sys_webhook_events (STAGED migration 20260903000000) — raw payload audit +
//     notification queue for the P3 box-side notifier. Absent ⇒ best-effort degrade.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("SMARTLEAD_WEBHOOK_SECRET") || "";

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// ─── Payload normalization (field-name variants across Smartlead event types) ───

interface NormalizedEvent {
  event_type: string;
  email: string;
  first_name: string;
  last_name: string;
  company_name: string;
  campaign_id: string;
  campaign_name: string;
  lead_id: string;
  message_id: string;
  thread_id: string;
  subject: string;
  body: string;
  bounce_reason: string;
  timestamp: string;
  raw: Record<string, unknown>;
}

function pick(payload: Record<string, unknown>, keys: string[]): string {
  for (const k of keys) {
    const v = payload[k];
    if (typeof v === "string" && v) return v;
    if (typeof v === "number") return String(v);
  }
  return "";
}

function normalizePayload(payload: Record<string, unknown>): NormalizedEvent {
  let email = pick(payload, ["email", "lead_email", "prospect_email", "to_email", "to"]);
  if (email.includes("@") === false && Array.isArray(payload.to)) {
    email = String((payload.to as unknown[])[0] || "");
  }
  // Nested guide shape (api.smartlead.ai/core/webhooks): fields live inside
  // `lead` and `reply` objects. Fall back to them when the flat keys miss.
  const lead = jsonOrRaw(payload.lead);
  const reply = jsonOrRaw(payload.reply);
  if (email.includes("@") === false && typeof lead.email === "string") {
    email = lead.email;
  }
  return {
    event_type: pick(payload, ["event_type", "event", "type"]).toLowerCase(),
    email,
    first_name: pick(payload, ["first_name", "firstName"]) ||
      (typeof lead.first_name === "string" ? lead.first_name : ""),
    last_name: pick(payload, ["last_name", "lastName"]) ||
      (typeof lead.last_name === "string" ? lead.last_name : ""),
    company_name: pick(payload, ["company_name", "companyName"]) ||
      (typeof lead.company_name === "string" ? lead.company_name : ""),
    campaign_id: pick(payload, ["campaign_id", "campaignId"]),
    campaign_name: pick(payload, ["campaign_name", "campaignName"]),
    lead_id: pick(payload, ["lead_id", "leadId"]),
    message_id: pick(payload, ["message_id", "messageId"]) ||
      (typeof reply.message_id === "string" ? reply.message_id : ""),
    thread_id: pick(payload, ["thread_id", "threadId"]),
    subject: pick(payload, ["subject", "email_subject", "reply_subject"]) ||
      (typeof reply.subject === "string" ? reply.subject : ""),
    body: pick(payload, ["reply_body", "body", "email_body", "message", "preview_text"]) ||
      (typeof reply.body === "string" ? reply.body : ""),
    bounce_reason: pick(payload, ["bounce_reason", "bounceReason"]),
    timestamp: pick(payload, ["timestamp", "created_at", "createdAt", "time_replied", "time_sent", "time_opened", "time_clicked"]),
    raw: payload,
  };
}

// ─── Classifier v0 (spec §4.3 — keyword rules, fail toward positive) ───

const POSITIVE_PATTERNS = [
  /\binterested\b/i,
  /\bcall\b/i,
  /\bpricing\b/i,
  /\bhow much\b/i,
  /\bquote\b/i,
  /\bschedule\b/i,
  /\bcalendar\b/i,
  /\bbook\b/i,
  /\bworks for us\b/i,
  /\bsend over\b/i,
  /\bsend me\b/i,
  /\bmore info/i,
  /\bte?ll me more\b/i,
  /\byes\b/i,
  /\bsure\b/i,
  /\blet'?s talk\b/i,
  /\blet'?s do\b/i,
];

const NEGATIVE_PATTERNS = [
  /\bremove\b/i,
  /\bunsubscribe\b/i,
  /\bstop emailing\b/i,
  /\bstop sending\b/i,
  /\bdo not email\b/i,
  /\bnot interested\b/i,
  /\bno thanks\b/i,
  /\bno thank you\b/i,
  /\bunsubscribe me\b/i,
  /\btake me off\b/i,
  /\bopt[- ]?out\b/i,
  /\bdo not contact\b/i,
  /\bdnc\b/i,
];

export type ReplyClass = "positive" | "negative" | "neutral";

export function classifyReply(body: string): ReplyClass {
  const text = (body || "").toLowerCase();
  if (!text.trim()) return "neutral"; // empty → fail toward positive downstream
  for (const p of NEGATIVE_PATTERNS) {
    if (p.test(text)) return "negative";
  }
  for (const p of POSITIVE_PATTERNS) {
    if (p.test(text)) return "positive";
  }
  return "neutral";
}

// ─── Event → activity mapping ───

const SUPPORTED_EVENTS = new Set([
  "email_replied",
  "email_reply", // current documented event name (api.smartlead.ai events reference)
  "email_bounced",
  "lead_hot",
  "email_opened",
  "email_open", // current documented event name
  "email_clicked",
  "email_link_click", // current documented event name
]);

function mapActivity(ev: NormalizedEvent): string {
  // Normalize the two documented reply spellings to one activity type…
  const isReply = ev.event_type === "email_replied" || ev.event_type === "email_reply";
  if (isReply) {
    const cls = classifyReply(ev.body);
    // Spec §4.7: positive | neutral → email_replied (fail toward attention);
    // negative → email_replied_negative (copy-library signal, still logged).
    return cls === "negative" ? "email_replied_negative" : "email_replied";
  }
  // …and the open/click spellings to their funnel activity types.
  if (ev.event_type === "email_open") return "email_opened";
  if (ev.event_type === "email_link_click") return "email_clicked";
  return ev.event_type; // email_bounced | lead_hot | email_opened | email_clicked
}

// ─── Dedupe key (external_id) ───

async function sha256short(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(digest).slice(0, 8))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function buildExternalId(ev: NormalizedEvent): Promise<string> {
  // Priority: provider message id → stable content hash → whole-payload hash.
  if (ev.message_id) return `sl_${ev.event_type}_${ev.message_id}`;
  const basis = [ev.lead_id, ev.thread_id, ev.timestamp, ev.subject, ev.body]
    .join("|");
  if (basis.replace(/\|/g, "")) {
    return `sl_${ev.event_type}_${await sha256short(basis)}`;
  }
  return `sl_${ev.event_type}_${await sha256short(JSON.stringify(ev.raw))}`;
}

// ─── Idempotency ledger (sys_processed_webhooks — table EXISTS in live DB) ───

async function isProcessed(eventId: string): Promise<boolean> {
  const { data } = await supabase
    .from("sys_processed_webhooks")
    .select("event_id")
    .eq("event_id", eventId)
    .limit(1);
  return !!(data && data.length > 0);
}

async function markProcessed(eventId: string, eventType: string): Promise<void> {
  await supabase.from("sys_processed_webhooks").insert({
    event_id: eventId,
    source: "smartlead",
    event_type: eventType,
  });
}

// ─── Raw-payload audit (sys_webhook_events — staged migration; degrade if absent) ───

async function auditRawEvent(
  ev: NormalizedEvent,
  dedupeKey: string,
): Promise<string | null> {
  const { data, error } = await supabase
    .from("sys_webhook_events")
    .insert({
      source: "smartlead",
      event_type: ev.event_type,
      payload: ev.raw,
      dedupe_key: dedupeKey,
      status: "received",
    })
    .select("id")
    .single();
  if (error) {
    // Degrade gracefully — CRM write still proceeds. Coverage reconcile must
    // treat "audit unavailable" as a deploy gap (migration not yet run).
    console.error(`audit insert failed (migration run?): ${error.message}`);
    return null;
  }
  return data?.id ?? null;
}

async function updateAuditRow(
  auditId: string | null,
  patch: Record<string, unknown>,
): Promise<void> {
  if (!auditId) return;
  await supabase.from("sys_webhook_events").update(patch).eq("id", auditId);
}

// ─── CRM touchpoints (READ-ONLY lookup; writes to crm_activities only) ───

async function findContactByEmail(email: string) {
  if (!email) return null;
  const { data, error } = await supabase
    .from("crm_contacts")
    .select("id, company_id")
    .eq("email", email)
    .limit(1);
  if (error || !data || data.length === 0) return null;
  return data[0];
}

async function findSystemCompany(): Promise<string | null> {
  const { data, error } = await supabase
    .from("crm_companies")
    .select("id")
    .eq("normalized_name", "mafsystem")
    .is("deleted_at", null)
    .limit(1);
  if (error || !data || data.length === 0) return null;
  return data[0].id;
}

function jsonOrRaw(v: unknown): Record<string, unknown> {
  if (typeof v === "string") {
    try {
      return JSON.parse(v);
    } catch {
      return { raw: v };
    }
  }
  return (v as Record<string, unknown>) || {};
}

// ─── Handler ───

Deno.serve({ port: Number(Deno.env.get("PORT")) || 8000 }, async (req: Request) => {
  const url = new URL(req.url);

  if (req.method === "GET") {
    if (url.pathname.endsWith("/health")) {
      return new Response(JSON.stringify({ status: "ok" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Shared secret (header x-webhook-secret OR ?secret= — Smartlead can't set
  // custom headers, so the query param is the deploy-ready path).
  // FAIL CLOSED (2026-09-04 review): a missing SMARTLEAD_WEBHOOK_SECRET used to
  // skip verification entirely — any anonymous POST could reach CRM writes. A
  // redeploy without the secret must degrade to refusing traffic, not to
  // accept-everything. 500 (not 401) so the misconfig is visible in logs.
  if (!WEBHOOK_SECRET) {
    console.error("smartlead-webhook: SMARTLEAD_WEBHOOK_SECRET is not set — refusing to serve (fail-closed)");
    return new Response(
      JSON.stringify({ error: "receiver misconfigured: missing SMARTLEAD_WEBHOOK_SECRET" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
  const authHeader = req.headers.get("x-webhook-secret") || "";
  const querySecret = url.searchParams.get("secret") || "";
  if (authHeader !== WEBHOOK_SECRET && querySecret !== WEBHOOK_SECRET) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  let payload: Record<string, unknown>;
  try {
    payload = (await req.json()) as Record<string, unknown>;
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const ev = normalizePayload(payload);
  const response: Record<string, unknown> = { ok: true, event: ev.event_type };

  if (!ev.event_type) {
    response.ok = false;
    response.error = "missing event_type";
    return new Response(JSON.stringify(response), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Unsupported events: STILL AUDITED (2026-09-04 review — this path used to
  // return without an audit row, so a real payload-shape mismatch would vanish
  // exactly like the pre-PR silent-loss bug). Smartlead only receives 200s on
  // this endpoint — coverage lives in the audit ledger.
  if (!SUPPORTED_EVENTS.has(ev.event_type)) {
    console.log(`smartlead-webhook: unsupported event '${ev.event_type}' — acked + audited`);
    const extId = await buildExternalId(ev);
    const auditId = await auditRawEvent(ev, `unsupported:${extId}`);
    response.skipped = "unsupported_event";
    response.audited = auditId !== null;
    return new Response(JSON.stringify(response), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const activityType = mapActivity(ev);
  const externalId = await buildExternalId(ev);
  const dedupeKey = `${activityType}:${externalId}`;
  response.external_id = externalId;
  response.activity_type = activityType;

  // Raw-payload audit BEFORE dedupe (spec §4.2 order).
  const auditId = await auditRawEvent(ev, dedupeKey);
  response.audited = auditId !== null;

  // Dedupe BEFORE any write/notify (spec failure mode 7).
  if (await isProcessed(dedupeKey)) {
    response.deduped = true;
    await updateAuditRow(auditId, { status: "deduped" });
    return new Response(JSON.stringify(response), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Read-only contact lookup; fallbacks keep the chk_activity_has_link
  // constraint satisfied WITHOUT creating anything:
  //   1. contact by email
  //   2. company by normalized payload name (ilike, not deleted)
  //   3. MAF System company (not deleted) — anchor of last resort
  const contact = await findContactByEmail(ev.email);
  let company_id: string | null = contact?.company_id ?? null;
  let contact_id: string | null = contact?.id ?? null;
  if (!contact_id && !company_id && ev.company_name) {
    const { data: byName } = await supabase
      .from("crm_companies")
      .select("id")
      .ilike("company_name", ev.company_name)
      .is("deleted_at", null)
      .limit(1);
    if (byName && byName.length > 0) company_id = byName[0].id;
  }
  if (!contact_id && !company_id) {
    company_id = await findSystemCompany();
  }

  if (!contact_id && !company_id) {
    // No link possible AND no system fallback — flag loudly, never silently ok.
    console.error("smartlead-webhook: no contact AND no MAF System company — activity skipped");
    response.skipped = "no_link";
    await updateAuditRow(auditId, { status: "skipped", error: "no_contact_and_no_system_company" });
    await markProcessed(dedupeKey, ev.event_type);
    return new Response(JSON.stringify(response), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const insertBody: Record<string, unknown> = {
    activity_type: activityType,
    channel: "smartlead",
    direction: ev.event_type === "email_replied" ? "inbound" : "outbound",
    subject: ev.subject || `Smartlead: ${ev.event_type}`,
    body: ev.body || ev.bounce_reason || "",
    external_id: externalId,
    thread_id: ev.thread_id || null,
    meta: {
      campaign: ev.campaign_name || null,
      campaign_id: ev.campaign_id || null,
      lead_id: ev.lead_id || null,
      message_id: ev.message_id || null,
      event: ev.event_type,
      classification:
        ev.event_type === "email_replied"
          ? classifyReply(ev.body)
          : null,
    },
    occurred_at: ev.timestamp && !Number.isNaN(Date.parse(ev.timestamp))
      ? new Date(ev.timestamp).toISOString()
      : new Date().toISOString(),
  };
  if (contact_id) insertBody.contact_id = contact_id;
  if (company_id) insertBody.company_id = company_id;

  const { data: inserted, error: insertErr } = await supabase
    .from("crm_activities")
    .insert(insertBody)
    .select("id")
    .single();

  if (insertErr) {
    // 23505 = unique external dedupe index fired — a race duplicate, fine.
    if (insertErr.code === "23505") {
      response.deduped = true;
      await updateAuditRow(auditId, { status: "deduped" });
      return new Response(JSON.stringify(response), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
    console.error(`smartlead-webhook: activity insert failed: ${insertErr.message}`);
    response.ok = false;
    response.error = `activity_insert_failed: ${insertErr.message}`;
    await updateAuditRow(auditId, { status: "error", error: insertErr.message });
    // Do NOT mark processed — a retry may succeed once the fault is fixed.
    return new Response(JSON.stringify(response), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  await markProcessed(dedupeKey, ev.event_type);
  response.created = true;
  response.activity_id = inserted?.id ?? null;
  response.contact_linked = contact_id !== null;
  await updateAuditRow(auditId, { status: "logged", activity_id: inserted?.id ?? null });

  // P3 (hours gate + box-side Discord notifier) subscribes to these audit rows /
  // crm_activities — nothing outbound happens here, by design.
  return new Response(JSON.stringify(response), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});