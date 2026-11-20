import { createClient } from "npm:@supabase/supabase-js@2";

// photo64 (19 Nov, backend only): hands Google place photos back as data URIs, for card previews made outside the app
// (Claude's workspace cannot load Google's image host). Body: { urls?: string[], venues?: [{ q, lat, lng }] }.
// urls: Google photo links (lh3.googleusercontent.com only). venues: looked up on Google Places (one search, one photo
// each, logged in google_calls like every other call). Auth: x-sync-key. Writes nothing else.
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const b64 = (buf: ArrayBuffer) => { let s = ""; const a = new Uint8Array(buf); for (let i = 0; i < a.length; i += 0x8000) s += String.fromCharCode(...a.subarray(i, i + 0x8000)); return btoa(s); };
async function grab(u: string): Promise<string | null> {
  try { if (!/^https:\/\/lh3\.googleusercontent\.com\//.test(u)) return null; const r = await fetch(u); if (!r.ok) return null;
    return `data:${r.headers.get("content-type") ?? "image/jpeg"};base64,${b64(await r.arrayBuffer())}`; } catch (_) { return null; }
}
Deno.serve(async (req: Request) => {
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle();
    if (!sec?.value || req.headers.get("x-sync-key") !== sec.value) return json({ error: "forbidden" }, 403);
    const a = await req.json().catch(() => ({}));
    const out: Record<string, string | null> = {};
    await Promise.all(((a.urls ?? []) as string[]).slice(0, 40).map(async (u) => { out[u] = await grab(u); }));
    const gkey = Deno.env.get("GOOGLE_PLACES_KEY") ?? "", ven: Record<string, unknown> = {};
    await Promise.all(((a.venues ?? []) as any[]).slice(0, 25).map(async (v) => {
      try {
        const body: Record<string, unknown> = { textQuery: String(v.q), pageSize: 1 };
        if (Number.isFinite(v.lat)) body.locationBias = { circle: { center: { latitude: v.lat, longitude: v.lng }, radius: 50000 } };
        const r = await fetch("https://places.googleapis.com/v1/places:searchText", { method: "POST", headers: { "Content-Type": "application/json", "X-Goog-Api-Key": gkey, "X-Goog-FieldMask": "places.id,places.displayName,places.photos,places.location" }, body: JSON.stringify(body) });
        const d = await r.json().catch(() => null); await sb.from("google_calls").insert({ api: "places", sku: "Text Search Pro", ok: r.ok, note: ("photo64 " + v.q).slice(0, 200) });
        const p = d?.places?.[0]; if (!p?.photos?.[0]?.name) { ven[v.q] = null; return; }
        const ph = await fetch(`https://places.googleapis.com/v1/${p.photos[0].name}/media?maxWidthPx=600&skipHttpRedirect=true`, { headers: { "X-Goog-Api-Key": gkey } });
        const pd = await ph.json().catch(() => null); await sb.from("google_calls").insert({ api: "places", sku: "Place Photos", ok: ph.ok, note: "photo64 photo" });
        ven[v.q] = { name: p.displayName?.text, place_id: p.id, lat: p.location?.latitude, lng: p.location?.longitude, image: pd?.photoUri ?? null, data: pd?.photoUri ? await grab(pd.photoUri) : null };
      } catch (_) { ven[v.q] = null; }
    }));
    return json({ ok: true, urls: out, venues: ven });
  } catch (e) { return json({ ok: false, detail: String(e).slice(0, 200) }); }
});
