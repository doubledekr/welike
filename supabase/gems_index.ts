import { createClient } from "npm:@supabase/supabase-js@2";
import { logAi } from "./ai_log.ts";
import { wikiImages } from "./wikiimg.ts";
logAi("gems");

// Hidden gems: offbeat places near a couple's home or a trip city, built from open sources.
//   1. pick:  geotagged Wikipedia articles around an area -> Claude keeps the ones a curious couple would find surprising
//   2. write: the article intros are read and Claude writes one line per place in the app's own words (facts from the intro only)
//   3. match: each kept place is matched to Google Places for opening hours, a map link and its country. The photo is the
//      article's own Wikipedia photo when it is large and freely licensed (credited on the card, Dave 20 Nov); only
//      otherwise is a Google photo fetched, which saves most Place Photos calls.
// One stage per call ("work" does whichever is waiting), so no call runs long. Called by the database on a timer.
// Auth: the x-sync-key header must match the backend's sync key. Keys never leave the backend.
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const UA = { "User-Agent": "LetsTogether/1.0 (https://letstogether.app)" };
const apiKey = () => Deno.env.get("ANTHROPIC_API_KEY") ?? Deno.env.get("CLAUDE_API_KEY") ?? Deno.env.get("CLAUDE_KEY") ?? Deno.env.get("ANTHROPIC_KEY") ?? "";
const MODELS = [Deno.env.get("CLAUDE_GEMS_MODEL"), "claude-sonnet-5-5", "claude-sonnet-4-5", "claude-haiku-5-5", "claude-haiku-4-5"].filter(Boolean) as string[];
let lastErr = "";

async function claude(prompt: string, maxTokens: number, ms: number): Promise<string | null> {
  const key = apiKey(); lastErr = "";
  if (!key) { lastErr = "no key"; return null; }
  const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), ms);
  try {
    for (const model of MODELS) {
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", signal: ctl.signal,
        headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" },
        body: JSON.stringify({ model, max_tokens: maxTokens, messages: [{ role: "user", content: prompt }] }) });
      if (!r.ok) { const t = (await r.text()).slice(0, 240); lastErr = `${model} ${r.status} ${t}`; if (r.status === 404 || (r.status === 400 && /model/i.test(t))) continue; return null; }
      const d = await r.json();
      const text = (d.content ?? []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("").trim();
      if (text) return text;
      lastErr = `${model} empty (${d.stop_reason})`; return null;
    }
    return null;
  } catch (e) { lastErr = String(e); return null; } finally { clearTimeout(timer); }
}
const parseArr = (t: string | null): any[] => { const m = (t ?? "").match(/\[[\s\S]*\]/); try { const a = JSON.parse(m?.[0] ?? "[]"); return Array.isArray(a) ? a : []; } catch (_) { return []; } };

