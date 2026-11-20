import { createClient } from "npm:@supabase/supabase-js@2";
import { logAi } from "./ai_log.ts";
logAi("finds");

// finds (Dave, 19 Nov, TRIAL): looks for things the other jobs miss, around one home area.
//   openings: restaurants, bars, cafes, bakeries and independent shops that opened in the last few months, from local
//             news, food sites and city Reddit communities; each one is then matched to Google Places (open now, rating,
//             hours, one photo) so nothing closed or made up gets through.
//   events:   one-off and offbeat local events in the next two weeks (pop-ups, cook-offs, tastings, night markets, maker
//             fairs, oddities expos, supper clubs), each with a date, start time, venue and at least one source.
//   reddit:   the same event search limited to reddit.com, to see what the city's subreddits add on their own.
// Claude does the reading with its web search tool (search results only, no scraping). Writes NOTHING to cards yet:
// it returns what it found. Google calls are logged in google_calls and count against the daily guard.
// Body: { mode: "openings" | "events" | "reddit", city, region, lat, lng, today: "YYYY-MM-DD" }. Auth: x-sync-key.
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const apiKey = () => Deno.env.get("ANTHROPIC_API_KEY") ?? Deno.env.get("CLAUDE_API_KEY") ?? Deno.env.get("CLAUDE_KEY") ?? Deno.env.get("ANTHROPIC_KEY") ?? "";
const MODELS = [Deno.env.get("CLAUDE_FINDS_MODEL"), "claude-sonnet-5-5", "claude-sonnet-4-5"].filter(Boolean) as string[];
const DAILY_GUARD = 1500;

async function ask(prompt: string, city: string, region: string, domains?: string[]): Promise<{ text: string | null; err: string; searches: number }> {
  const key = apiKey(); if (!key) return { text: null, err: "no key", searches: 0 };
  const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), 140000);
  let err = "";
  const tool: Record<string, unknown> = { type: "web_search_20250305", name: "web_search", max_uses: 6,
    user_location: { type: "approximate", city, region, country: "US" } };
  if (domains) tool.allowed_domains = domains;
  try {
    for (const model of MODELS) {
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", signal: ctl.signal,
        headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" },
        body: JSON.stringify({ model, max_tokens: 9000, tools: [tool], messages: [{ role: "user", content: prompt }] }) });
      if (!r.ok) { const t = (await r.text()).slice(0, 300); err = `${model} ${r.status} ${t}`; if (r.status === 404 || (r.status === 400 && /model/i.test(t))) continue; return { text: null, err, searches: 0 }; }
      const d = await r.json();
      const blocks = (d.content ?? []) as any[];
      const text = blocks.filter((b) => b.type === "text").map((b) => b.text).join("").trim();   // cited answers come in many text blocks; joining with "" keeps the JSON whole
      return { text: text || null, err: text ? "" : `${model} empty (${d.stop_reason})`, searches: blocks.filter((b) => b.type === "server_tool_use").length };
    }
    return { text: null, err, searches: 0 };
  } catch (e) { return { text: null, err: String(e), searches: 0 }; } finally { clearTimeout(timer); }
}
// the answer ends with a JSON array; take the widest piece that parses
function lastArray(t: string | null): any[] {
  if (!t) return []; const end = t.lastIndexOf("]");
  for (let s = t.indexOf("["); s >= 0 && s < end; s = t.indexOf("[", s + 1)) {
    try { const a = JSON.parse(t.slice(s, end + 1)); if (Array.isArray(a)) return a; } catch (_) { /* next */ }
  }
  return [];
}
const miles = (a: number, b: number, c: number, d: number) => { const r = (x: number) => x * Math.PI / 180, q = Math.sin(r(c - a) / 2) ** 2 + Math.cos(r(a)) * Math.cos(r(c)) * Math.sin(r(d - b) / 2) ** 2; return 3958.8 * 2 * Math.asin(Math.sqrt(q)); };

const RULES = `Use only what your sources say. Never guess a date, time, address or opening. No superlatives you cannot back up, no prices unless a source gives them, no emoji, no exclamation marks. Every item needs at least one source URL you actually read.`;

function promptOpenings(city: string, region: string, today: string) {
  return `Today is ${today}. Find restaurants, bars, cafes, bakeries, dessert shops and interesting independent shops (bookshops, record stores, vintage, makers, gift and design shops) that OPENED in or near ${city}, ${region} in roughly the last four months, or open in the next two weeks. Look at local news, city food sites and magazines, the business's own site or social posts, and the city's Reddit communities. Skip chains and franchises, ghost kitchens, food trucks with no fixed spot, and anything that has since closed.\n${RULES}\nAfter searching, end your answer with ONLY a JSON array (up to 12 items, short values):\n[{"name":"...","kind":"Restaurant|Bar|Cafe|Bakery|Dessert|Shop","what":"cuisine or what they sell, a few words","opened":"YYYY-MM or YYYY-MM-DD","area":"neighbourhood or town","address":"street address if a source gives it","line":"one sentence, at most 100 characters, why a couple would go","sources":["url", "..."]}]`;
}
function promptEvents(city: string, region: string, today: string, reddit: boolean) {
  return `Today is ${today}. Find one-off and offbeat things to do in or near ${city}, ${region} in the next 14 days that a couple would not find on Ticketmaster: food and drink pop-ups, cook-offs, tastings, supper clubs, night and holiday markets, maker and craft fairs, oddities or vintage expos, small art openings, unusual workshops, neighbourhood festivals. Skip big concerts, sports, chain promotions, recurring weekly bar trivia, and anything already over.\n` +
    (reddit ? `Search ONLY reddit.com: find the subreddits for this city and its suburbs and look at their recent event posts, weekend threads and announcements.\n` : `Look at venue sites and their social posts, local news and city magazines, community calendars, Eventbrite, and the city's Reddit communities.\n`) +
    `${RULES} An event needs a date, a start time and a venue; leave it out if any is missing.\nAfter searching, end your answer with ONLY a JSON array (up to 12 items, short values):\n[{"title":"...","kind":"Food|Drink|Market|Art|Workshop|Festival|Odd","date":"YYYY-MM-DD","time":"7:00 PM","end":"10:00 PM or empty","venue":"...","address":"...","price":"if a source gives it, else empty","line":"one sentence, at most 100 characters","sources":["url", "..."]}]`;
}

