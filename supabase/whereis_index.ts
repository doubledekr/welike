import { createClient } from "npm:@supabase/supabase-js@2";

// Two small Google lookups for plans (Hamoody's feedback, 19 Nov 2026). Auth: the couple code must match a couple.
//   action "geocode": an address or place name typed by the person (their cottage, a friend's house) -> up to 3 matches
//                     with name, address and coordinates, so it can be saved as one of their places.
//   action "quest":   a side quest between two stops: a short, well-rated stop (ice cream, coffee, a bookshop, a park,
//                     a view) close to the walk or drive from A to B, open at that time. Returns up to 3; saves nothing.
//                     With snack:true it's a snack break near A instead (coffee, a bakery, dessert): up to 8 within
//                     about 15 minutes' walk, closest first, for a long gap after a stop that isn't food.
// The Google key never leaves the backend. Each call is logged in google_calls like the other place lookups.
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const SNACK = ["ice_cream_shop", "dessert_shop", "coffee_shop", "bakery", "chocolate_shop", "cafe", "tea_house", "donut_shop", "juice_shop", "confectionery"];
const QUEST = ["ice_cream_shop", "dessert_shop", "coffee_shop", "bakery", "book_store", "park", "art_gallery", "chocolate_shop", "tourist_attraction"];
const miles = (a: number, b: number, c: number, d: number) => { const r = (x: number) => x * Math.PI / 180, q = Math.sin(r(c - a) / 2) ** 2 + Math.cos(r(a)) * Math.cos(r(c)) * Math.sin(r(d - b) / 2) ** 2; return 3958.8 * 2 * Math.asin(Math.sqrt(q)); };
// open at hh:mm on that weekday, from Google's regularOpeningHours periods
function openAt(h: any, day: string, hhmm: string): boolean | null {
  const ps = h?.periods; if (!Array.isArray(ps) || !ps.length) return null;
  if (ps.length === 1 && ps[0].open && !ps[0].close) return true;
  const dow = new Date(day + "T12:00:00").getDay(), [H, M] = hhmm.split(":").map(Number), t = dow * 1440 + H * 60 + M;
  return ps.some((p: any) => { if (!p.open || !p.close) return false; const o = p.open.day * 1440 + p.open.hour * 60 + (p.open.minute ?? 0); let c = p.close.day * 1440 + p.close.hour * 60 + (p.close.minute ?? 0); if (c <= o) c += 7 * 1440; return (t >= o && t + 20 <= c) || (t + 7 * 1440 >= o && t + 7 * 1440 + 20 <= c); });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const key = Deno.env.get("GOOGLE_PLACES_KEY"); if (!key) return json({ error: "no_key" }, 503);
    const b = await req.json();
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: couple } = await sb.from("couples").select("id,settings").eq("code", String(b.code ?? "").trim().toUpperCase()).maybeSingle();
    if (!couple) return json({ error: "bad_code" }, 403);
    const log = (kind: string) => sb.from("google_calls").insert({ couple_id: couple.id, api: "places", sku: kind }).then(() => {}, () => {});
    if (b.action === "geocode") {
      const q = String(b.q ?? "").trim().slice(0, 120); if (q.length < 3) return json({ error: "short" }, 400);
      const st = couple.settings ?? {};
      const body: Record<string, unknown> = { textQuery: q, pageSize: 3 };
      if (typeof st.lat === "number") body.locationBias = { circle: { center: { latitude: st.lat, longitude: st.lng }, radius: 50000 } };
      const r = await fetch("https://places.googleapis.com/v1/places:searchText", { method: "POST",
        headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key, "X-Goog-FieldMask": "places.displayName,places.formattedAddress,places.location" }, body: JSON.stringify(body) });
      const d = await r.json(); log("whereis_geocode");
      if (!r.ok) return json({ error: "google", detail: d?.error?.message ?? r.status }, 502);
      return json({ places: (d.places ?? []).filter((p: any) => p.location).map((p: any) => ({ name: p.displayName?.text ?? "", address: p.formattedAddress ?? "", lat: p.location.latitude, lng: p.location.longitude })) });
    }
    if (b.action === "quest") {
      const a = [Number(b.lat), Number(b.lng)], z = [Number(b.lat2), Number(b.lng2)];
      if (![...a, ...z].every(isFinite)) return json({ error: "bad_location" }, 400);
      const leg = miles(a[0], a[1], z[0], z[1]), mid = [(a[0] + z[0]) / 2, (a[1] + z[1]) / 2];
      const snack = b.snack === true, radius = snack ? 1200 : Math.round(Math.min(Math.max(leg * 0.6, 0.35), 3) * 1609.344);
      const r = await fetch("https://places.googleapis.com/v1/places:searchNearby", { method: "POST",
        headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key, "X-Goog-FieldMask": "places.id,places.displayName,places.primaryTypeDisplayName,places.primaryType,places.location,places.rating,places.userRatingCount,places.regularOpeningHours,places.photos,places.googleMapsUri,places.shortFormattedAddress,places.websiteUri" },
        body: JSON.stringify({ includedTypes: snack ? SNACK : QUEST, maxResultCount: 20, rankPreference: "POPULARITY", locationRestriction: { circle: { center: { latitude: snack ? a[0] : mid[0], longitude: snack ? a[1] : mid[1] }, radius } } }) });
      const d = await r.json(); log(snack ? "whereis_snack" : "whereis_quest");
      if (!r.ok) return json({ error: "google", detail: d?.error?.message ?? r.status }, 502);
      const day = String(b.day ?? ""), time = String(b.time ?? "");
      const out = (d.places ?? []).map((p: any) => {
        const la = p.location?.latitude, lo = p.location?.longitude;
        // how far off the straight line from A to B this takes you
        const detour = la == null ? 99 : miles(a[0], a[1], la, lo) + miles(la, lo, z[0], z[1]) - leg;
        return { id: p.id, name: p.displayName?.text ?? "", type: p.primaryTypeDisplayName?.text ?? null, ptype: p.primaryType ?? null, lat: la, lng: lo, rating: p.rating ?? null, ratings: p.userRatingCount ?? null,
          maps: p.googleMapsUri ?? null, address: p.shortFormattedAddress ?? null, url: p.websiteUri ?? null, photo: p.photos?.[0]?.name ?? null,
          dist: la == null ? null : Math.round(miles(a[0], a[1], la, lo) * 100) / 100, open: /^\d{4}-\d{2}-\d{2}$/.test(day) && /^\d{2}:\d{2}$/.test(time) ? openAt(p.regularOpeningHours, day, time) : null, detour: Math.round(detour * 100) / 100 };
      // not one of the two stops themselves, and not somewhere that's a whole outing on its own
      }).filter((p: any) => p.name && p.lat != null && miles(a[0], a[1], p.lat, p.lng) > 0.06 && (snack || miles(z[0], z[1], p.lat, p.lng) > 0.06) && !/museum|stadium|casino|amusement/.test(String(p.ptype ?? "")) && p.open !== false && (p.rating ?? 0) >= 4.4 && (p.ratings ?? 0) >= 40 && (snack ? p.dist <= 0.75 && SNACK.includes(String(p.ptype ?? "")) : p.detour <= Math.max(0.4, leg * 0.35)))
        .sort((x: any, y: any) => snack ? (x.dist - y.dist) : (x.detour - y.detour) || ((y.rating ?? 0) - (x.rating ?? 0))).slice(0, snack ? 8 : 3);
      // a photo for each, so the suggestion looks like somewhere you'd want to stop
      await Promise.all(out.map(async (p: any) => { if (!p.photo) return; try { const pr = await fetch(`https://places.googleapis.com/v1/${p.photo}/media?maxWidthPx=600&skipHttpRedirect=true`, { headers: { "X-Goog-Api-Key": key } }); const pd = await pr.json(); p.image = pr.ok ? pd.photoUri ?? null : null; } catch (_) { p.image = null; } }));
      return json({ leg: Math.round(leg * 100) / 100, quests: out });
    }
    return json({ error: "bad_action" }, 400);
  } catch (e) { return json({ error: String(e) }, 400); }
});
