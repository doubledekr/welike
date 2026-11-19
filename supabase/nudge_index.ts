import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

// Sends a push notification to the other person in the couple, and keeps a copy in their in-app inbox so someone
// without notifications (or who swiped one away) can still find it.
// Auth: the couple code in the body must match a couple.
// "kind" marks an automatic reminder (cards, event, invite, share, plan). Those are capped per person per day,
// with the "today's cards" reminder giving way first. A message with no kind was sent by a person and always goes.
// Extras (daily cards, invite and share reminders, community sends) are not pushed to someone who chose
// "just the essentials"; they still land in the in-app inbox.
// "tag" (optional) lets a series replace itself on the lock screen, like trivia buzzes; "ttl" (30 to 3600 s) drops a push that would arrive stale.
// "round" ties a message to one swipe round: every message for that round shares a tag, so a newer one replaces
// the older one on the lock screen instead of stacking. "quiet" files it in the inbox without a push, for when
// the other person is already looking at the app.
// Plans: a message about a plan (a "plan" id, or a ./?plan= link) shares one tag per plan and replaces that plan's
// unread inbox note instead of stacking. "need": "answer" means it asks the person to answer the plan: it is dropped
// if they already have, or the plan is past or called off. "hold" (seconds) waits before pushing, so several edits in
// a row arrive as one push. Late at night, a plan that isn't for today or tomorrow waits until 9am. Waiting pushes
// sit in push_later and are sent by _push_later_tick with "queued", which checks again before sending.
// Each person gets it once per kind of device (iPhone, Mac, ...): on the one of that kind they opened most recently.
// All those devices are sent to at the same time, each with its own time limit, so one slow or dead device can't
// hold up the rest. Every copy carries the same tag, so if two still land on one device the second replaces the first.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const AUTO = new Set(["cards", "event", "invite", "share", "plan"]);
const EXTRA = new Set(["cards", "invite", "share", "extra"]);
const NO_INBOX = new Set(["cards", "invite"]);   // pure reminders: the app shows these itself while they apply
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const host = (e: string) => { try { return new URL(e).host; } catch { return "?"; } };

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { code, member, title, body, url, kind, round, quiet, plan, need, hold, to, noinbox, queued, tag: tagIn, ttl } = await req.json();
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const C = String(code ?? "").trim().toUpperCase();
    const { data: couple } = await sb.from("couples").select("id").eq("code", C).maybeSingle();
    if (!couple) return json({ error: "bad_code" }, 403);
    const T = String(title ?? "Let’s Together").slice(0, 80), B = String(body ?? "").slice(0, 180), U = String(url ?? "./").slice(0, 200), K = String(kind ?? "");
    const R = /^[0-9a-f-]{8,40}$/i.test(String(round ?? "")) ? String(round) : "";
    const P = UUID.test(String(plan ?? "")) ? String(plan) : (U.match(/[?&]plan=([0-9a-f-]{36})/i)?.[1] ?? "");
    const N = need === "answer" ? "answer" : "";
    const H = queued === true ? 0 : Math.min(Math.max(Number(hold) || 0, 0), 600);
    const { data: ms } = await sb.from("members").select("name,notif").eq("couple_id", couple.id).neq("name", String(member ?? ""));
    let others = (ms ?? []) as any[];
    if (to) others = others.filter((m) => m.name === String(to));
    // A plan message someone has to act on: still relevant, and now or later?
    const later = new Map<string, string>();
    let dropped = 0;
    if (P && (N || H)) {
      const keep: any[] = [];
      for (const m of others) {
        const { data: g, error } = await sb.rpc("push_plan_gate", { p_couple: couple.id, p_member: m.name, p_plan: P, p_need: N || null });
        if (!error && g && g.go === false) { dropped++; continue; }
        const due = Math.max(g?.later ? Date.parse(g.later) : 0, H ? Date.now() + H * 1000 : 0);
        if (due > Date.now() + 5000) later.set(m.name, new Date(due).toISOString());
        keep.push(m);
      }
      others = keep;
    }
    if (!NO_INBOX.has(K) && noinbox !== true && others.length) {
      if (P) await sb.from("inbox").delete().eq("couple_id", couple.id).in("member", others.map((m) => m.name)).is("seen_at", null).like("url", `./?plan=${P}%`);
      await sb.from("inbox").insert(others.map((m) => ({ couple_id: couple.id, member: m.name, title: T, body: B, url: U, kind: K || null })));
    }
    if (later.size) {
      await sb.from("push_later").upsert([...later].map(([m, due]) => ({ plan: P, member: m, couple_id: couple.id, code: C, sender: String(member ?? ""),
        title: T, body: B, url: U, need: N || null, due_at: due })));
      others = others.filter((m) => !later.has(m.name));
    } else if (P && !queued && others.length) {
      // sent now: anything still waiting for this plan is out of date
      await sb.from("push_later").delete().eq("plan", P).in("member", others.map((m) => m.name));
    }
    if (quiet === true || !others.length) return json({ sent: 0, quiet: quiet === true, held_later: later.size, dropped });
    const names = new Set(others.map((m) => m.name));
    const essentials = new Set(others.filter((m) => m.notif === "essentials").map((m) => m.name));
    const { data: secs } = await sb.from("app_secrets").select("key,value").in("key", ["vapid_public", "vapid_private"]);
    const S: Record<string, string> = Object.fromEntries((secs ?? []).map((r: any) => [r.key, r.value]));
    webpush.setVapidDetails("https://doubledekr.github.io/welike/", S.vapid_public, S.vapid_private);
    const { data: subs } = await sb.from("push_subs").select("id,sub,member,endpoint,kind,last_seen").eq("couple_id", couple.id).neq("member", String(member ?? ""))
      .order("last_seen", { ascending: false, nullsFirst: false });
    const all = ((subs ?? []) as any[]).filter((s) => names.has(s.member));
    // newest device of each kind, per person (older ones of a kind are skipped, not deleted)
    const seen = new Set<string>();
    let muted = 0;
    const list = all.filter((s) => { const g = s.member + "|" + (s.kind || host(s.endpoint)); if (seen.has(g)) return false; seen.add(g); return true; })
      .filter((s) => { if (EXTRA.has(K) && essentials.has(s.member)) { muted++; return false; } return true; });
    let held = 0;
    const allow = new Map<string, boolean>();
    if (AUTO.has(K)) {
      for (const m of new Set(list.map((s) => s.member))) {
        const { data: ok, error } = await sb.rpc("push_allow", { p_couple: couple.id, p_member: m, p_kind: K });
        allow.set(m, error ? true : ok !== false);   // if the count cannot be checked, send rather than lose it
      }
    }
    const go = list.filter((s) => { if (allow.size && !allow.get(s.member)) { held++; return false; } return true; });
    const TG = /^[a-z0-9-]{3,60}$/i.test(String(tagIn ?? "")) ? String(tagIn) : "";
    const tag = R ? "r-" + R : P ? "p-" + P : TG || crypto.randomUUID();
    const payload = JSON.stringify({ title: T, body: B, url: U, tag, ...(R ? { round: R } : {}) });
    const res = await Promise.allSettled(go.map((s) => webpush.sendNotification(s.sub, payload, { TTL: Math.min(Math.max(Number(ttl) || 3600, 30), 3600), timeout: 8000 })));
    let sent = 0, failed = 0;
    const gone: string[] = [];
    res.forEach((r, i) => {
      if (r.status === "fulfilled") sent++;
      else { failed++; const sc = (r.reason as any)?.statusCode; if (sc === 404 || sc === 410) gone.push(go[i].id); }
    });
    if (gone.length) await sb.from("push_subs").delete().in("id", gone);   // the browser says this device is gone for good
    return json({ sent, held, muted, failed, removed: gone.length, devices: all.length, used: list.length, held_later: later.size, dropped });
  } catch (e) {
    return json({ error: String(e) }, 400);
  }
});
