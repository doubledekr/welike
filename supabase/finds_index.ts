import { createClient } from "npm:@supabase/supabase-js@2";
import { logAi } from "./ai_log.ts";
logAi("finds");

// finds (Dave, 19 Nov, TRIAL): one discovery job for ANY town, city or place in the world. Claude reads the web with its
// search tool (search results only, no scraping; Reddit refuses Anthropic's crawler, so it is reached only through pages
// that quote it). Writes NOTHING to cards yet: it returns what it found.
//   sources:  the area's own event calendars, city and regional magazines, food and travel guides, newsletters, tourism
//             boards and community boards, so later runs know where to look first.
//   openings: restaurants, bars, cafes, bakeries and independent shops that opened in the last ~4 months (or open soon).
//   gems:     hidden gems and one-of-a-kind spots named by guides, magazines and local writers (complements the
//             Wikipedia-based gems job): odd museums, secret gardens, speakeasies, overlooks, makers, markets.
//   events:   one-off and offbeat events in the next 14 days, each with a date, start time, venue and a source.
// Places (openings, gems) are then matched to Google Places: must be open, 4.0+ stars once 10+ people rated it,
// with hours and one photo. Google calls are logged in google_calls and count against the daily guard.
// Body: { mode, place: "Lititz, Pennsylvania", city, region, country: "US", lat, lng, today: "YYYY-MM-DD", sites?: string[] }.
// Auth: x-sync-key.
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const apiKey = () => Deno.env.get("ANTHROPIC_API_KEY") ?? Deno.env.get("CLAUDE_API_KEY") ?? Deno.env.get("CLAUDE_KEY") ?? Deno.env.get("ANTHROPIC_KEY") ?? "";
const MODELS = [Deno.env.get("CLAUDE_FINDS_MODEL"), "claude-sonnet-5-5", "claude-sonnet-4-5"].filter(Boolean) as string[];
const DAILY_GUARD = 1500;

async function ask(prompt: string, loc: Record<string, string>, uses = 6): Promise<{ text: string | null; err: string; searches: number }> {
  const key = apiKey(); if (!key) return { text: null, err: "no key", searches: 0 };
  const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), 140000);
  let err = "";
  const ul: Record<string, string> = { type: "approximate" };
  for (const k of ["city", "region", "country"]) if (loc[k]) ul[k] = loc[k];
  const tool = { type: "web_search_20250305", name: "web_search", max_uses: uses, user_location: ul };
  try {
    for (const model of MODELS) {
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", signal: ctl.signal,
        headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" },
        body: JSON.stringify({ model, max_tokens: 9000, tools: [tool], messages: [{ role: "user", content: prompt }] }) });
      if (!r.ok) { const t = (await r.text()).slice(0, 300); err = `${model} ${r.status} ${t}`; if (r.status === 404 || (r.status === 400 && /model/i.test(t))) continue; return { text: null, err, searches: 0 }; }
      const d = await r.json();
      const blocks = (d.content ?? []) as any[];
      const text = blocks.filter((b) => b.type === "text").map((b) => b.text).join("").trim();   // cited answers come in many blocks; "" keeps the JSON whole
      return { text: text || null, err: text ? "" : `${model} empty (${d.stop_reason})`, searches: blocks.filter((b) => b.type === "server_tool_use").length };
    }
    return { text: null, err, searches: 0 };
  } catch (e) { return { text: null, err: String(e), searches: 0 }; } finally { clearTimeout(timer); }
}
function lastArray(t: string | null): any[] {
  if (!t) return []; const end = t.lastIndexOf("]");
  for (let s = t.indexOf("["); s >= 0 && s < end; s = t.indexOf("[", s + 1)) {
    try { const a = JSON.parse(t.slice(s, end + 1)); if (Array.isArray(a)) return a; } catch (_) { /* next */ }
  }
  return [];
}
const miles = (a: number, b: number, c: number, d: number) => { const r = (x: number) => x * Math.PI / 180, q = Math.sin(r(c - a) / 2) ** 2 + Math.cos(r(a)) * Math.cos(r(c)) * Math.sin(r(d - b) / 2) ** 2; return 3958.8 * 2 * Math.asin(Math.sqrt(q)); };

const RULES = `Use only what your sources say. Never guess a date, time, address or opening. Every item needs at least one source URL you actually read.
The "line" is shown to couples on a card: one sentence, at most 100 characters, saying what the place or event IS and why it is worth going, in plain warm words. Never tell the reader to check, confirm or call ahead, never mention your sources or the article, no superlatives you cannot back up, no prices unless a source gives them, no emoji, no exclamation marks.`;
const NEAR = (p: string) => `in or near ${p} (within about 30 miles / 50 km; include the nearby towns people from there actually go to)`;

