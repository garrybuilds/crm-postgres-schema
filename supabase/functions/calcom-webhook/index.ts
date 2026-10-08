// supabase/functions/calcom-webhook/index.ts
// Cal.com webhook receiver — fires when a booking is created, cancelled, or completed.
// Receives Cal.com webhook payload, maps to CRM activity types, writes to crm_activities.
//
// Deploy: supabase functions deploy calcom-webhook --project-ref <your-project-ref>
// Cal.com webhook URL: https://<your-project-ref>.functions.supabase.co/calcom-webhook
//
// Cal.com webhook events we handle:
//   - BOOKING_CREATED   → call_booked
//   - BOOKING_CANCELLED → call_no_show
//   - BOOKING_COMPLETED → call_held (when meeting actually ends)
//
// Security: Cal.com webhook signatures can be verified via the
// Cal.com webhook signing secret. We check for a shared secret in the
// WEBHOOK_SECRET env var as a simpler first-line defense.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("CALCOM_WEBHOOK_SECRET") || "";

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

interface CalComAttendee {
  email: string;
  name?: string;
  timeZone?: string;
}

interface CalComBooking {
  id: string;
  uid?: string;
  status: string;
  title?: string;
  startTime?: string;
  endTime?: string;
  createdAt?: string;
  attendees?: CalComAttendee[];
  metadata?: Record<string, unknown>;
  user?: { email?: string; name?: string };
}

interface CalComWebhookPayload {
  triggerEvent: string; // BOOKING_CREATED, BOOKING_CANCELLED, BOOKING_COMPLETED, etc.
  createdAt: string;
  payload: CalComBooking;
  // Some Cal.com webhook versions nest differently
  booking?: CalComBooking;
  type?: string;
}

function mapEventType(triggerEvent: string, booking: CalComBooking): string {
  const event = triggerEvent || "";
  if (event === "BOOKING_CREATED" || event === "booking.created") return "call_booked";
  if (event === "BOOKING_CANCELLED" || event === "booking.cancelled") return "call_no_show";
  if (event === "BOOKING_COMPLETED" || event === "booking.completed") return "call_held";
  // Fallback: infer from booking status
  if (booking.status === "cancelled") return "call_no_show";
  if (booking.endTime) return "call_held";
  return "call_booked";
}

function getAttendeeEmail(payload: CalComWebhookPayload): string {
  const booking = payload.payload || payload.booking;
  if (!booking) return "";
  const attendees = booking.attendees || [];
  if (attendees.length > 0 && attendees[0].email) {
    return attendees[0].email;
  }
  // Some payloads put email in metadata
  const meta = booking.metadata as Record<string, unknown> | undefined;
  if (meta && typeof meta.email === "string") return meta.email;
  return "";
}

function getBooking(payload: CalComWebhookPayload): CalComBooking {
  return payload.payload || payload.booking || (payload as unknown as CalComBooking);
}

async function findDealByEmail(email: string) {
  // Find contact by email
  const { data: contacts, error: contactErr } = await supabase
    .from("crm_contacts")
    .select("id, company_id")
    .eq("email", email)
    .limit(1);

  if (contactErr || !contacts || contacts.length === 0) return null;

  const contact = contacts[0];

  // Find open deal for this contact
  const { data: deals, error: dealErr } = await supabase
    .from("crm_deals")
    .select("id, company_id, stage, contact_id")
    .eq("contact_id", contact.id)
    .not("stage", "in", "(closed_won,closed_lost)")
    .order("created_at", { ascending: false })
    .limit(1);

  if (dealErr || !deals || deals.length === 0) return null;

  return deals[0];
}

async function checkExistingActivity(externalId: string): Promise<boolean> {
  const { data, error } = await supabase
    .from("crm_activities")
    .select("id")
    .eq("external_id", externalId)
    .limit(1);

  if (error) return false;
  return !!(data && data.length > 0);
}

async function logActivity(
  booking: CalComBooking,
  deal: { id: string; company_id: string | null; stage: string },
  activityType: string,
  triggerEvent: string,
) {
  const extId = `calcom_booking_${booking.id}`;
  if (await checkExistingActivity(extId)) {
    return { deduped: true, created: false };
  }

  const { error } = await supabase.from("crm_activities").insert({
    deal_id: deal.id,
    company_id: deal.company_id,
    activity_type: activityType,
    channel: "cal_com",
    direction: "inbound",
    subject: `Cal.com booking: ${booking.title || "Growth Blocker Analysis"}`,
    body: `Status: ${booking.status}. Start: ${booking.startTime || "N/A"}. Event: ${triggerEvent}`,
    external_id: extId,
    meta: {
      booking_id: booking.id,
      status: booking.status,
      trigger_event: triggerEvent,
    },
    occurred_at: booking.startTime || new Date().toISOString(),
  });

  if (error) {
    console.error("Failed to insert activity:", error.message);
    return { deduped: false, created: false, error: error.message };
  }

  return { deduped: false, created: true };
}

