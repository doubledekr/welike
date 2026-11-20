import { createClient } from "npm:@supabase/supabase-js@2";

// Unique spots (Discover package, 19 Nov 2026): independent, interesting places near where couples live, or in a city
// they've booked a trip to. Magic shops, oddities, bookshops, confectioners, record stores, vintage, makers' shops.
//   1. Google Places Text Search around the point for a fixed list of kinds (one call per kind, 20 results each).
//   2. Drop anything closed, thinly reviewed or poorly rated, the wrong kind of place (restaurants, bars, groceries,
//      services), a known chain, or a name found at two or more addresses in this search or three in the table.
//   3. A small AI check of the rest: keep only independent places a couple would enjoy browsing together, give each a
//      short kind label and one line. The line may only say what the Google summary or the reviews support.
//   4. One Google photo per kept spot. Everything goes in the spots table, shared by every couple near it.
//      Home areas are dealt into decks by _spots_deal. With trip: <city>, kept spots also become shared Trips cards.
// Body: { lat, lng, area?, trip?: city, force?: true, dry?: true }. Auth: x-sync-key. Every Google call is logged in
// google_calls and counts against the same 1,500-a-day guard as geo. The keys never leave this function.
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const apiKey = () => Deno.env.get("ANTHROPIC_API_KEY") ?? Deno.env.get("CLAUDE_API_KEY") ?? Deno.env.get("CLAUDE_KEY") ?? Deno.env.get("ANTHROPIC_KEY") ?? "";
const DAILY_GUARD = 1500, RADIUS_M = 16000, FRESH_DAYS = 60;
const QUERIES = ["magic shop", "oddities and curiosities shop", "independent bookstore", "candy shop", "chocolate shop", "independent bakery",
  "record store", "vintage shop", "antique shop", "toy store", "independent gift shop", "plant shop", "stationery and paper shop",
  "cheese shop", "spice shop", "makers market",
  // home goods and design (Dave, 19 Nov: places like Nest and Shinola)
  "home goods boutique", "design shop", "locally made goods store", "leather goods store"];
const NOT_TYPES = new Set(["restaurant", "fast_food_restaurant", "bar", "night_club", "meal_takeaway", "meal_delivery", "supermarket", "grocery_store",
  "convenience_store", "gas_station", "pharmacy", "drugstore", "department_store", "shopping_mall", "warehouse_store", "discount_store",
  "hotel", "lodging", "car_dealer", "car_repair", "bank", "atm", "doctor", "dentist", "hospital", "school", "storage", "moving_company",
  "wholesaler", "liquor_store", "cell_phone_store", "electronics_store", "hardware_store", "home_improvement_store", "furniture_store", "pet_store", "real_estate_agency"]);
