// Trip merch through Fourthwall (Dave, 20 Nov). Shirts, hoodies, crewnecks, hats and kids' pieces only.
// A trip's planner makes a design (ours, or their own upload), picks up to 3 blanks, and we create hidden products in
// the Let's Together Fourthwall shop: $5 margin each, reachable only by link. Everyone orders their own size and pays
// Fourthwall; the app never handles money. Keys stay in the backend.
// Actions (signed-in, from the app): blanks; create {plan, templates[], image (base64), mime, w, h, name, ink};
// opts {plan, item} loads an item's colours, sizes and variant ids; checkout {plan} (planner) builds one Fourthwall checkout
// link for every "everyone gets one" item, one per size picked, shipped to the planner in one box.
import { createClient } from "npm:@supabase/supabase-js@2";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const FW = "https://api.fourthwall.com/open-api/v1.0";
const MARGIN = 5;
const auth = () => "Basic " + btoa(`${Deno.env.get("FOURTHWALL_API_USERNAME")}:${Deno.env.get("FOURTHWALL_API_PASSWORD")}`);
const fw = (path: string, init: RequestInit = {}) => fetch(FW + path, { ...init, headers: { Authorization: auth(), Accept: "application/json", "Content-Type": "application/json", ...(init.headers || {}) } });
const kindOf = (cat: string, name: string) => /Hats/i.test(cat) ? "Hat" : /Kids/i.test(cat) ? "Kids" : /Hoodies/i.test(cat) || /hood/i.test(name) ? "Hoodie" : /Sweatshirts/i.test(cat) ? "Crewneck" : /T-Shirts/i.test(cat) ? "Tee" : "";
// Shirt colours to offer for each ink, so a light design never lands on a white shirt. Unknown names are ignored by Fourthwall.
const DARK = ["Black", "Navy", "Charcoal", "Dark Grey Heather", "Forest Green", "Maroon", "Faded Black", "True Navy", "Graphite", "Espresso", "Dark Heather", "Heather Navy", "Black Heather"];
const LIGHT = ["White", "Natural", "Ash", "Heather Grey", "Athletic Heather", "Sand", "Ivory", "Bone", "Cream", "Light Blue", "Pink", "Faded Bone", "Heather Dust"];

async function blanks() {
  const out: any[] = [];
  for (let page = 0; page < 5; page++) {
    const r = await fw(`/product-templates?page=${page}&size=100`); if (!r.ok) break;
    const j = await r.json(), list = (j?.results || []) as any[];
    for (const t of list) { const k = kindOf(String(t.category || ""), String(t.name || "")); if (k) out.push({ id: t.productId || t.id, name: String(t.name || "").trim(), kind: k, thumb: t.thumbnail || null, price: t.basePrice?.amount != null ? Math.ceil((Number(t.basePrice.amount) + MARGIN) * 100) / 100 : null }); }
    if (list.length < 100) break;
  }
  const order = ["Tee", "Hoodie", "Crewneck", "Hat", "Kids"];
  return out.sort((a, b) => order.indexOf(a.kind) - order.indexOf(b.kind) || (a.price ?? 99) - (b.price ?? 99));
}

const SIZE_ORDER = ["XXS", "XS", "S", "M", "L", "XL", "2XL", "XXL", "3XL", "XXXL", "4XL", "5XL", "OS", "ONE SIZE"];
const sizeRank = (x: string) => { const i = SIZE_ORDER.indexOf(x.toUpperCase()); return i < 0 ? 50 : i; };
// Colours, sizes and variant ids for one product, read from the Open API.
async function optsFor(productId: string) {
  const r = await fw(`/products/${productId}`); if (!r.ok) return null;
  const d = await r.json(), vs = (d?.variants || []) as any[];
  const nm = (x: any) => typeof x === "string" ? x : x?.name || x?.value || "";
  const v: Record<string, string> = {}, colors: string[] = [], sizes: string[] = [];
  for (const x of vs) {
    const a = x.attributes || {}, c = nm(a.color ?? x.color) || "One colour", z = nm(a.size ?? x.size) || "One size";
    if (x.stock?.type === "LIMITED" && !(x.stock?.inStock > 0)) continue;
    v[`${c}|${z}`] = x.id; if (!colors.includes(c)) colors.push(c); if (!sizes.includes(z)) sizes.push(z);
  }
  sizes.sort((a, b) => sizeRank(a) - sizeRank(b));
  return { colors, sizes, v, slug: d?.slug || "" };
}