function promptSources(p: string) {
  return `Find the best places to learn what is happening and what is worth visiting ${NEAR(p)}: local and regional event calendars, city or county magazines, alt-weeklies, newspapers' things-to-do pages, food and drink guides, travel and tourism boards, local newsletters and blogs, community calendars, markets' and venues' own listings, and the local Reddit communities (name them even if you cannot open them). Prefer sources that are current (updated in the last month) and specific to this area.
Use only what you find. After searching, end your answer with ONLY a JSON array (up to 15 items, short values):
[{"name":"...","url":"https://...","type":"Events calendar|Magazine|Newspaper|Food guide|Tourism|Newsletter|Blog|Community|Venue|Reddit","covers":"what it is good for, a few words","fresh":"how current it looked, a few words"}]`;
}
function promptOpenings(p: string, today: string) {
  return `Today is ${today}. Find restaurants, bars, cafes, bakeries, dessert shops and interesting independent shops (bookshops, record stores, vintage, makers, gift and design shops) that OPENED ${NEAR(p)} in roughly the last four months, or open in the next two weeks. Look at local news, food sites and magazines, the business's own site or social posts. Skip chains and franchises, ghost kitchens, food trucks with no fixed spot, and anything that has since closed.
${RULES}
After searching, end your answer with ONLY a JSON array (up to 12 items, short values):
[{"name":"...","kind":"Restaurant|Bar|Cafe|Bakery|Dessert|Shop","what":"cuisine or what they sell, a few words","opened":"YYYY-MM or YYYY-MM-DD","area":"neighbourhood or town","address":"street address if a source gives it","line":"...","sources":["url"]}]`;
}
function promptGems(p: string) {
  return `Find hidden gems and one-of-a-kind places ${NEAR(p)} that local magazines, guides, travel writers and locals recommend but most visitors miss: odd or tiny museums, secret gardens, overlooks, unusual architecture you can walk into, speakeasies and storied old bars or diners, distinctive markets, makers' workshops, curious shops, quirky roadside stops, scenic walks. Skip the famous attractions everyone already knows, chains, and anything closed.
${RULES}
After searching, end your answer with ONLY a JSON array (up to 12 items, short values):
[{"name":"...","kind":"two or three word type, e.g. Odd museum","area":"neighbourhood or town","address":"if a source gives it","line":"...","score":1-10 for how surprising and worth the trip,"sources":["url"]}]`;
}
function promptEvents(p: string, today: string, sites: string[]) {
  return `Today is ${today}. Find one-off and offbeat things to do ${NEAR(p)} in the next 14 days that a couple would not find on a big ticketing site: food and drink pop-ups, cook-offs, tastings, supper clubs, night and holiday markets, maker and craft fairs, oddities or vintage expos, small art openings, unusual workshops, farm and orchard events, small-town festivals. Skip big concerts, sports, chain promotions, recurring weekly bar trivia, and anything already over.
${sites.length ? `Start with these local sources: ${sites.slice(0, 8).join(", ")}. Then look wider: venue sites and their social posts, local news, community calendars, Eventbrite.` : `Look at the area's event calendars, local magazines and news, venue sites and their social posts, community calendars and Eventbrite.`}
${RULES} An event needs a date, a start time and a venue; leave it out if any is missing.
After searching, end your answer with ONLY a JSON array (up to 12 items, short values):
[{"title":"...","kind":"Food|Drink|Market|Art|Workshop|Festival|Outdoors|Odd","date":"YYYY-MM-DD","time":"7:00 PM","end":"10:00 PM or empty","venue":"...","address":"...","price":"if a source gives it, else empty","line":"...","sources":["url"]}]`;
}

Deno.serve(async (req: Request) => {
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle();
    if (!sec?.value || req.headers.get("x-sync-key") !== sec.value) return json({ error: "forbidden" }, 403);
    const a = await req.json().catch(() => ({}));
    const mode = String(a.mode ?? "");
    const loc = { city: String(a.city ?? ""), region: String(a.region ?? ""), country: String(a.country ?? "").toUpperCase().slice(0, 2) };
    const place = String(a.place ?? [loc.city, loc.region].filter(Boolean).join(", "));
    const today = String(a.today ?? new Date().toISOString().slice(0, 10));
    const lat = Number(a.lat), lng = Number(a.lng), sites = Array.isArray(a.sites) ? a.sites.map(String) : [];
    if (mode === "reddit") return json({ ok: false, mode, reason: "reddit_blocks_search" });
    if (!place || !["sources", "openings", "gems", "events"].includes(mode)) return json({ ok: false, reason: "bad_args" });
    const t0 = Date.now();

    if (mode === "sources") {
      const r = await ask(promptSources(place), loc, 7);
      const items = lastArray(r.text).filter((x) => x?.name && /^https?:\/\//.test(String(x?.url ?? "")));
      return json({ ok: true, mode, place, searches: r.searches, ms: Date.now() - t0, err: r.err || undefined, found: items.length, items, raw_tail: items.length ? undefined : (r.text ?? "").slice(-600) });
    }
    if (mode === "events") {
      const r = await ask(promptEvents(place, today, sites), loc);
      const items = lastArray(r.text).filter((x) => x?.title && x?.date && x?.time && x?.venue && Array.isArray(x?.sources) && x.sources.length && x.date >= today);
      return json({ ok: true, mode, place, searches: r.searches, ms: Date.now() - t0, err: r.err || undefined, found: items.length, items, raw_tail: items.length ? undefined : (r.text ?? "").slice(-600) });
    }

    // openings and gems: then confirm each on Google Places
    const r = await ask(mode === "gems" ? promptGems(place) : promptOpenings(place, today), loc);
    const items = lastArray(r.text).filter((x) => x?.name && Array.isArray(x?.sources) && x.sources.length);
    const gkey = Deno.env.get("GOOGLE_PLACES_KEY") ?? "";
    const { count } = await sb.from("google_calls").select("id", { count: "exact", head: true }).gte("at", new Date(Date.now() - 864e5).toISOString());
    let left = DAILY_GUARD - (count ?? 0), gcalls = 0;
    const log = async (sku: string, ok: boolean, note: string) => { left--; gcalls++; await sb.from("google_calls").insert({ api: "places", sku, ok, note: ("finds " + note).slice(0, 200) }); };
    const n = (s: string) => s.toLowerCase().normalize("NFD").replace(/[^a-z0-9]/g, "");
    for (const x of items) {
      if (!gkey || left <= 0) { x.google = "skipped"; continue; }
      try {
        const body: Record<string, unknown> = { textQuery: `${x.name} ${x.address || x.area || place}`, pageSize: 3 };
        if (Number.isFinite(lat) && Number.isFinite(lng)) body.locationBias = { circle: { center: { latitude: lat, longitude: lng }, radius: 50000 } };
        const g = await fetch("https://places.googleapis.com/v1/places:searchText", { method: "POST",
          headers: { "Content-Type": "application/json", "X-Goog-Api-Key": gkey,
            "X-Goog-FieldMask": "places.id,places.displayName,places.location,places.shortFormattedAddress,places.businessStatus,places.rating,places.userRatingCount,places.primaryType,places.googleMapsUri,places.photos,places.regularOpeningHours" },
          body: JSON.stringify(body) });
        const d = await g.json().catch(() => null); await log("Text Search Enterprise", g.ok, `${mode} ${x.name}`);
        const p = ((d?.places ?? []) as any[]).find((q) => { const a1 = n(q.displayName?.text ?? ""), b1 = n(x.name); return a1 && b1 && (a1.includes(b1.slice(0, 8)) || b1.includes(a1.slice(0, 8))); });
        if (!p) { x.google = "not_found"; continue; }
        x.google = p.businessStatus ?? "OPERATIONAL"; x.place_id = p.id; x.g_name = p.displayName?.text; x.g_address = p.shortFormattedAddress;
        x.rating = p.rating ?? null; x.ratings = p.userRatingCount ?? 0; x.ptype = p.primaryType ?? null; x.maps = p.googleMapsUri ?? null; x.has_hours = !!p.regularOpeningHours;
        if (p.location && Number.isFinite(lat)) x.miles = Math.round(miles(lat, lng, p.location.latitude, p.location.longitude) * 10) / 10;
        x.keep = x.google === "OPERATIONAL" && !(x.ratings >= 10 && Number(x.rating) < 4) && (x.miles ?? 0) <= 35;
        if (x.keep && p.photos?.[0]?.name && left > 0) {
          const ph = await fetch(`https://places.googleapis.com/v1/${p.photos[0].name}/media?maxWidthPx=600&skipHttpRedirect=true`, { headers: { "X-Goog-Api-Key": gkey } });
          const pd = await ph.json().catch(() => null); await log("Place Photos", ph.ok, "photo"); if (ph.ok) x.image = pd?.photoUri ?? null;
        }
      } catch (_) { x.google = "error"; }
    }
    return json({ ok: true, mode, place, searches: r.searches, google_calls: gcalls, ms: Date.now() - t0, err: r.err || undefined, found: items.length,
      kept: items.filter((x) => x.keep).length, items, raw_tail: items.length ? undefined : (r.text ?? "").slice(-600) });
  } catch (e) { return json({ ok: false, reason: "error", detail: String(e).slice(0, 200) }); }
});