function km(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const r = (d: number) => d * Math.PI / 180, a = Math.sin(r(lat2 - lat1) / 2) ** 2 + Math.cos(r(lat1)) * Math.cos(r(lat2)) * Math.sin(r(lng2 - lng1) / 2) ** 2;
  return 6371 * 2 * Math.asin(Math.sqrt(a));
}
// Titles that are never a place to visit: stations, schools, broadcasters, administrative areas, events, lists.
const NOISE = /^(List of|[WK][A-Z]{2,3}(-[A-Z]{2})?( \(|$)|C[A-Z]{3}(-|$)|\d{4} )|\b(station|High School|Middle School|Elementary|School District|Academy|Township|County|Hospital|Medical Center|Interstate|Highway|Route \d|Airport|Mall|Shopping|Stadium shooting|shooting|stabbing|riot|election|Company|Corporation|Inc\.|Apartments|Cooperative House|student housing|College of|School of|Department of|Radio|\(TV|Television)\b|, (Michigan|Maryland|Pennsylvania|North Carolina|Virginia|Ohio|Illinois|Ontario|[A-Z][a-z]+ County)$/;

async function geosearch(lat: number, lng: number): Promise<any[]> {
  try {
    const r = await fetch(`https://en.wikipedia.org/w/api.php?action=query&list=geosearch&gsradius=10000&gslimit=500&format=json&gscoord=${lat}%7C${lng}`, { headers: UA });
    const d = await r.json(); return d?.query?.geosearch ?? [];
  } catch (_) { return []; }
}

async function stagePick(sb: any, area: any) {
  // The centre plus six points around it, so a suburb also sees the city next door (about 16 miles across in all).
  const pts: [number, number][] = [[area.lat, area.lng]];
  for (let i = 0; i < 6; i++) { const a = i * Math.PI / 3; pts.push([area.lat + (15 / 111) * Math.cos(a), area.lng + (15 / (111 * Math.cos(area.lat * Math.PI / 180))) * Math.sin(a)]); }
  const all = (await Promise.all(pts.map(([la, ln]) => geosearch(la, ln)))).flat();
  const seen = new Map<number, any>();
  for (const p of all) if (!seen.has(p.pageid) && !NOISE.test(p.title)) seen.set(p.pageid, { ...p, d: km(area.lat, area.lng, p.lat, p.lon) });
  const { data: have } = await sb.from("gems").select("pageid").in("pageid", [...seen.keys()].slice(0, 3000));
  const known = new Set(((have ?? []) as any[]).map((g) => Number(g.pageid)));
  const cands = [...seen.values()].filter((p) => !known.has(p.pageid)).sort((a, b) => a.d - b.d).slice(0, 1100);
  if (cands.length < 5) { await sb.from("gem_areas").update({ status: known.size ? "picked" : "empty", note: `candidates ${cands.length}, known ${known.size}`, done_at: new Date().toISOString() }).eq("id", area.id); return { stage: "pick", cands: cands.length, known: known.size }; }
  const list = cands.map((p, i) => `${i + 1}. ${p.title}`).join("\n");
  const text = await claude(
    `These are titles of Wikipedia articles about geotagged places in and around ${area.label || "one metro area"}.\n\n${list}\n\n` +
    `Pick the hidden gems: places a curious couple could actually visit today and would be delighted or surprised by. Good picks are odd small museums, striking interiors you can walk into, unusual public art, strange landmarks, gardens, ruins you can see, historic oddities, overlooks, old cemeteries with a story, beautiful libraries, one-of-a-kind shops, markets, storied old bars and diners.\n` +
    `Leave out: anything demolished, closed or private; ordinary office buildings, houses, churches and schools unless truly remarkable to visit; sports arenas; hospitals; hotels; neighbourhoods and districts; companies; the big museums, zoos and landmarks every visitor already knows; anything you are not confident still exists; a second article about the same place.\n` +
    `When many places are the same kind of thing (covered bridges, say), pick only the three or four most unusual.\n` +
    `Pick at most 45, fewer if the list is thin. Score each 1 to 10 for how surprising and worth the visit it is.\n` +
    `Reply with JSON only: [{"n": list number, "s": score, "k": "two or three word type, e.g. Glasshouse garden"}]`, 5000, 110000);
  const picks = parseArr(text).filter((x) => Number.isInteger(x?.n) && x.n >= 1 && x.n <= cands.length);
  if (!picks.length) { await sb.from("gem_areas").update({ tries: (area.tries ?? 0) + 1, note: ("pick failed: " + lastErr).slice(0, 300), status: (area.tries ?? 0) >= 3 ? "failed" : "new" }).eq("id", area.id); return { stage: "pick", error: lastErr || "no picks", cands: cands.length }; }
  const rows = picks.slice(0, 45).map((x) => { const p = cands[x.n - 1]; return { pageid: p.pageid, title: String(p.title).slice(0, 120), lat: p.lat, lng: p.lon, score: Math.min(10, Math.max(1, Number(x.s) || 5)), kind: String(x.k ?? "").slice(0, 40) || null, src: `https://en.wikipedia.org/?curid=${p.pageid}` }; });
  await sb.from("gems").upsert(rows, { onConflict: "pageid", ignoreDuplicates: true });
  await sb.from("gem_areas").update({ status: "picked", note: `candidates ${cands.length}, picked ${rows.length}`, done_at: new Date().toISOString() }).eq("id", area.id);
  return { stage: "pick", area: area.label, cands: cands.length, picked: rows.length };
}

async function stageWrite(sb: any) {
  const { data } = await sb.from("gems").select("id,pageid,title,kind").is("keep", null).order("created_at").limit(40);
  const gs = (data ?? []) as any[]; if (!gs.length) return null;
  const ex = new Map<number, string>();
  for (let i = 0; i < gs.length; i += 20) {
    try {
      const r = await fetch(`https://en.wikipedia.org/w/api.php?action=query&prop=extracts&exintro=1&explaintext=1&exlimit=20&format=json&pageids=${gs.slice(i, i + 20).map((g) => g.pageid).join("%7C")}`, { headers: UA });
      const d = await r.json();
      for (const p of Object.values(d?.query?.pages ?? {}) as any[]) ex.set(Number(p.pageid), String(p.extract ?? "").replace(/\s+/g, " ").slice(0, 700));
    } catch (_) { /* a missing intro means the place is dropped below */ }
  }
  const list = gs.map((g, i) => `${i + 1}. ${g.title}\n${ex.get(Number(g.pageid)) || "(no text)"}`).join("\n\n");
  const text = await claude(
    `For each place below you get its name and the opening of its Wikipedia article. Decide if it belongs in a deck of hidden gems for couples looking for something unusual to do, and write its card.\n\n${list}\n\n` +
    `keep = false if the text shows it is demolished, closed, private, not a place you can visit, or there is no text. Otherwise keep = true.\n` +
    `line = one sentence, at most 20 words, in plain warm words, saying what makes it worth a visit. Use only facts from the text. Do not copy phrases from the text. No opening hours, prices or superlatives you cannot back up. No quotation marks.\n` +
    `k = a two or three word type, like Glasshouse garden or Odd museum.\n` +
    `Reply with JSON only: [{"n": number, "keep": true or false, "line": "...", "k": "..."}]`, 5000, 110000);
  const out = parseArr(text);
  if (!out.length) {   // a batch that cannot be answered twice is dropped rather than retried forever
    const { data: st } = await sb.from("gem_state").select("at").eq("k", "writefail:" + gs[0].id).maybeSingle();
    if (st) await sb.from("gems").update({ keep: false }).in("id", gs.map((g) => g.id)); else await sb.from("gem_state").insert({ k: "writefail:" + gs[0].id });
    return { stage: "write", error: lastErr || "no answer", n: gs.length, dropped: !!st };
  }
  let kept = 0; const done = new Set<number>();
  for (const x of out) {
    const g = gs[Number(x?.n) - 1]; if (!g || done.has(x.n)) continue; done.add(x.n);
    const line = String(x.line ?? "").replace(/["“”]/g, "").trim().slice(0, 200);
    const keep = x.keep === true && line.length > 15; if (keep) kept++;
    await sb.from("gems").update({ keep, line: keep ? line : null, kind: String(x.k ?? g.kind ?? "").slice(0, 40) || g.kind }).eq("id", g.id);
  }
  return { stage: "write", n: gs.length, answered: done.size, kept };
}

function packHours(h: any): unknown {
  const ps = h?.periods; if (!Array.isArray(ps) || !ps.length) return null;
  if (ps.length === 1 && ps[0].open && !ps[0].close) return "always";
  const out: number[][] = [];
  for (const p of ps) { const o = p.open, c = p.close; if (!o || !c) continue; out.push([o.day ?? 0, (o.hour ?? 0) * 100 + (o.minute ?? 0), c.day ?? 0, (c.hour ?? 0) * 100 + (c.minute ?? 0)]); }
  return out.length ? out : null;
}
async function stageMatch(sb: any) {
  const key = Deno.env.get("GOOGLE_PLACES_KEY"); if (!key) return { stage: "match", error: "no google key" };
  const { data } = await sb.from("gems").select("id,pageid,title,lat,lng").eq("keep", true).is("matched", null).order("score", { ascending: false }).limit(15);
  const gs = (data ?? []) as any[]; if (!gs.length) return null;
  const pics = await wikiImages(gs.map((g) => g.pageid));
  let ok = 0, wiki = 0;
  await Promise.all(gs.map(async (g) => {
    try {
      const wi = pics.get(Number(g.pageid));
      const r = await fetch("https://places.googleapis.com/v1/places:searchText", { method: "POST",
        headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key, "X-Goog-FieldMask": "places.id,places.displayName,places.location,places.googleMapsUri,places.regularOpeningHours,places.photos,places.primaryType,places.shortFormattedAddress,places.formattedAddress,places.businessStatus" },
        body: JSON.stringify({ textQuery: String(g.title).replace(/\s*\([^)]*\)$/, ""), pageSize: 3, locationBias: { circle: { center: { latitude: g.lat, longitude: g.lng }, radius: 1500 } } }) });
      const d = await r.json();
      if (!r.ok) { await sb.from("gems").update({ matched: false }).eq("id", g.id); return; }
      const p = (d.places ?? []).find((x: any) => x.location && km(g.lat, g.lng, x.location.latitude, x.location.longitude) < 0.7 && (x.businessStatus ?? "OPERATIONAL") === "OPERATIONAL" && (wi || x.photos?.length));
      if (!p) { await sb.from("gems").update({ matched: false }).eq("id", g.id); return; }
      let image: string | null = wi?.url ?? null;
      if (!image) try { const pr = await fetch(`https://places.googleapis.com/v1/${p.photos[0].name}/media?maxWidthPx=900&skipHttpRedirect=true`, { headers: { "X-Goog-Api-Key": key } }); const pd = await pr.json(); image = pr.ok ? (pd.photoUri ?? null) : null; } catch (_) { /* no photo */ }
      // the country is the last part of Google's full address; a home deck only takes places in its own country
      const country = String(p.formattedAddress ?? "").split(",").pop()?.trim().slice(0, 40) || null;
      await sb.from("gems").update({ matched: !!image, place_id: p.id, photo: wi ? null : p.photos?.[0]?.name ?? null, image, photo_credit: wi?.credit ?? null, hours: packHours(p.regularOpeningHours), maps: p.googleMapsUri ?? null, address: p.shortFormattedAddress ?? null, ptype: p.primaryType ?? null, country, lat: p.location.latitude, lng: p.location.longitude }).eq("id", g.id);
      if (image) ok++; if (wi) wiki++;
    } catch (_) { /* left for the next pass */ }
  }));
  return { stage: "match", n: gs.length, matched: ok, wiki };
}

Deno.serve(async (req: Request) => {
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle();
    if (!sec?.value || req.headers.get("x-sync-key") !== sec.value) return json({ error: "forbidden" }, 403);
    const body = await req.json().catch(() => ({}));
    const only = String(body?.stage ?? "");
    if (!only || only === "pick") {
      const { data: area } = await sb.from("gem_areas").select("*").eq("status", "new").order("created_at").limit(1).maybeSingle();
      if (area) return json(await stagePick(sb, area));
    }
    if (!only || only === "write") { const w = await stageWrite(sb); if (w) return json(w); }
    if (!only || only === "match") { const m = await stageMatch(sb); if (m) return json(m); }
    return json({ idle: true });
  } catch (e) { return json({ error: String(e) }, 500); }
});