async function updateDealStage(
  dealId: string,
  currentStage: string,
  activityType: string,
) {
  let newStage: string | null = null;

  if (activityType === "call_booked" && currentStage === "contacted") {
    newStage = "discovery_booked";
  } else if (activityType === "call_held" && currentStage === "discovery_booked") {
    newStage = "discovery_completed";
  }

  if (!newStage) return;

  const { error } = await supabase
    .from("crm_deals")
    .update({ stage: newStage, stage_entered_at: new Date().toISOString() })
    .eq("id", dealId);

  if (error) {
    // Fail loudly (throw → 500 from the handler) so Cal.com retries the
    // webhook; swallowing the error meant the booking was recorded but the
    // stage never advanced, with no retry.
    console.error(`Failed to update deal stage: ${error.message}`);
    throw new Error(`failed to update deal stage for deal ${dealId}: ${error.message}`);
  } else {
    console.log(`Deal ${dealId} stage: ${currentStage} → ${newStage}`);
  }
}

Deno.serve(async (req: Request) => {
  // Only accept POST
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Shared secret (header x-webhook-secret OR ?secret= — Cal.com can set
  // custom headers; the query param is kept for parity with prior deploys).
  // FAIL CLOSED: a missing CALCOM_WEBHOOK_SECRET used to skip verification
  // entirely — any anonymous POST could reach CRM writes. A redeploy without
  // the secret must degrade to refusing traffic, not to accept-everything.
  // 500 (not 401) so the misconfig is visible in logs.
  if (!WEBHOOK_SECRET) {
    console.error("calcom-webhook: CALCOM_WEBHOOK_SECRET is not set — refusing to serve (fail-closed)");
    return new Response(
      JSON.stringify({ error: "receiver misconfigured: missing CALCOM_WEBHOOK_SECRET" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
  const authHeader = req.headers.get("x-webhook-secret") || "";
  const url = new URL(req.url);
  const querySecret = url.searchParams.get("secret") || "";
  // TODO(constant-time): compare secrets with a constant-time helper instead
  // of !==; smartlead-webhook convention uses ===, matching it here.
  if (authHeader !== WEBHOOK_SECRET && querySecret !== WEBHOOK_SECRET) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  let payload: CalComWebhookPayload;
  try {
    payload = await req.json();
  } catch (e) {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const triggerEvent = payload.triggerEvent || payload.type || "unknown";
  const booking = getBooking(payload);
  const attendeeEmail = getAttendeeEmail(payload);

  console.log(`Cal.com webhook: ${triggerEvent} — booking ${booking.id} — ${attendeeEmail}`);

  if (!attendeeEmail) {
    return new Response(JSON.stringify({ ok: true, skipped: "no attendee email" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Find matching deal
  const deal = await findDealByEmail(attendeeEmail);
  if (!deal) {
    console.log(`No matching CRM deal for ${attendeeEmail}`);
    return new Response(JSON.stringify({ ok: true, skipped: "no matching deal" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Map event to activity type
  const activityType = mapEventType(triggerEvent, booking);

  // Log the activity
  const result = await logActivity(booking, deal, activityType, triggerEvent);

  // Re-attempt the stage transition on BOTH the created and deduped paths.
  // If a prior attempt inserted the activity and then 500'd inside
  // updateDealStage, Cal.com retries the webhook; the retry dedupes the
  // insert (result.created === false) but must still advance the stage —
  // otherwise the handler returns 200 "deduped" and the stage never heals.
  // Safe to re-run: updateDealStage is forward-only and stage-condition-gated
  // (no transition for the activity type, or stage already past the gate →
  // no-op), so it is idempotent.
  await updateDealStage(deal.id, deal.stage, activityType);

  return new Response(
    JSON.stringify({
      ok: true,
      booking_id: booking.id,
      activity_type: activityType,
      deal_id: deal.id,
      ...result,
    }),
    {
      status: 200,
      headers: { "Content-Type": "application/json" },
    },
  );
});