// SerpApi pulls (Dave, 20 Nov). Backend only (sync key). One call = one SerpApi search, saved to serp_pulls with a tidy
// item list next to the raw answer. Nothing is shown in the app from here until Dave says to publish.
// Body: { engine: "google_events" | "tripadvisor" | "google_local", q, area?, purpose?, ssrc?, location? }
import { createClient } from "npm:@supabase/supabase-js@2";
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "Content-Type": "application/json" } });
const VIRTUAL = /\b(virtual|online|webinar|zoom|livestream|live stream)\b/i;

function tidy(engine: string, j: any) {
  if (engine === "google_events") return (j.events_results || []).map((e: any) => ({
    title: e.title, type: e.type || null, when: e.date?.when || null, start: e.date?.start_date || null, venue: e.venue?.name || null,
    address: (e.address || []).join(", ") || null, price: e.price || null, link: e.link || e.ticket_info?.[0]?.link || null,
    ticket: e.ticket_info?.[0]?.source || null, thumb: e.thumbnail || null, virtual: VIRTUAL.test(`${e.title} ${(e.address || []).join(" ")}`) }));
  if (engine === "tripadvisor") return (j.places || j.locations || []).map((l: any) => ({
    title: l.title, type: l.place_type || l.type || null, rating: l.rating ?? null, reviews: l.reviews ?? null, where: l.location || null, desc: l.description || null, link: l.link || null, thumb: l.thumbnail || null, id: l.place_id || null }));
  if (engine === "google_local") return (j.local_results || []).map((l: any) => ({
    title: l.title, type: l.type || null, rating: l.rating ?? null, reviews: l.reviews ?? null, address: l.address || null, hours: l.hours || null, desc: l.description || null,
    lat: l.gps_coordinates?.latitude ?? null, lng: l.gps_coordinates?.longitude ?? null, thumb: l.thumbnail || null, id: l.place_id || null }));
  return [];
}

Deno.serve(async (req) => {
  try {
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data: sk } = await db.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle();
    if (!sk?.value || req.headers.get("x-sync-key") !== sk.value) return json({ error: "forbidden" }, 403);
    const key = Deno.env.get("SERPAPI_KEY"); if (!key) return json({ ok: false, why: "no_key" });
    const b = await req.json().catch(() => ({}));
    const engine = String(b.engine || ""); if (!["google_events", "tripadvisor", "google_local"].includes(engine) || !b.q) return json({ ok: false, why: "bad" }, 400);
    const u = new URL("https://serpapi.com/search.json"); u.searchParams.set("engine", engine); u.searchParams.set("q", String(b.q)); u.searchParams.set("api_key", key);
    if (b.ssrc) u.searchParams.set("ssrc", String(b.ssrc)); if (b.location) u.searchParams.set("location", String(b.location));
    const r = await fetch(u); const j = await r.json().catch(() => ({}));
    if (!r.ok || j.error) return json({ ok: false, status: r.status, error: String(j.error || "").slice(0, 200) });
    const items = tidy(engine, j);
    const raw = { search_metadata: { id: j.search_metadata?.id, status: j.search_metadata?.status, total_time_taken: j.search_metadata?.total_time_taken }, keys: Object.keys(j), first: (j.places || j.locations || j.events_results || j.local_results || [])[0] || null };
    await db.from("serp_pulls").insert({ engine, q: String(b.q), area: b.area || null, purpose: b.purpose || null, n: items.length, items, raw });
    return json({ ok: true, n: items.length, sample: items.slice(0, 3) });
  } catch (e) { return json({ ok: false, error: String(e) }, 500); }
});