// Backend test only: a plain 1200px white square on a clear background, as a PNG, so the pipeline can be checked without an upload.
async function testPng(): Promise<string> {
  const W = 1200, H = 1200, row = W * 4 + 1, raw = new Uint8Array(row * H);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) { const i = y * row + 1 + x * 4, on = x > 300 && x < 900 && y > 300 && y < 900; if (on) { raw[i] = raw[i + 1] = raw[i + 2] = 255; raw[i + 3] = 255; } }
  const z = new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new CompressionStream("deflate"))).arrayBuffer());
  const crcT = new Uint32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (b: Uint8Array) => { let c = 0xffffffff; for (const v of b) c = crcT[(c ^ v) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (t: string, d: Uint8Array) => { const o = new Uint8Array(12 + d.length), dv = new DataView(o.buffer); dv.setUint32(0, d.length); o.set(new TextEncoder().encode(t), 4); o.set(d, 8); dv.setUint32(8 + d.length, crc(o.subarray(4, 8 + d.length))); return o; };
  const ih = new Uint8Array(13), dv = new DataView(ih.buffer); dv.setUint32(0, W); dv.setUint32(4, H); ih[8] = 8; ih[9] = 6;
  const parts = [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ih), chunk("IDAT", z), chunk("IEND", new Uint8Array())];
  const all = new Uint8Array(parts.reduce((a, b) => a + b.length, 0)); let o = 0; for (const q of parts) { all.set(q, o); o += q.length; }
  let bin = ""; for (const v of all) bin += String.fromCharCode(v); return btoa(bin);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const tok = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = tok ? await db.auth.getUser(tok) : { data: null } as any;
    const b = await req.json().catch(() => ({}));
    let uid = u?.user?.id;
    if (!uid && req.headers.get("x-sync-key")) {   // backend test path: act as the trip's owner
      const { data: sk } = await db.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle();
      if (sk?.value && req.headers.get("x-sync-key") === sk.value && b.plan) { const { data: o } = await db.from("fr_plans").select("owner").eq("id", b.plan).maybeSingle(); uid = o?.owner; if (b.testImage) { b.image = await testPng(); b.w = 1200; b.h = 1200; } }
    }
    if (!uid) return json({ ok: false, why: "signin" }, 401);
    if (b.action === "blanks") return json({ ok: true, blanks: await blanks(), margin: MARGIN });
    if (b.action === "probe" && req.headers.get("x-sync-key")) {   // backend test: what a product looks like
      const r = await fw(`/products?page=0&size=5`); const j = r.ok ? await r.json() : { status: r.status };
      const first = (j?.results || [])[0]; const one = first ? await (await fw(`/products/${first.id}`)).json() : null;
      return json({ ok: true, n: (j?.results || []).length, names: (j?.results || []).map((p: any) => [p.id, p.name, p.state?.type || p.state]), keys: one ? Object.keys(one) : null, variant: one?.variants?.[0] || null, opts: first ? await optsFor(first.id) : null });
    }

    if (b.action === "opts" || b.action === "checkout") {
      const { data: pl } = await db.from("fr_plans").select("id, owner, data").eq("id", b.plan).maybeSingle();
      if (!pl) return json({ ok: false, why: "no_plan" });
      const { data: me } = await db.from("fr_plan_members").select("role, status").eq("plan", pl.id).eq("person", uid).maybeSingle();
      if (me?.status !== "in") return json({ ok: false, why: "gone" });
      let merch = (pl.data?.merch || []) as any[];
      if (b.action === "opts") {
        const it = merch.find((m) => m.id === b.item); if (!it) return json({ ok: false, why: "item" });
        const o = await optsFor(it.id); if (!o) return json({ ok: false, why: "fourthwall" });
        const patch: Record<string, unknown> = { opts: { colors: o.colors, sizes: o.sizes, v: o.v } };
        if (!it.color || !o.colors.includes(it.color)) patch.color = o.colors[0] || null;
        const { data: m2 } = await db.rpc("fr_merch_patch", { p_id: pl.id, p_item: it.id, p_patch: patch });
        return json({ ok: true, merch: m2 });
      }
      if (!(pl.owner === uid || /host/i.test(String(me?.role || "")))) return json({ ok: false, why: "not_host" });
      const qty: Record<string, number> = {}, miss: string[] = [];
      let items = 0, cents = 0;
      for (const it of merch) {
        if (it.mode !== "all" || it.ordered || !it.sz || !Object.keys(it.sz).length) continue;
        const o = it.opts || await optsFor(it.id); if (!o) { miss.push(it.kind); continue; }
        const color = it.color && o.colors.includes(it.color) ? it.color : o.colors[0];
        for (const z of Object.values(it.sz) as string[]) { const vid = o.v[`${color}|${z}`]; if (!vid) { miss.push(`${it.kind} ${z}`); continue; } qty[vid] = (qty[vid] || 0) + 1; items++; cents += Math.round(Number(it.price || 0) * 100); }
      }
      if (!items) return json({ ok: false, why: miss.length ? "sizes" : "nothing", miss });
      const { data: sh } = await (async () => { const r = await fw("/shops/current"); return { data: r.ok ? await r.json() : null }; })();
      const dom = sh?.publicDomain || "lets-together-shop.fourthwall.com";
      const url = `https://${dom}/cart/checkout?products=${Object.entries(qty).map(([v, n]) => `${v}:${n}`).join(",")}`;
      return json({ ok: true, url, items, cents, miss });
    }

    if (b.action === "create") {
      const { data: pl } = await db.from("fr_plans").select("id, owner, title, city, data").eq("id", b.plan).maybeSingle();
      if (!pl) return json({ ok: false, why: "no_plan" });
      const { data: me } = await db.from("fr_plan_members").select("role, status").eq("plan", pl.id).eq("person", uid).maybeSingle();
      const host = pl.owner === uid || /host/i.test(String(me?.role || ""));
      if (!host || me?.status !== "in") return json({ ok: false, why: "not_host" });
      if ((pl.data?.merch || []).length >= 6) return json({ ok: false, why: "enough" });
      const ids = [...new Set((b.templates || []) as string[])].slice(0, 3); if (!ids.length) return json({ ok: false, why: "pick" });
      const known = await blanks(), pick = ids.map((id) => known.find((k) => k.id === id)).filter(Boolean) as any[];
      if (pick.length !== ids.length) return json({ ok: false, why: "pick" });
      const mime = b.mime === "image/jpeg" ? "image/jpeg" : "image/png";
      const bytes = Uint8Array.from(atob(String(b.image || "")), (c) => c.charCodeAt(0));
      if (bytes.length < 500 || bytes.length > 9_000_000) return json({ ok: false, why: "image" });
      // 1. upload the artwork once, register it, reuse it on every blank
      const up = await fw("/media/upload-url", { method: "POST", body: JSON.stringify({ fileName: `trip-${pl.id.slice(0, 8)}.${mime === "image/png" ? "png" : "jpg"}`, contentType: mime, size: bytes.length }) });
      if (!up.ok) return json({ ok: false, why: "upload", detail: (await up.text()).slice(0, 200) });
      const { uploadUrl, fileUrl } = await up.json();
      const put = await fetch(uploadUrl, { method: "PUT", headers: { "Content-Type": mime, "x-goog-content-length-range": `0,${bytes.length}` }, body: bytes });
      if (!put.ok) return json({ ok: false, why: "upload_put", detail: (await put.text()).slice(0, 200) });
      const reg = await fw("/media/images", { method: "POST", body: JSON.stringify({ fileUrl, width: Number(b.w) || 2400, height: Number(b.h) || 2400 }) });
      if (!reg.ok) return json({ ok: false, why: "register", detail: (await reg.text()).slice(0, 200) });
      const imageId = (await reg.json()).id;
      const { data: sh } = await (async () => { const r = await fw("/shops/current"); return { data: r.ok ? await r.json() : null }; })();
      const host_ = sh?.publicDomain || "lets-together-shop.fourthwall.com";
      const name = String(b.name || pl.title || "Our trip").replace(/\s+/g, " ").trim().slice(0, 60);
      const made: any[] = [], errs: string[] = [];
      for (const t of pick) {
        const body: Record<string, unknown> = { type: "design", productTemplateId: t.id, name: `${name} ${t.kind === "Kids" ? "Kids" : t.kind}`.slice(0, 80),
          description: `Made in Let's Together for ${name}${pl.city ? ", " + pl.city : ""}.`, regions: [{ region: "front", imageId, placementStrategy: "AUTO" }], profitMargin: MARGIN, publishOnCreate: false };
        if (t.kind !== "Hat") body.colors = b.ink === "dark" ? LIGHT : DARK;
        let r = await fw("/products", { method: "POST", body: JSON.stringify(body) });
        if (r.status === 400 && body.colors) { delete body.colors; r = await fw("/products", { method: "POST", body: JSON.stringify(body) }); }
        if (!r.ok) { errs.push(`${t.kind} ${r.status} ${(await r.text()).slice(0, 160)}`); continue; }
        const c = await r.json();
        let slug = "", raw = "";
        try { const g = await fw(`/products/${c.productId}`); const d = g.ok ? await g.json() : null; slug = d?.slug || d?.offerSlug || ""; raw = d ? Object.keys(d).join(",") : String(g.status); } catch (_) { /* link below falls back */ }
        const o = await optsFor(c.productId).catch(() => null);
        made.push({ id: c.productId, kind: t.kind, blank: t.name, price: t.price, img: c.images?.[0]?.url || null, url: slug ? `https://${host_}/products/${slug}` : `https://${host_}`, raw: slug ? undefined : raw,
          mode: "own", opts: o ? { colors: o.colors, sizes: o.sizes, v: o.v } : null, color: o?.colors?.[0] || null });
      }
      if (!made.length) return json({ ok: false, why: "create", detail: errs.join(" | ").slice(0, 400) });
      const { data: merch } = await db.rpc("fr_merch_add", { p_id: pl.id, p_items: made.map((m) => ({ ...m, by: uid, at: new Date().toISOString() })) });
      return json({ ok: true, made, errs, merch });
    }
    return json({ ok: false, why: "bad_action" }, 400);
  } catch (e) { return json({ ok: false, error: String(e) }, 500); }
});