Deno.serve(async (req: Request) => {
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle();
    if (!sec?.value || req.headers.get("x-sync-key") !== sec.value) return json({ error: "forbidden" }, 403);
    const a = await req.json().catch(() => ({}));
    const mode = String(a.mode ?? ""), city = String(a.city ?? ""), region = String(a.region ?? ""), today = String(a.today ?? new Date().toISOString().slice(0, 10));
    const lat = Number(a.lat), lng = Number(a.lng);
    if (!city || !["openings", "events", "reddit"].includes(mode)) return json({ ok: false, reason: "bad_args" });
    const t0 = Date.now();

    // Reddit refuses Anthropic's search crawler (checked 19 Nov: "domains are not accessible to our user agent"), so a
    // reddit-only search is not possible this way; the open-web search still sees pages that quote Reddit posts.
    if (mode === "reddit") return json({ ok: false, mode, reason: "reddit_blocks_search" });
    if (mode !== "openings") {
      const r = await ask(promptEvents(city, region, today, mode === "reddit"), city, region, mode === "reddit" ? ["reddit.com"] : undefined);
      const items = lastArray(r.text).filter((x) => x?.title && x?.date && x?.time && x?.venue && Array.isArray(x?.sources) && x.sources.length)
        .filter((x) => x.date >= today);
      return json({ ok: true, mode, city, searches: r.searches, ms: Date.now() - t0, err: r.err || undefined, found: items.length, items, raw_tail: items.length ? undefined : (r.text ?? "").slice(-600) });
    }

    // openings: then confirm each on Google Places (open, where, rating, hours, one photo)
    const r = await ask(promptOpenings(city, region, today), city, region);
    const items = lastArray(r.text).filter((x) => x?.name && Array.isArray(x?.sources) && x.sources.length);
    const gkey = Deno.env.get("GOOGLE_PLACES_KEY") ?? "";
    const { count } = await sb.from("google_calls").select("id", { count: "exact", head: true }).gte("at", new Date(Date.now() - 864e5).toISOString());
    let left = DAILY_GUARD - (count ?? 0), gcalls = 0;
    const log = async (sku: string, ok: boolean, note: string) => { left--; gcalls++; await sb.from("google_calls").insert({ api: "places", sku, ok, note: ("finds " + note).slice(0, 200) }); };
    for (const x of items) {
      if (!gkey || left <= 0) { x.google = "skipped"; continue; }
      try {
        const body: Record<string, unknown> = { textQuery: `${x.name} ${x.address || x.area || city}`, pageSize: 3 };
        if (Number.isFinite(lat) && Number.isFinite(lng)) body.locationBias = { circle: { center: { latitude: lat, longitude: lng }, radius: 40000 } };
        const g = await fetch("https://places.googleapis.com/v1/places:searchText", { method: "POST",
          headers: { "Content-Type": "application/json", "X-Goog-Api-Key": gkey,
            "X-Goog-FieldMask": "places.id,places.displayName,places.location,places.shortFormattedAddress,places.businessStatus,places.rating,places.userRatingCount,places.primaryType,places.googleMapsUri,places.photos,places.regularOpeningHours" },
          body: JSON.stringify(body) });
        const d = await g.json().catch(() => null); await log("Text Search Enterprise", g.ok, x.name);
        const n = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
        const p = ((d?.places ?? []) as any[]).find((q) => n(q.displayName?.text ?? "").includes(n(x.name).slice(0, 8)) || n(x.name).includes(n(q.displayName?.text ?? "").slice(0, 8)));
        if (!p) { x.google = "not_found"; continue; }
        x.google = p.businessStatus ?? "OPERATIONAL"; x.place_id = p.id; x.g_name = p.displayName?.text; x.g_address = p.shortFormattedAddress;
        x.rating = p.rating ?? null; x.ratings = p.userRatingCount ?? 0; x.ptype = p.primaryType ?? null; x.maps = p.googleMapsUri ?? null; x.has_hours = !!p.regularOpeningHours;
        if (p.location && Number.isFinite(lat)) x.miles = Math.round(miles(lat, lng, p.location.latitude, p.location.longitude) * 10) / 10;
        if (p.photos?.[0]?.name && left > 0 && x.google === "OPERATIONAL") {
          const ph = await fetch(`https://places.googleapis.com/v1/${p.photos[0].name}/media?maxWidthPx=600&skipHttpRedirect=true`, { headers: { "X-Goog-Api-Key": gkey } });
          const pd = await ph.json().catch(() => null); await log("Place Photos", ph.ok, "photo"); if (ph.ok) x.image = pd?.photoUri ?? null;
        }
      } catch (_) { x.google = "error"; }
    }
    return json({ ok: true, mode, city, searches: r.searches, google_calls: gcalls, ms: Date.now() - t0, err: r.err || undefined, found: items.length,
      open_on_google: items.filter((x) => x.google === "OPERATIONAL").length, items, raw_tail: items.length ? undefined : (r.text ?? "").slice(-600) });
  } catch (e) { return json({ ok: false, reason: "error", detail: String(e).slice(0, 200) }); }
});
