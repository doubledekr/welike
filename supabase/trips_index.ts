// Let's Together trips: experiences from the Viator affiliate API.
// Self-authenticating: 'seed' needs the x-sync-key header, 'city', 'local' and 'explore' need a valid couple code.
// 'explore' (beta, 20 Nov): day trips out of a trip city, and tours bookable on the trip's dates, tagged on the cards
// (data.explore = 'day' | 'dates') for the Explore pile. Viator only; no Google calls.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-key", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

async function secret(key: string) { const { data } = await db.from("app_secrets").select("value").eq("key", key).maybeSingle(); return data?.value as string | undefined; }
const tidy = (s: string) => s.trim().replace(/\s+/g, " ").slice(0, 40).toLowerCase().replace(/(^|[\s-])([a-z])/g, (_m, a, b) => a + b.toUpperCase());
const ymd = (d: Date) => d.toISOString().slice(0, 10);
const LOCAL_MILES = 75;   // a "local" experience has to be within this distance of home

async function search(key: string, term: string, count: number, week = false, range?: { from: string; to: string }) {
  const body: Record<string, unknown> = { searchTerm: term, searchTypes: [{ searchType: "PRODUCTS", pagination: { start: 1, count } }], currency: "USD" };
  if (week) { const a = new Date(), b = new Date(Date.now() + 7 * 864e5); body.productFiltering = { dateRange: { from: ymd(a), to: ymd(b) } }; }
  if (range) body.productFiltering = { dateRange: range };
  const r = await fetch("https://api.viator.com/partner/search/freetext", { method: "POST", headers: { "exp-api-key": key, "Accept": "application/json;version=2.0", "Accept-Language": "en-US", "Content-Type": "application/json" }, body: JSON.stringify(body) });
  if (!r.ok) { if (week || range) return search(key, term, count, false); throw new Error("viator_" + r.status); }
  const j = await r.json();
  return (j?.products?.results || []) as any[];
}
function toItem(p: any, city: string) {
  const imgs = p.images || [], img = imgs.find((i: any) => i.isCover) || imgs[0];
  const vs = (img?.variants || []).slice().sort((a: any, b: any) => (a.width || 0) - (b.width || 0));
  const image = (vs.find((v: any) => (v.width || 0) >= 600) || vs[vs.length - 1])?.url || "";
  const price = p.pricing?.summary?.fromPrice, rating = p.reviews?.combinedAverageRating, reviews = p.reviews?.totalReviews;
  const d = p.duration || {}, minutes = d.fixedDurationInMinutes || d.variableDurationFromMinutes || null;
  return { code: p.productCode, city, title: p.title, image,
    subtitle: [city, price ? "from $" + Math.round(price) : ""].filter(Boolean).join(" · "),
    data: { city, price: price ? Math.round(price) : null, rating: rating ? Math.round(rating * 10) / 10 : null, reviews: reviews || null, minutes,
      url: p.productUrl || null, notes: String(p.description || "").slice(0, 600), source: "viator" } as Record<string, unknown> };
}
const weekly = (it: ReturnType<typeof toItem>) => { it.subtitle = ["Bookable this week", it.data.price ? "from $" + it.data.price : ""].filter(Boolean).join(" · "); return it; };

