// Sends a Web Push when a swap request is created or decided.
//
// Triggered by a Database Webhook on public.swap_requests. The webhook body
// is Supabase's standard shape: { type, table, record, old_record }.
//
// Who gets told:
//   INSERT                      -> the listing owner ("someone wants your bay")
//   UPDATE to confirmed/declined-> the requester ("your request was decided")
//
// Secrets to set on the project (Edge Functions -> Secrets):
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:swapspot.uk@gmail.com)
//   PUSH_WEBHOOK_SECRET (optional but recommended, see below)
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "jsr:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:swapspot.uk@gmail.com";
const WEBHOOK_SECRET = Deno.env.get("PUSH_WEBHOOK_SECRET") ?? "";

// Service role: this function reads other members' subscriptions on purpose,
// which RLS would otherwise prevent. It is never exposed to the browser.
const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

if (VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY) {
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
}

type Body = {
  type: "INSERT" | "UPDATE" | "DELETE";
  record?: Record<string, unknown> | null;
  old_record?: Record<string, unknown> | null;
};

function messageFor(body: Body): { userKey: "owner" | "requester"; title: string; text: string } | null {
  const rec = body.record ?? {};
  const prev = body.old_record ?? {};
  const status = rec.status as string | undefined;

  if (body.type === "INSERT") {
    return {
      userKey: "owner",
      title: "New swap request",
      text: "Someone wants to borrow one of your bays.",
    };
  }
  // only speak when the status actually moved, or an unrelated column edit
  // would re-notify everyone
  if (body.type === "UPDATE" && status && status !== prev.status) {
    if (status === "confirmed") {
      return {
        userKey: "requester",
        title: "Swap approved",
        text: `Your bay is booked. ${rec.cost_credits ?? 0} credits charged.`,
      };
    }
    if (status === "declined") {
      return {
        userKey: "requester",
        title: "Swap declined",
        text: "No credits were charged.",
      };
    }
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  // A database webhook can send a custom header. Without this check the
  // endpoint is public and anyone could make it fan out notifications.
  if (WEBHOOK_SECRET && req.headers.get("x-webhook-secret") !== WEBHOOK_SECRET) {
    return new Response("Unauthorised", { status: 401 });
  }
  if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) {
    return new Response("VAPID keys not configured", { status: 500 });
  }

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return new Response("Bad request", { status: 400 });
  }

  const msg = messageFor(body);
  if (!msg) return Response.json({ sent: 0, reason: "nothing worth notifying" });

  const rec = body.record ?? {};
  let targetUserId: string | null = null;

  if (msg.userKey === "requester") {
    targetUserId = (rec.requester_id as string) ?? null;
  } else {
    const { data: listing } = await admin
      .from("listings")
      .select("owner_id")
      .eq("id", rec.listing_id as string)
      .maybeSingle();
    targetUserId = listing?.owner_id ?? null;
    // never ping someone about their own request on their own bay
    if (targetUserId && targetUserId === rec.requester_id) targetUserId = null;
  }
  if (!targetUserId) return Response.json({ sent: 0, reason: "no recipient" });

  const { data: subs } = await admin
    .from("push_subscriptions")
    .select("endpoint, p256dh, auth")
    .eq("user_id", targetUserId);

  if (!subs || subs.length === 0) return Response.json({ sent: 0, reason: "no subscriptions" });

  const payload = JSON.stringify({
    title: msg.title,
    body: msg.text,
    tag: `swap-${rec.id ?? "x"}`,
    url: "./",
  });

  let sent = 0;
  const dead: string[] = [];
  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        payload,
      );
      sent++;
    } catch (err) {
      // 404/410 mean the browser threw the subscription away: clear it out or
      // dead endpoints accumulate forever
      const code = (err as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) dead.push(s.endpoint);
      else console.error("push failed", code, String(err));
    }
  }));

  if (dead.length) {
    await admin.from("push_subscriptions").delete().in("endpoint", dead);
  }
  return Response.json({ sent, pruned: dead.length });
});
