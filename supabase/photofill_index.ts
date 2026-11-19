import { createClient } from "npm:@supabase/supabase-js@2";

// Finds a real photo for place cards that still show an emoji cover, before giving up on them.
//   1. The Google photo we already hold a reference to (most cards: it was never turned into an image).
//   2. Google's photo list for the place, if we hold no reference.
//   3. The image the venue's own website shares as its preview (og:image / twitter:image), only if it is a real,
//      reasonably large picture and not a logo or icon.
// A card with none of these is marked photo_tried so it isn't asked again for a month; the emoji cover stays.
// Body: { ids?: uuid[], limit?: number }. With no ids it takes the next cards from _photo_queue. Auth: x-sync-key.
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const UA = "Mozilla/5.0 (compatible; LetsTogether/1.0; +https://letstogether.app)";

async function photoUrl(key: string, name: string): Promise<string | null> {
  try {
    const r = await fetch(`https://places.googleapis.com/v1/${name}/media?maxWidthPx=900&skipHttpRedirect=true`, { headers: { "X-Goog-Api-Key": key } });
    const d = await r.json(); return r.ok ? (d.photoUri ?? null) : null;
  } catch (_) { return null; }
}
async function placePhoto(key: string, id: string): Promise<{ name: string; credit: string | null } | null> {
  try {
    const r = await fetch(`https://places.googleapis.com/v1/places/${encodeURIComponent(id)}`, { headers: { "X-Goog-Api-Key": key, "X-Goog-FieldMask": "photos" } });
    const d = await r.json(); const p = d?.photos?.[0];
    return r.ok && p?.name ? { name: p.name, credit: p.authorAttributions?.[0]?.displayName ?? null } : null;
  } catch (_) { return null; }
}
async function siteImage(url: string): Promise<string | null> {
  const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 9000);
  try {
    const r = await fetch(url, { signal: ctl.signal, redirect: "follow", headers: { "User-Agent": UA, "Accept": "text/html" } });
    if (!r.ok || !/html/i.test(r.headers.get("content-type") ?? "")) return null;
    const html = (await r.text()).slice(0, 400000);
    const metas = [...html.matchAll(/<meta\b[^>]*>/gi)].map((m) => m[0]);
    const pick = (re: RegExp) => { for (const m of metas) if (re.test(m)) { const c = m.match(/content\s*=\s*["']([^"']+)["']/i)?.[1]; if (c) return c; } return null; };
    let img = pick(/property\s*=\s*["']og:image(:secure_url)?["']/i) ?? pick(/name\s*=\s*["']twitter:image(:src)?["']/i);
    if (!img) return null;
    img = new URL(img.replace(/&amp;/g, "&"), r.url || url).toString();
    if (!/^https:/.test(img) || /logo|favicon|icon|placeholder|default[-_]?share|blank/i.test(img)) return null;
    // it must really be a picture, and big enough to be a photo rather than a badge
    const h = await fetch(img, { signal: ctl.signal, headers: { "User-Agent": UA, "Range": "bytes=0-65535" } });
    const ct = h.headers.get("content-type") ?? "";
    if (!h.ok || !/^image\/(jpeg|jpg|png|webp)/i.test(ct)) return null;
    const total = Number(h.headers.get("content-range")?.split("/")[1] ?? h.headers.get("content-length") ?? 0);
    const got = (await h.arrayBuffer()).byteLength;
    if (Math.max(total, got) < 25000) return null;
    return img;
  } catch (_) { return null; } finally { clearTimeout(t); }
}

Deno.serve(async (req: Request) => {
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle();
    if (!sec?.value || req.headers.get("x-sync-key") !== sec.value) return json({ error: "forbidden" }, 403);
    const key = Deno.env.get("GOOGLE_PLACES_KEY"); if (!key) return json({ error: "no_key" }, 503);
    const a = await req.json().catch(() => ({}));
    let ids: string[] = Array.isArray(a.ids) ? a.ids.map(String).slice(0, 60) : [];
    if (!ids.length) { const { data } = await sb.rpc("_photo_queue", { p_n: Math.min(Math.max(Number(a.limit) || 30, 1), 60) }); ids = ((data ?? []) as any[]).map((x) => String(x.id ?? x)); }
    if (!ids.length) return json({ ok: true, done: 0 });
    const { data: cards } = await sb.from("cards").select("id,image,data").in("id", ids);
    const out = { google: 0, site: 0, none: 0 };
    const today = new Date().toISOString().slice(0, 10);
    await Promise.all(((cards ?? []) as any[]).filter((c) => !c.image).map(async (c) => {
      const d = { ...(c.data ?? {}) };
      let img: string | null = null, src = "";
      if (d.photo) { img = await photoUrl(key, d.photo); if (img) src = "google"; }
      if (!img && d.place_id) { const p = await placePhoto(key, d.place_id); if (p) { img = await photoUrl(key, p.name); if (img) { src = "google"; if (p.credit) d.photo_credit = p.credit; } } }
      if (!img && typeof d.url === "string" && /^https?:/.test(d.url)) { img = await siteImage(d.url); if (img) src = "site"; }
      if (img) { d.image_src = src; delete d.photo_tried; await sb.from("cards").update({ image: img, data: d }).eq("id", c.id); out[src as "google" | "site"]++; }
      else { d.photo_tried = today; await sb.from("cards").update({ data: d }).eq("id", c.id); out.none++; }
    }));
    return json({ ok: true, ...out });
  } catch (e) { return json({ error: String(e) }, 400); }
});
