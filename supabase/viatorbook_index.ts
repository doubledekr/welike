// Viator bookings back into Let's Together plans (beta, Dave 20 Nov).
// Reads Viator's booking report (/bookings/modified-since, open to basic-access affiliates) from where it left off,
// and hands each event to _viator_apply. Only bookings carrying one of our per-person tags ("campaign value") are used;
// they go into that person's own trip or group trip. Nothing is pushed to anyone.
// Viator gives the travel date but not always the time: when the product has a single start time, we fill it in.
// Auth: x-sync-key (cron). Body: { fake?: event } lets a test event through the same path.
import { createClient } from "npm:@supabase/supabase-js@2";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });
async function secret(k: string) { const { data } = await db.from("app_secrets").select("value").eq("key", k).maybeSingle(); return data?.value as string | undefined; }
const H = (key: string) => ({ "exp-api-key": key, "Accept": "application/json;version=2.0", "Accept-Language": "en-US" });

async function oneStart(key: string, code: string): Promise<string | null> {
  try {
    const r = await fetch(`https://api.viator.com/partner/availability/schedules/${encodeURIComponent(code)}`, { headers: H(key) });
    if (!r.ok) return null;
    const j = await r.json(), starts = new Set<string>();
    for (const bi of j?.bookableItems || []) for (const s of bi?.seasons || []) for (const pr of s?.pricingRecords || []) for (const t of pr?.timedEntries || []) if (t?.startTime) starts.add(String(t.startTime).slice(0, 5));
    return starts.size === 1 ? [...starts][0] : null;
  } catch { return null; }
}
// Events may arrive flat or with the booking nested; pull out the fields _viator_apply reads.
function flat(e: any) {
  const b = e?.booking || e || {};
  return { transactionRef: e?.transactionRef ?? b?.transactionRef ?? b?.bookingRef ?? e?.bookingRef, eventType: e?.eventType ?? b?.eventType, productCode: e?.productCode ?? b?.productCode,
    travelDate: e?.travelDate ?? b?.travelDate, travelTime: e?.travelTime ?? b?.travelTime ?? b?.startTime, campaignValue: e?.campaignValue ?? b?.campaignValue,
    totalPrice: e?.totalPrice ?? b?.totalPrice?.price ?? b?.totalPrice, currency: e?.currency ?? b?.currency, lastUpdated: e?.lastUpdated };
}
async function apply(key: string, ev: any) {
  const f: any = flat(ev);
  if (!f.campaignValue) return "untagged";
  const { data: ours } = await db.from("viator_tags").select("tag").eq("tag", f.campaignValue).maybeSingle();
  if (!ours) return "not_ours";
  if (!f.travelTime && f.productCode && !/CANCEL|REJECT/i.test(String(f.eventType))) { const t = await oneStart(key, f.productCode); if (t) f.travelTime = t; }
  const { data, error } = await db.rpc("_viator_apply", { e: f });
  return error ? "err " + error.message.slice(0, 80) : data;
}

Deno.serve(async (req) => {
  try {
    if (req.headers.get("x-sync-key") !== await secret("sync_key")) return json({ error: "forbidden" }, 403);
    const key = await secret("viator_key"); if (!key) return json({ ok: false, error: "no_key" });
    const b = await req.json().catch(() => ({}));
    if (b.fake) return json({ ok: true, result: await apply(key, b.fake) });
    const { data: st } = await db.from("viator_sync").select("cursor").eq("id", 1).maybeSingle();
    let cursor = st?.cursor as string | undefined, pages = 0, seen = 0; const out: Record<string, number> = {}; let note = "";
    while (pages < 20) {
      const url = new URL("https://api.viator.com/partner/bookings/modified-since"); if (cursor) url.searchParams.set("cursor", cursor);
      const r = await fetch(url, { headers: H(key) });
      if (!r.ok) { note = "viator " + r.status + " " + (await r.text()).slice(0, 160); break; }
      const j = await r.json();
      const list = (j?.bookings || j?.events || j?.bookingEvents || j?.data || []) as any[];
      if (!pages && !list.length) note = "keys " + Object.keys(j || {}).join(",");
      for (const ev of list) { const res = String(await apply(key, ev)); out[res] = (out[res] || 0) + 1; seen++; }
      const next = j?.nextCursor || j?.cursor; pages++;
      if (!next || next === cursor || !list.length) { if (next) cursor = next; break; }
      cursor = next;
    }
    await db.from("viator_sync").upsert({ id: 1, cursor: cursor ?? null, at: new Date().toISOString(), note: (note || JSON.stringify(out)).slice(0, 300) });
    return json({ ok: true, pages, seen, out, note: note || undefined });
  } catch (e) { return json({ ok: false, error: String((e as Error).message || e) }); }
});