// big national and regional brands; local-born brands (Shinola, Sanders) are left to the AI check
const CHAINS = /\b(barnes\s*&?\s*noble|half price books|books-a-million|starbucks|dunkin|panera|tim hortons|krispy kreme|crumbl|nothing bundt|insomnia cookies|great american cookie|cinnabon|auntie anne|paris baguette|85°?c|tous les jours|sweet frog|menchie|lush|bath\s*&\s*body|yankee candle|see'?s candies|lindt|godiva|ghirardelli|rocky mountain chocolate|hallmark|party city|michaels|hobby lobby|joann|spencer|hot topic|five below|dollar|target|walmart|costco|kroger|meijer|whole foods|trader joe|cvs|walgreens|goodwill|salvation army|savers|value village|plato'?s closet|uptown cheapskate|once upon a child|kid to kid|lego store|build-a-bear|gamestop|funko|ulta|sephora|bed bath|homegoods|tj ?maxx|marshalls|ross|kirkland|pier 1|world market|urban outfitters|anthropologie|free people|apple store|t-mobile|verizon|at&t|tuesday morning|big lots|wonder ?works|sugar factory|it'?sugar|ice cream factory)\b/i;
// names come as the shop writes them; emoji are dropped ("Sideshow Books 📚" -> "Sideshow Books")
const clean = (s: string) => s.replace(/[\p{Extended_Pictographic}\uFE0F\u200D]+/gu, "").replace(/\s+/g, " ").trim();
const norm = (s: string) => s.toLowerCase().replace(/&/g, "and").replace(/[^a-z0-9]+/g, " ").replace(/\b(the|llc|inc|co)\b/g, "").replace(/\s+/g, " ").trim();
const miles = (a: number, b: number, c: number, d: number) => { const r = (x: number) => x * Math.PI / 180, q = Math.sin(r(c - a) / 2) ** 2 + Math.cos(r(a)) * Math.cos(r(c)) * Math.sin(r(d - b) / 2) ** 2; return 3958.8 * 2 * Math.asin(Math.sqrt(q)); };
function packHours(h: any): unknown {
  const ps = h?.periods; if (!Array.isArray(ps) || !ps.length) return null;
  if (ps.length === 1 && ps[0].open && !ps[0].close) return "always";
  const out: number[][] = [];
  for (const p of ps) { const o = p.open, c = p.close; if (!o || !c) continue; out.push([o.day ?? 0, (o.hour ?? 0) * 100 + (o.minute ?? 0), c.day ?? 0, (c.hour ?? 0) * 100 + (c.minute ?? 0)]); }
  return out.length ? out : null;
}
const areaOf = (p: any): string | null => { const cs = (p.addressComponents ?? []) as any[];
  for (const t of ["neighborhood", "sublocality_level_1", "sublocality", "locality"]) { const c = cs.find((x) => (x.types ?? []).includes(t)); if (c?.shortText || c?.longText) return c.shortText ?? c.longText; }
  return null; };
async function ask(prompt: string, max = 3500): Promise<string | null> {
  const key = apiKey(); if (!key) return null;
  for (const [model, off] of [["claude-haiku-5-5", true], ["claude-haiku-5-5", false], ["claude-haiku-4-5", false]] as [string, boolean][]) {
    try {
      const body: Record<string, unknown> = { model, max_tokens: off ? max : max + 2500, messages: [{ role: "user", content: prompt }] }; if (off) body.thinking = { type: "disabled" };
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" }, body: JSON.stringify(body) });
      if (!r.ok) continue;
      const d = await r.json(); const t = (d.content ?? []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("").trim(); if (t) return t;
    } catch (_) { /* next */ }
  }
  return null;
}
const KINDS = ["Home goods", "Design shop", "Magic shop", "Oddities", "Bookshop", "Candy shop", "Chocolatier", "Bakery", "Record store", "Vintage shop", "Antiques", "Toy shop",
  "Gift shop", "Plant shop", "Stationery", "Cheese shop", "Spice shop", "Makers' market", "Design shop", "Comic shop", "Game shop", "Craft shop"];

Deno.serve(async (req: Request) => {
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle();
    if (!sec?.value || req.headers.get("x-sync-key") !== sec.value) return json({ error: "forbidden" }, 403);
    const gkey = Deno.env.get("GOOGLE_PLACES_KEY") ?? ""; if (!gkey) return json({ ok: false, reason: "no_key" });
    if (!apiKey()) return json({ ok: false, reason: "no_ai_key" });
    const a = await req.json().catch(() => ({}));
    const lat = Number(a.lat), lng = Number(a.lng); if (!Number.isFinite(lat) || !Number.isFinite(lng)) return json({ ok: false, reason: "bad_point" });
    const trip = typeof a.trip === "string" && a.trip ? a.trip : null, dry = !!a.dry;

    // already searched here lately: nothing to do (trip cards are still made from what we hold)
    const { data: near } = await sb.from("spots").select("place_id,title,kind,line,area,lat,lng,address,maps,image,hours,rating,ratings,minutes,score,keep,created_at")
      .gte("lat", lat - 0.25).lte("lat", lat + 0.25).gte("lng", lng - 0.33).lte("lng", lng + 0.33);
    const fresh = ((near ?? []) as any[]).filter((s) => miles(lat, lng, s.lat, s.lng) <= 10 && Date.now() - Date.parse(s.created_at) < FRESH_DAYS * 864e5);
    let searched = false, calls = 0, cand = 0, kept: any[] = [];
    let left: number | null = null;
    const canCall = async () => { if (left === null) { const { count } = await sb.from("google_calls").select("id", { count: "exact", head: true }).gte("at", new Date(Date.now() - 864e5).toISOString()); left = DAILY_GUARD - (count ?? 0); } return left > 0; };
    const log = async (sku: string, ok: boolean, note: string) => { if (left !== null) left--; calls++; await sb.from("google_calls").insert({ api: "places", sku, ok, note: ("spots " + note).slice(0, 200) }); };

    if (a.force || fresh.length < 5) {
      searched = true;
      const seen = new Map<string, any>(); const names = new Map<string, Set<string>>();
      for (const q of QUERIES) {
        if (!(await canCall())) break;
        try {
          const r = await fetch("https://places.googleapis.com/v1/places:searchText", { method: "POST",
            headers: { "Content-Type": "application/json", "X-Goog-Api-Key": gkey,
              "X-Goog-FieldMask": "places.id,places.displayName,places.primaryType,places.types,places.location,places.formattedAddress,places.shortFormattedAddress,places.addressComponents,places.googleMapsUri,places.businessStatus,places.rating,places.userRatingCount,places.regularOpeningHours,places.photos,places.editorialSummary,places.reviews" },
            body: JSON.stringify({ textQuery: q, pageSize: 20, locationBias: { circle: { center: { latitude: lat, longitude: lng }, radius: RADIUS_M } } }) });
          const j = await r.json().catch(() => null);
          await log("Text Search Enterprise + Atmosphere", r.ok, r.ok ? q : `${q} ${r.status} ${String(j?.error?.message ?? "").slice(0, 120)}`);
          if (!r.ok) continue;
          for (const p of (j?.places ?? []) as any[]) {
            const nm = p.displayName?.text ?? ""; if (!nm || !p.location) continue;
            const k = norm(nm); if (!names.has(k)) names.set(k, new Set()); names.get(k)!.add(p.id);
            if (!seen.has(p.id)) seen.set(p.id, { ...p, q });
          }
        } catch (_) { /* next query */ }
      }
      // names we already hold at 3+ addresses anywhere count as a chain too
      const { data: allSpots } = await sb.from("spots").select("title");
      const held = new Map<string, number>(); for (const s of (allSpots ?? []) as any[]) { const k = norm(s.title); held.set(k, (held.get(k) ?? 0) + 1); }
      const pool = [...seen.values()].filter((p) => {
        const nm = p.displayName.text, k = norm(nm);
        if (p.businessStatus && p.businessStatus !== "OPERATIONAL") return false;
        if (miles(lat, lng, p.location.latitude, p.location.longitude) > 14) return false;
        if (!(Number(p.rating) >= 4.5) || !(Number(p.userRatingCount) >= 25) || Number(p.userRatingCount) > 6000) return false;
        if (NOT_TYPES.has(p.primaryType) || CHAINS.test(nm)) return false;
        if ((names.get(k)?.size ?? 0) >= 2 || (held.get(k) ?? 0) >= 3) return false;
        if (!packHours(p.regularOpeningHours)) return false;   // plans need hours
        return true;
      }).sort((x, y) => Number(y.userRatingCount) * Number(y.rating) - Number(x.userRatingCount) * Number(x.rating)).slice(0, 60);
      cand = pool.length;

      // the AI check, in batches of 20
      for (let i = 0; i < pool.length; i += 20) {
        const batch = pool.slice(i, i + 20);
        const lines = batch.map((p, n) => {
          const rv = ((p.reviews ?? []) as any[]).slice(0, 4).map((x) => String(x.text?.text ?? x.originalText?.text ?? "").replace(/\s+/g, " ").slice(0, 260)).filter(Boolean);
          return `[${n}] ${p.displayName.text} | Google type: ${p.primaryType ?? "?"} | ${p.shortFormattedAddress ?? p.formattedAddress ?? ""} | ${p.rating} stars, ${p.userRatingCount} reviews\n` +
            (p.editorialSummary?.text ? `  Google summary: ${p.editorialSummary.text}\n` : "") + rv.map((t) => `  Review: ${t}`).join("\n");
        }).join("\n\n");
        const out = await ask(`You pick "unique spots" for a couples' date app: independent, distinctive shops and places a couple would enjoy wandering into together, like a magic shop, an oddities shop, an indie bookshop, a confectioner, a record store, a vintage shop, a maker's shop. Not chains or franchises (a brand that started locally and still feels local is fine), not ordinary everyday stores, not services, not restaurants or bars, not wholesale.

For each place below decide:
- keep: true or false
- kind: one of ${KINDS.join(", ")}
- line: one sentence, at most 90 characters, saying what makes it worth a visit. Use ONLY what the Google summary or the reviews say. No made-up details, no prices, no "best in the city", no names of staff. Plain words, no exclamation marks, no emoji.
- minutes: how long a browse there usually takes, 20 to 60
- score: 1 to 10, how special it is for a couple (8+ only for something truly one of a kind)

Places:
${lines}

Answer with only a JSON array, one object per place: [{"i":0,"keep":true,"kind":"...","line":"...","minutes":30,"score":7}, ...]`);
        let arr: any[] = []; try { arr = JSON.parse((out ?? "").replace(/^[^\[]*/, "").replace(/[^\]]*$/, "")); } catch (_) { arr = []; }
        for (const v of arr) {
          const p = batch[Number(v?.i)]; if (!p || v.keep !== true) continue;
          const kind = KINDS.includes(v.kind) ? v.kind : null; const line = String(v.line ?? "").trim();
          if (!kind || !line || line.length > 110) continue;
          kept.push({ place_id: p.id, title: clean(p.displayName.text).slice(0, 80), kind, line, area: areaOf(p), lat: p.location.latitude, lng: p.location.longitude,
            address: p.shortFormattedAddress ?? p.formattedAddress ?? null, maps: p.googleMapsUri ?? null, hours: packHours(p.regularOpeningHours),
            rating: p.rating ?? null, ratings: p.userRatingCount ?? null, minutes: Math.min(60, Math.max(20, Math.round(Number(v.minutes) || 30))),
            score: Math.min(10, Math.max(1, Math.round(Number(v.score) || 6))), keep: true, _photo: p.photos?.[0]?.name ?? null });
        }
      }
      // one photo each; Google's link to the picture is kept
      for (const s of kept) {
        if (dry || !s._photo || !(await canCall())) continue;
        try {
          const r = await fetch(`https://places.googleapis.com/v1/${s._photo}/media?maxWidthPx=900&skipHttpRedirect=true`, { headers: { "X-Goog-Api-Key": gkey } });
          const d = await r.json().catch(() => null); await log("Place Photos", r.ok, "photo");
          if (r.ok && d?.photoUri) s.image = d.photoUri;
        } catch (_) { /* no photo */ }
      }
      kept = kept.map(({ _photo, ...s }) => s);
      if (!dry && kept.length) await sb.from("spots").upsert(kept, { onConflict: "place_id" });
    }

    // a booked trip: the kept spots around that city become shared Trips cards for it
    let tripCards = 0;
    if (trip && !dry) {
      const list = searched ? kept : fresh.filter((s) => s.keep);
      const ext = list.map((s) => "us:" + s.place_id);
      const { data: have } = ext.length ? await sb.from("cards").select("ext_id").eq("deck", "trip").is("couple_id", null).in("ext_id", ext) : { data: [] as any[] };
      const got = new Set(((have ?? []) as any[]).map((x) => x.ext_id));
      for (const s of list) {
        if (got.has("us:" + s.place_id)) continue;
        const { error } = await sb.from("cards").insert({ deck: "trip", kind: trip, title: s.title.slice(0, 60), subtitle: `${trip} · ${s.kind}`, image: s.image ?? null,
          ext_id: "us:" + s.place_id, created_by: "spots", active: true,
          data: Object.fromEntries(Object.entries({ unique: true, place: true, source: "spots", city: trip, notes: s.line, lat: s.lat, lng: s.lng, maps: s.maps,
            address: s.address, rating: s.rating, ratings: s.ratings, place_id: s.place_id, hours: s.hours, minutes: s.minutes, area: s.area }).filter(([, v]) => v != null)) });
        if (!error) tripCards++;
      }
    }
    return json({ ok: true, searched, google_calls: calls, candidates: cand, kept: kept.length, held_near: fresh.length, trip_cards: tripCards,
      ...(dry ? { sample: kept.slice(0, 12).map((s) => ({ title: s.title, kind: s.kind, line: s.line, area: s.area, score: s.score })) } : {}) });
  } catch (e) { return json({ ok: false, reason: "error", detail: String(e).slice(0, 200) }); }
});
