import { createClient } from "npm:@supabase/supabase-js@2";

// Google lookups for plans (Hamoody's feedback, 19 Nov 2026). Auth: the couple code must match a couple.
//   action "geocode": an address or place name typed by the person (their cottage, a friend's house) -> up to 3 matches
//                     with name, address and coordinates, so it can be saved as one of their places.
//   action "area":    (21 Nov) once per place away from home: good places within 25 miles saved as this couple's own cards.
//   action "route":   (27 Nov) a walking route from home to a place: map picture (data URL) and plain steps.
//   action "corner":  (27 Nov) open now within a 5 or 10 minute walk of home: drinks, snacks, things to do. Saves nothing.
//   action "quest":   a side quest between two stops: a short, well-rated stop (ice cream, coffee, a bookshop, a park,
//                     a view) close to the walk or drive from A to B, open at that time. Returns up to 3; saves nothing.
//                     With snack:true it's a snack break near A instead (coffee, a bakery, dessert): up to 8 within
//                     about 15 minutes' walk, closest first, for a long gap after a stop that isn't food.
// The Google key never leaves the backend. Each call is logged in google_calls like the other place lookups.
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const SNACK = ["ice_cream_shop", "dessert_shop", "coffee_shop", "bakery", "chocolate_shop", "cafe", "tea_house", "donut_shop", "juice_shop", "confectionery"];
// gap fillers by kind (Dave, 21 Nov): a snack, a drink, a bite, or something fun to walk around (alleys, murals, a plaza)
const KINDS: Record<string, string[]> = {
  drinks: ["bar", "pub", "wine_bar", "brewery", "cocktail_bar"],
  food: ["restaurant"],
  fun: ["tourist_attraction", "art_gallery", "plaza", "park", "book_store", "historical_landmark", "market", "gift_shop", "monument"],
};
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
      const kind = KINDS[String(b.kind ?? "")] ? String(b.kind) : "", snack = b.snack === true || b.kind === "snack", near = snack || !!kind;
      const radius = near ? 1200 : Math.round(Math.min(Math.max(leg * 0.6, 0.35), 3) * 1609.344);
      const r = await fetch("https://places.googleapis.com/v1/places:searchNearby", { method: "POST",
        headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key, "X-Goog-FieldMask": "places.id,places.displayName,places.primaryTypeDisplayName,places.primaryType,places.location,places.rating,places.userRatingCount,places.regularOpeningHours,places.photos,places.googleMapsUri,places.shortFormattedAddress,places.websiteUri" },
        body: JSON.stringify({ includedTypes: snack ? SNACK : kind ? KINDS[kind] : QUEST, maxResultCount: 20, rankPreference: "POPULARITY", locationRestriction: { circle: { center: { latitude: near ? a[0] : mid[0], longitude: near ? a[1] : mid[1] }, radius } } }) });
      const d = await r.json(); log(snack ? "whereis_snack" : kind ? "whereis_" + kind : "whereis_quest");
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
      }).filter((p: any) => p.name && p.lat != null && miles(a[0], a[1], p.lat, p.lng) > 0.06 && (near || miles(z[0], z[1], p.lat, p.lng) > 0.06) && !/museum|stadium|casino|amusement|lodging|hotel/.test(String(p.ptype ?? "")) && p.open !== false
          && (p.rating ?? 0) >= (kind ? 4.3 : 4.4) && (p.ratings ?? 0) >= (kind ? 30 : 40)
          && (kind !== "drinks" || /bar|pub|brew|wine|cocktail|lounge|tavern|beer|distill/.test(String(p.ptype ?? "")))
          && (snack ? p.dist <= 0.75 && SNACK.includes(String(p.ptype ?? "")) : kind ? p.dist <= 0.75 : p.detour <= Math.max(0.4, leg * 0.35)))
        .sort((x: any, y: any) => near ? (x.dist - y.dist) : (x.detour - y.detour) || ((y.rating ?? 0) - (x.rating ?? 0))).slice(0, near ? 8 : 3);
      // something fun: the couple's own hidden gems and unique spots close by come first (alleys, murals, odd little places)
      if (kind === "fun") {
        const { data: own } = await sb.from("cards").select("id,title,image,data").eq("couple_id", couple.id).eq("active", true).or("data->>gem.eq.true,data->>unique.eq.true").limit(300);
        const mine = ((own ?? []) as any[]).filter((c: any) => c.data?.lat != null && miles(a[0], a[1], Number(c.data.lat), Number(c.data.lng)) <= 0.75)
          .map((c: any) => ({ id: "card:" + c.id, card: c.id, name: c.title, type: c.data?.gem ? "Hidden gem" : "Unique spot", ptype: c.data?.ptype ?? null, lat: Number(c.data.lat), lng: Number(c.data.lng), rating: c.data?.rating ?? null, image: c.image ?? null,
            address: c.data?.address ?? null, maps: c.data?.maps ?? null, url: c.data?.url ?? null, dist: Math.round(miles(a[0], a[1], Number(c.data.lat), Number(c.data.lng)) * 100) / 100, open: null, gem: true }));
        out.unshift(...mine.slice(0, 4)); out.splice(8);
      }
      // a photo for each, so the suggestion looks like somewhere you'd want to stop
      await Promise.all(out.map(async (p: any) => { if (!p.photo || p.image) return; try { const pr = await fetch(`https://places.googleapis.com/v1/${p.photo}/media?maxWidthPx=600&skipHttpRedirect=true`, { headers: { "X-Goog-Api-Key": key } }); const pd = await pr.json(); p.image = pr.ok ? pd.photoUri ?? null : null; } catch (_) { p.image = null; } }));
      return json({ leg: Math.round(leg * 100) / 100, quests: out });
    }
    if (b.action === "route") {
      // 27 Nov, Dave: directions in the app. A walking route from home (or from/to given) as a map picture and plain steps.
      // Routes API for the path and steps, Static Maps for the picture, fetched here so the key never reaches the phone.
      const st = couple.settings ?? {}, to = [Number(b.lat), Number(b.lng)];
      const from = isFinite(Number(b.flat)) && b.flat != null ? [Number(b.flat), Number(b.flng)] : [Number(st.lat), Number(st.lng)];
      if (![...to, ...from].every(isFinite)) return json({ error: "bad_location" }, 400);
      const r = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", { method: "POST",
        headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key, "X-Goog-FieldMask": "routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline,routes.legs.steps.navigationInstruction,routes.legs.steps.distanceMeters,routes.legs.steps.staticDuration" },
        body: JSON.stringify({ origin: { location: { latLng: { latitude: from[0], longitude: from[1] } } }, destination: { location: { latLng: { latitude: to[0], longitude: to[1] } } }, travelMode: "WALK", units: "IMPERIAL" }) });
      const d = await r.json(); log("whereis_route");
      if (!r.ok || !d.routes?.[0]) return json({ error: "google", detail: d?.error?.message ?? r.status }, 502);
      const rt = d.routes[0], poly = rt.polyline?.encodedPolyline ?? "";
      const steps = ((rt.legs?.[0]?.steps ?? []) as any[]).map((x: any) => ({ text: x.navigationInstruction?.instructions ?? "", m: x.distanceMeters ?? 0, s: parseInt(String(x.staticDuration ?? "0")) || 0 })).filter((x: any) => x.text);
      // the picture: dark map, route in the app's coral, home and the place marked
      const style = ["element:geometry|color:0x1d1b22", "element:labels.text.fill|color:0x9b96a6", "element:labels.text.stroke|color:0x1d1b22", "feature:road|element:geometry|color:0x2e2b36", "feature:road.arterial|element:geometry|color:0x37333f", "feature:water|element:geometry|color:0x10141c", "feature:poi|element:geometry|color:0x24222a", "feature:transit|visibility:off"].map((x) => "&style=" + encodeURIComponent(x)).join("");
      const url = `https://maps.googleapis.com/maps/api/staticmap?size=600x360&scale=2&format=png${style}&path=${encodeURIComponent("weight:6|color:0xff6b6bff|enc:" + poly)}&markers=${encodeURIComponent(`size:small|color:0xf4efe9|${from[0]},${from[1]}`)}&markers=${encodeURIComponent(`color:0xff5a6e|${to[0]},${to[1]}`)}&key=${key}`;
      let img: string | null = null, imgerr: string | null = null;
      try { const m = await fetch(url); log("whereis_staticmap"); if (!m.ok) imgerr = m.status + " " + (await m.text()).slice(0, 160); if (m.ok) { const buf = new Uint8Array(await m.arrayBuffer()); let bin = ""; for (let i = 0; i < buf.length; i += 8192) bin += String.fromCharCode(...buf.subarray(i, i + 8192)); img = "data:image/png;base64," + btoa(bin); } } catch (e) { img = null; imgerr = String(e).slice(0, 160); }
      return json({ mins: Math.max(1, Math.round((parseInt(String(rt.duration ?? "0")) || 0) / 60)), meters: rt.distanceMeters ?? null, steps, img, imgerr });
    }
    if (b.action === "corner") {
      // 27 Nov, Dave: "days where we want to wander without a plan but want to make sure there are places really close".
      // Open now, within a 5 (or 10) minute walk of home (or of lat/lng if given): drinks, snacks, and things to do. Saves nothing.
      const st = couple.settings ?? {}, lat = isFinite(Number(b.lat)) && b.lat != null ? Number(b.lat) : Number(st.lat), lng = isFinite(Number(b.lng)) && b.lng != null ? Number(b.lng) : Number(st.lng);
      if (!isFinite(lat) || !isFinite(lng)) return json({ error: "no_home" }, 400);
      const mins = Number(b.mins) === 10 ? 10 : 5, radius = mins === 10 ? 800 : 420;
      const G: Record<string, string[][]> = {
        drinks: [["bar", "pub", "wine_bar", "brewery", "cocktail_bar", "beer_garden", "lounge_bar", "sports_bar", "irish_pub", "night_club"], ["bar", "pub", "wine_bar", "brewery", "cocktail_bar", "night_club"]],
        snacks: [["coffee_shop", "cafe", "bakery", "ice_cream_shop", "dessert_shop", "donut_shop", "tea_house", "juice_shop", "chocolate_shop", "sandwich_shop", "pizza_restaurant", "deli", "bagel_shop"], ["coffee_shop", "cafe", "bakery", "ice_cream_shop", "dessert_shop", "donut_shop", "tea_house", "juice_shop", "chocolate_shop", "pizza_restaurant"]],
        do: [["book_store", "art_gallery", "park", "museum", "plaza", "tourist_attraction", "historical_landmark", "market", "gift_shop", "bowling_alley", "video_arcade", "movie_theater", "comedy_club", "performing_arts_theater", "dog_park"], ["book_store", "art_gallery", "park", "museum", "plaza", "tourist_attraction", "historical_landmark", "market", "gift_shop", "bowling_alley", "movie_theater"]],
      };
      const fm = "places.id,places.displayName,places.primaryTypeDisplayName,places.primaryType,places.location,places.rating,places.userRatingCount,places.currentOpeningHours,places.photos,places.googleMapsUri,places.shortFormattedAddress,places.businessStatus,places.websiteUri";
      const now = Date.now(), out: Record<string, any[]> = {};
      await Promise.all(Object.entries(G).map(async ([k, lists]) => {
        let d: any = null;
        for (const types of lists) {
          const r = await fetch("https://places.googleapis.com/v1/places:searchNearby", { method: "POST", headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key, "X-Goog-FieldMask": fm },
            body: JSON.stringify({ includedTypes: types, maxResultCount: 20, rankPreference: "DISTANCE", locationRestriction: { circle: { center: { latitude: lat, longitude: lng }, radius } } }) });
          d = await r.json(); log("whereis_corner"); if (r.ok) break; d = null;
        }
        out[k] = ((d?.places ?? []) as any[]).filter((p: any) => p.location && p.displayName?.text && (p.businessStatus ?? "OPERATIONAL") === "OPERATIONAL" && p.currentOpeningHours?.openNow !== false && !/fast_food|gas_station|convenience|lodging|hotel/.test(String(p.primaryType ?? ""))
            && (k === "do" ? (p.userRatingCount ?? 0) >= 10 && (p.rating ?? 5) >= 4.0 : (p.userRatingCount ?? 0) >= 15 && (p.rating ?? 0) >= 4.0))
          .map((p: any) => { const m = miles(lat, lng, p.location.latitude, p.location.longitude) * 1609.344, nc = p.currentOpeningHours?.nextCloseTime;
            return { id: p.id, name: p.displayName.text, type: p.primaryTypeDisplayName?.text ?? null, ptype: p.primaryType ?? null, lat: p.location.latitude, lng: p.location.longitude,
              rating: p.rating ?? null, ratings: p.userRatingCount ?? null, maps: p.googleMapsUri ?? null, address: p.shortFormattedAddress ?? null, photo: p.photos?.[0]?.name ?? null, url: p.websiteUri ?? null,
              walk: Math.max(1, Math.round(m * 1.25 / 80)), closes: nc && Date.parse(nc) - now < 24 * 3600e3 ? nc : null, open: p.currentOpeningHours?.openNow ?? null }; })
          .filter((p: any) => p.walk <= mins + 1).sort((x: any, y: any) => x.walk - y.walk);
      }));
      const all = Object.values(out).flat(), { data: ch } = await sb.rpc("_chain_ids", { p_items: all.map((p: any) => ({ id: p.id, name: p.name, ptype: p.ptype })) }), chain = new Set((ch ?? []) as string[]);
      // drinks are real bars; a place shows in one group only (a bar first, then a snack spot, then things to do)
      const BARRE = /bar|pub|brew|wine|cocktail|lounge|tavern|beer|distill|night_club/, used = new Set<string>();
      out.drinks = (out.drinks ?? []).filter((p: any) => BARRE.test(String(p.ptype ?? "")));
      for (const k of ["drinks", "snacks", "do"]) out[k] = (out[k] ?? []).filter((p: any) => !chain.has(p.id) && !used.has(p.id) && (used.add(p.id), true)).slice(0, 10);
      await Promise.all(Object.values(out).flatMap((l) => l.slice(0, 5)).map(async (p: any) => { if (!p.photo) return; try { const pr = await fetch(`https://places.googleapis.com/v1/${p.photo}/media?maxWidthPx=400&skipHttpRedirect=true`, { headers: { "X-Goog-Api-Key": key } }); const pd = await pr.json(); p.image = pr.ok ? pd.photoUri ?? null : null; } catch (_) { p.image = null; } }));
      return json({ mins, home: !(isFinite(Number(b.lat)) && b.lat != null), groups: out });
    }
    if (b.action === "area") {
      // A place away from home (the cottage): once, pull good places around it into this couple's own cards, tagged
      // with the town (data.away) so they deal in rounds for that place and never in the usual home decks.
      const lat = Number(b.lat), lng = Number(b.lng), town = String(b.town ?? "").trim().slice(0, 60);
      if (!isFinite(lat) || !isFinite(lng) || !town) return json({ error: "bad_location" }, 400);
      const { count } = await sb.from("cards").select("id", { count: "exact", head: true }).eq("couple_id", couple.id).eq("data->>away", town).eq("created_by", "area");
      if ((count ?? 0) >= 12 && !b.more) return json({ ok: true, cached: true, n: count });
      const GROUPS: [string, string[]][] = [
        ["dinner", ["restaurant", "american_restaurant", "pizza_restaurant", "seafood_restaurant", "bar", "pub", "brewery", "winery"]],
        ["dinner", ["breakfast_restaurant", "brunch_restaurant", "cafe", "coffee_shop", "bakery", "ice_cream_shop"]],
        ["event", ["park", "state_park", "national_park", "beach", "hiking_area", "marina", "tourist_attraction", "farm", "garden"]],
        ["event", ["museum", "art_gallery", "book_store", "gift_shop", "bowling_alley", "movie_theater", "historical_landmark", "visitor_center"]],
      ];
      const isFood = (t: string) => /restaurant|cafe|coffee|bakery|ice_cream|bar|pub|brew|winery|food|diner|deli|bagel|sandwich|donut|dessert|pizza/.test(t), SKIP = /lodging|hotel|motel|resort|rv_park|(^|_)inn($|_)|fast_food|hospital|campground|cottage|bed_and_breakfast|grocery|supermarket|sports_complex|athletic|stadium|gas_station|convenience/;
      const fm = "places.id,places.displayName,places.primaryTypeDisplayName,places.primaryType,places.location,places.rating,places.userRatingCount,places.regularOpeningHours,places.photos,places.googleMapsUri,places.shortFormattedAddress,places.websiteUri,places.editorialSummary";
      const got: any[] = [];
      for (const [, types] of GROUPS) {
        const r = await fetch("https://places.googleapis.com/v1/places:searchNearby", { method: "POST", headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key, "X-Goog-FieldMask": fm },
          body: JSON.stringify({ includedTypes: types, maxResultCount: 20, rankPreference: "POPULARITY", locationRestriction: { circle: { center: { latitude: lat, longitude: lng }, radius: 40000 } } }) });
        const d = await r.json(); log("whereis_area"); if (r.ok) got.push(...(d.places ?? []));
      }
      const seen = new Set<string>(), hours = (h: any) => { const ps = h?.periods; if (!Array.isArray(ps) || !ps.length) return null; if (ps.length === 1 && ps[0].open && !ps[0].close) return "always";
        return ps.filter((p: any) => p.open && p.close).map((p: any) => [p.open.day, p.open.hour * 100 + (p.open.minute ?? 0), p.close.day, p.close.hour * 100 + (p.close.minute ?? 0)]); };
      const keep = got.filter((p: any) => { if (!p.id || seen.has(p.id) || !p.location || !p.displayName?.text) return false; seen.add(p.id); return !SKIP.test(String(p.primaryType ?? "")) && (p.rating ?? 0) >= 4.2 && (p.userRatingCount ?? 0) >= 25; }).slice(0, 48);
      await Promise.all(keep.map(async (p: any) => { const ph = p.photos?.[0]?.name; if (!ph) return; try { const pr = await fetch(`https://places.googleapis.com/v1/${ph}/media?maxWidthPx=800&skipHttpRedirect=true`, { headers: { "X-Goog-Api-Key": key } }); const pd = await pr.json(); p._img = pr.ok ? pd.photoUri ?? null : null; } catch (_) { p._img = null; } }));
      const rows = keep.map((p: any) => { const food = isFood(String(p.primaryType ?? "")), mi = Math.round(miles(lat, lng, p.location.latitude, p.location.longitude) * 10) / 10;
        return { couple_id: couple.id, deck: food ? "dinner" : "event", kind: p.primaryTypeDisplayName?.text ?? (food ? "Restaurant" : "Place"), title: p.displayName.text.slice(0, 80),
          subtitle: [p.primaryTypeDisplayName?.text, p.shortFormattedAddress].filter(Boolean).join(" · ").slice(0, 90), image: p._img ?? null, active: true, created_by: "area",
          ext_id: "g:" + p.id, event_date: food ? null : "2099-01-01",
          data: { place: true, place_id: p.id, lat: p.location.latitude, lng: p.location.longitude, ptype: p.primaryType ?? null, rating: p.rating ?? null, ratings: p.userRatingCount ?? null,
            hours: hours(p.regularOpeningHours), hours_at: new Date().toISOString().slice(0, 10), maps: p.googleMapsUri ?? null, url: p.websiteUri ?? null, address: p.shortFormattedAddress ?? null,
            notes: p.editorialSummary?.text ?? null, photo: p.photos?.[0]?.name ?? null, image_src: p._img ? "google" : null, away: town, area: String(b.place ?? ""), miles: mi, source: "area", dinner: food || undefined } }; });
      const { data: have } = await sb.from("cards").select("deck,ext_id").eq("couple_id", couple.id).in("ext_id", rows.map((r: any) => r.ext_id));
      const hk = new Set((have ?? []).map((h: any) => h.deck + "|" + h.ext_id)), fresh = rows.filter((r: any) => !hk.has(r.deck + "|" + r.ext_id));
      let n = 0; if (fresh.length) { const { error, count } = await sb.from("cards").insert(fresh, { count: "exact" }); if (error) return json({ error: "save", detail: error.message }, 500); n = count ?? fresh.length; }
      return json({ ok: true, found: got.length, kept: keep.length, n });
    }
    return json({ error: "bad_action" }, 400);
  } catch (e) { return json({ error: String(e) }, 400); }
});