// ---- keeping "local" local ----
// Viator's search matches words, not places: "Royal Oak, MI" also finds "Royal London" and tours in India.
// Every product link names its destination (/tours/Detroit/...), so each destination is located once (Google,
// remembered in viator_dest) and anything further than LOCAL_MILES from home is dropped. If a destination cannot
// be located the product is dropped too: showing nothing beats showing another continent.
function miles(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const r = (d: number) => d * Math.PI / 180, dLat = r(lat2 - lat1), dLng = r(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(r(lat1)) * Math.cos(r(lat2)) * Math.sin(dLng / 2) ** 2;
  return 3958.8 * 2 * Math.asin(Math.sqrt(a));
}
const destOf = (p: any): string => { const m = String(p?.productUrl || "").match(/\/tours\/([^\/?#]+)\//); if (!m) return ""; try { return decodeURIComponent(m[1]).replace(/-/g, " ").trim(); } catch { return m[1].replace(/-/g, " ").trim(); } };
async function locate(name: string, gkey: string | undefined, near?: { lat: number; lng: number }): Promise<{ lat: number; lng: number } | null> {
  if (!name || !gkey) return null;
  try {
    const body: Record<string, unknown> = { textQuery: name, pageSize: 1 };
    if (near) body.locationBias = { circle: { center: { latitude: near.lat, longitude: near.lng }, radius: 50000 } };
    const r = await fetch("https://places.googleapis.com/v1/places:searchText", { method: "POST", headers: { "Content-Type": "application/json", "X-Goog-Api-Key": gkey, "X-Goog-FieldMask": "places.location" }, body: JSON.stringify(body) });
    const d = await r.json();
    const loc = d?.places?.[0]?.location;
    return r.ok && loc ? { lat: loc.latitude, lng: loc.longitude } : null;
  } catch { return null; }
}
async function keepLocal(products: any[], home: { lat: number; lng: number }, gkey: string | undefined) {
  const names = [...new Set(products.map(destOf).filter(Boolean))];
  const where = new Map<string, { lat: number; lng: number } | null>();
  if (names.length) {
    const { data } = await db.from("viator_dest").select("name,lat,lng").in("name", names);
    for (const d of (data || []) as any[]) where.set(d.name, d.lat == null ? null : { lat: d.lat, lng: d.lng });
    await Promise.all(names.filter((n) => !where.has(n)).map(async (n) => {
      // No bias toward home here: "London" must resolve to London, not to a London Street nearby.
      const loc = await locate(n, gkey);
      where.set(n, loc);
      if (gkey) await db.from("viator_dest").upsert({ name: n, lat: loc?.lat ?? null, lng: loc?.lng ?? null });
    }));
  }
  const kept = products.filter((p) => { const w = where.get(destOf(p)); return !!w && miles(home.lat, home.lng, w.lat, w.lng) <= LOCAL_MILES; });
  // The nearest real Viator destination among what survived (Detroit for Royal Oak, say), for a second, better search.
  const tally = new Map<string, number>(); kept.forEach((p) => tally.set(destOf(p), (tally.get(destOf(p)) || 0) + 1));
  const best = [...tally.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] || "";
  return { kept, best };
}
async function localItems(key: string, gkey: string | undefined, term: string, home: { lat: number; lng: number }, label: string, max: number) {
  const first = (await search(key, term, 12, true)).filter((p) => p.productCode && p.title);
  let { kept, best } = await keepLocal(first, home, gkey);
  if (kept.length < max && best && best.toLowerCase() !== term.split(",")[0].trim().toLowerCase()) {
    const more = (await search(key, best, 12, true)).filter((p) => p.productCode && p.title);
    const again = await keepLocal(more, home, gkey);
    const seen = new Set(kept.map((p) => p.productCode));
    kept = kept.concat(again.kept.filter((p) => !seen.has(p.productCode)));
  }
  return { items: kept.slice(0, max).map((p) => weekly(toItem(p, label))), found: first.length, kept: kept.length };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const b = await req.json().catch(() => ({}));
    const key = await secret("viator_key");
    if (!key) return json({ ok: false, error: "no_key" });

    if (b.action === "seed") {
      if (req.headers.get("x-sync-key") !== await secret("sync_key")) return json({ error: "forbidden" }, 403);
      const out: Record<string, number> = {};
      for (const raw of (b.cities || []).slice(0, 12)) {
        const city = tidy(String(raw));
        try { const items = (await search(key, city, b.count || 14)).filter((p) => p.productCode && p.title).map((p) => toItem(p, city)); const { data } = await db.rpc("trips_upsert", { p_items: items }); out[city] = data ?? 0; }
        catch (e) { out[city] = -1; console.error(city, String(e)); }
      }
      return json({ ok: true, out });
    }

    const { data: couple } = await db.from("couples").select("id, settings").eq("code", String(b.code || "").toUpperCase()).maybeSingle();
    if (!couple) return json({ error: "bad_code" }, 403);

    if (b.action === "city") {
      const city = tidy(String(b.city || ""));
      if (city.length < 2) return json({ ok: false, error: "bad_city" });
      const { count } = await db.from("cards").select("id", { count: "exact", head: true }).eq("deck", "trip").is("couple_id", null).eq("kind", city).eq("active", true);
      if ((count || 0) >= 10) return json({ ok: true, city, added: 0, total: count });
      const items = (await search(key, city, 20)).filter((p) => p.productCode && p.title).map((p) => toItem(p, city));
      if (!items.length) return json({ ok: false, error: "nothing_found", city });
      const { data } = await db.rpc("trips_upsert", { p_items: items });
      return json({ ok: true, city, added: data ?? 0 });
    }

    if (b.action === "explore") {
      const city = tidy(String(b.city || ""));
      if (city.length < 2) return json({ ok: false, error: "bad_city" });
      const { count } = await db.from("cards").select("id", { count: "exact", head: true }).eq("deck", "trip").is("couple_id", null).eq("kind", city).eq("active", true).not("data->explore", "is", null);
      if ((count || 0) >= 8) return json({ ok: true, city, cached: true, total: count });
      const re = /^\d{4}-\d{2}-\d{2}$/, from = re.test(String(b.from || "")) ? String(b.from) : "", to = re.test(String(b.to || "")) ? String(b.to) : from;
      const out: Record<string, number> = {};
      const skip = (t: string) => /transfer|shuttle|airport|private driver/i.test(t);
      const day = (await search(key, `day trips from ${city}`, 12)).filter((p) => p.productCode && p.title && !skip(p.title) && /day trip|excursion|full[- ]day|half[- ]day|from /i.test(p.title));
      if (day.length) { await db.rpc("trips_upsert", { p_items: day.map((p) => toItem(p, city)) }); const { data } = await db.rpc("trips_tag_explore", { p_codes: day.map((p) => p.productCode), p_tag: "day" }); out.day = data ?? 0; }
      if (from && from >= ymd(new Date())) {
        const dated = (await search(key, city, 12, false, { from, to })).filter((p) => p.productCode && p.title && !skip(p.title));
        if (dated.length) { await db.rpc("trips_upsert", { p_items: dated.map((p) => toItem(p, city)) }); const { data } = await db.rpc("trips_tag_explore", { p_codes: dated.map((p) => p.productCode), p_tag: "dates" }); out.dates = data ?? 0; }
      }
      return json({ ok: true, city, out });
    }

    if (b.action === "local") {
      const s = (couple.settings || {}) as any, today = ymd(new Date());
      const gkey = Deno.env.get("GOOGLE_PLACES_KEY");
      // Travel mode: things to do this week around wherever this phone is, tagged with that city.
      const away = b.city ? tidy(String(b.city)) : "";
      if (away) {
        const { count } = await db.from("cards").select("id", { count: "exact", head: true }).eq("couple_id", couple.id).eq("deck", "event").eq("active", true).gte("event_date", today).eq("data->>away", away);
        if ((count || 0) >= 4) return json({ ok: true, added: 0, cached: true, city: away });
        // Where is "here"? The phone's position when the app sent it, else the city name looked up.
        const here = (isFinite(Number(b.lat)) && isFinite(Number(b.lng)) && b.lat != null) ? { lat: Number(b.lat), lng: Number(b.lng) } : await locate(away, gkey);
        if (!here) return json({ ok: true, added: 0, city: away, note: "unlocated" });
        const got = await localItems(key, gkey, away, here, away, 8);
        got.items.forEach((it) => { it.data.away = away; });
        const { data } = await db.rpc("trips_local_upsert", { p_couple: couple.id, p_items: got.items });
        return json({ ok: true, city: away, added: data ?? 0, found: got.found, kept: got.kept });
      }
      if (!s.zip) return json({ ok: false, error: "no_zip" });
      if (s.local_exp?.at === today && s.local_exp?.zip === s.zip && s.local_exp?.v === 2) return json({ ok: true, added: 0, cached: true });
      let city = s.local_exp?.zip === s.zip ? s.local_exp?.city : "";
      let home: { lat: number; lng: number } | null = typeof s.lat === "number" && typeof s.lng === "number" ? { lat: s.lat, lng: s.lng }
        : s.zgeo?.zip === s.zip && typeof s.zgeo?.lat === "number" ? { lat: s.zgeo.lat, lng: s.zgeo.lng } : null;
      if (!city || !home) {
        const z = await fetch("https://api.zippopotam.us/us/" + encodeURIComponent(String(s.zip).slice(0, 5)));
        if (z.ok) { const j = await z.json(); const pl = j?.places?.[0];
          if (pl) { if (!city) city = pl["place name"] + ", " + pl["state abbreviation"]; if (!home && isFinite(Number(pl.latitude))) home = { lat: Number(pl.latitude), lng: Number(pl.longitude) }; } }
      }
      if (!city) return json({ ok: false, error: "no_city" });
      if (!home) return json({ ok: false, error: "no_home" });
      const got = await localItems(key, gkey, city, home, city.split(",")[0], 6);
      const { data } = await db.rpc("trips_local_upsert", { p_couple: couple.id, p_items: got.items });
      const { data: now } = await db.from("couples").select("settings").eq("id", couple.id).maybeSingle();
      await db.from("couples").update({ settings: { ...((now?.settings ?? s) as any), local_exp: { at: today, zip: s.zip, city, v: 2 } } }).eq("id", couple.id);
      return json({ ok: true, city, added: data ?? 0, found: got.found, kept: got.kept });
    }
    return json({ error: "bad_action" }, 400);
  } catch (e) {
    console.error(String(e));
    return json({ ok: false, error: String((e as Error).message || e) });
  }
});
