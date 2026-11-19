import { createClient } from "npm:@supabase/supabase-js@2";

// The only place that talks to Google Weather and Google Routes. Everything is cached in Postgres and the app reads the
// cache, never Google. Every outbound call is logged in google_calls. If the key is missing, a call fails or the daily
// guard is hit, the answer is simply "nothing new": plans and cards carry on without weather or travel times.
//   action "sweep":   keep a daily forecast for every spot in _wx_places(), each as fresh as that couple's plans call for
//                     (3, 6, 12 or 24 hours), then measure hotel-to-item travel for any trip with a confirmed stay
//   action "weather": { lat, lng, types?: ["daily","hourly","current"] } for one spot
//   action "plan":    { plan } measure the legs between a plan's stops; shift an untouched auto plan if a stop can't be reached in time
//   action "pairs":   { limit } measure the walk between liked places and what is next to them
//   action "stays":   only the hotel-to-item part of the sweep
// Cheapest SKUs only: Weather Usage, and Compute Routes Essentials (duration and distance, traffic unaware).
// A confirmed stay is located once with one Places Text Search (id, location, name).
// Auth: x-sync-key. The Google key is a function secret and never leaves this function.
//
// Time between stops (v4). Getting from one stop to the next needs more than the drive itself:
//   travel  the Google walk (a mile or less) or drive; when Google has no answer, an estimate from the distance
//   settle  5 min to pay up and head out of the stop you're leaving
//   park    5 more when you drive
//   checkin 20 min early for anything with a set start (a show, a screening, a ticketed event), 10 to be seated for dinner
// A stop lasts as long as the card says (minutes), else 2 hours for daytime, 90 for dinner, 30 for a side quest, an hour otherwise.
// An untouched auto plan is fixed by moving the later stop. A stop with a set start never moves.
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const TTL: Record<string, number> = { current: 1, hourly: 3, daily: 6 };   // hours
const DAILY_GUARD = 1500;                                                   // most Google calls in any 24 hours
const STAY: Record<string, number> = { day: 120, dinner: 90, quest: 30, quest2: 30 };   // minutes at a stop; an hour otherwise
const PLAN_RESERVE = 100;                                                  // calls the background pair job leaves for plans
const SETTLE = 5, PARK = 5, CHECKIN_EVENT = 20, CHECKIN_DINNER = 10;
const r2 = (n: number) => Math.round(n * 100) / 100;
const num = (x: unknown) => { const n = Number(x); return x != null && Number.isFinite(n) ? Math.round(n) : null; };
const pct = (p: any) => Number(p?.precipitation?.probability?.percent ?? 0) || 0;
const packDay = (f: any) => { const dd = f.displayDate ?? {}, day = f.daytimeForecast ?? {}, night = f.nighttimeForecast ?? {};
  return { date: `${dd.year}-${String(dd.month).padStart(2, "0")}-${String(dd.day).padStart(2, "0")}`,
    cond: day.weatherCondition?.description?.text ?? night.weatherCondition?.description?.text ?? "", type: day.weatherCondition?.type ?? night.weatherCondition?.type ?? "",
    hi: num(f.maxTemperature?.degrees), lo: num(f.minTemperature?.degrees), rain_day: pct(day), rain_night: pct(night), rain: Math.max(pct(day), pct(night)),
    wind: num(day.wind?.speed?.value), sunrise: f.sunEvents?.sunriseTime ?? null, sunset: f.sunEvents?.sunsetTime ?? null }; };
const packHour = (f: any) => ({ time: f.interval?.startTime ?? null, temp: num(f.temperature?.degrees), rain: pct(f), cond: f.weatherCondition?.description?.text ?? "" });
const packNow = (d: any) => ({ temp: num(d.temperature?.degrees), feels: num(d.feelsLikeTemperature?.degrees), rain: pct(d), cond: d.weatherCondition?.description?.text ?? "", wind: num(d.wind?.speed?.value), daytime: d.isDaytime ?? null });
const miles = (a: any, b: any) => { const R = 3958.8, t = (x: number) => x * Math.PI / 180, dl = t(b.lat - a.lat), dg = t(b.lng - a.lng);
  const h = Math.sin(dl / 2) ** 2 + Math.cos(t(a.lat)) * Math.cos(t(b.lat)) * Math.sin(dg / 2) ** 2; return 2 * R * Math.asin(Math.sqrt(h)); };
const mins = (t: string) => { const [h, m] = String(t).split(":").map(Number); return h * 60 + m; };
const hhmm = (m: number) => `${String(Math.floor(m / 60) % 24).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
// the start written on a card ("7:30 PM", "3:00 to 5:45 PM"), in minutes, or null
const setStart = (c: any) => { const m = String(c?.data?.time ?? "").toLowerCase().match(/(\d{1,2})(?::(\d{2}))?\s*(?:to|-|–)?\s*(?:\d{1,2}(?::\d{2})?\s*)?(am|pm)/);
  return m ? (Number(m[1]) % 12 + (m[3] === "pm" ? 12 : 0)) * 60 + Number(m[2] ?? 0) : null; };
const isFixed = (it: any, c: any) => !!c && setStart(c) != null && ((c.deck === "event" && !c.data?.place) || String(it.slot).startsWith("event"));
const checkin = (it: any, c: any) => isFixed(it, c) ? CHECKIN_EVENT : c?.deck === "dinner" && c?.kind !== "cook" && c?.kind !== "orderin" ? CHECKIN_DINNER : 0;
const stayOf = (it: any, c: any) => Number(c?.data?.minutes) > 0 ? Number(c.data.minutes) : STAY[it.slot] ?? 60;
const estMin = (mi: number) => mi <= 1 ? Math.max(3, Math.round(mi * 20)) : Math.round(mi * 2.6 + 4);

Deno.serve(async (req: Request) => {
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle();
    if (!sec?.value || req.headers.get("x-sync-key") !== sec.value) return json({ error: "forbidden" }, 403);
    const a = await req.json().catch(() => ({}));
    const key = a.nokey ? "" : (Deno.env.get("GOOGLE_PLACES_KEY") ?? "");   // nokey:true is for testing the no-key path
    let left: number | null = null; let made = 0;
    const canCall = async () => { if (!key) return false;
      if (left === null) { const { count } = await sb.from("google_calls").select("id", { count: "exact", head: true }).gte("at", new Date(Date.now() - 864e5).toISOString()); left = DAILY_GUARD - (count ?? 0); }
      return left > 0; };
    const log = async (api: string, sku: string, couple: string | null, ok: boolean, note: string) => { if (left !== null) left--; made++;
      await sb.from("google_calls").insert({ api, sku, couple_id: couple, ok, note: note.slice(0, 200) }); };

    async function weather(lat: number, lng: number, type: string, couple: string | null, ttlHours?: number): Promise<string> {
      const la = r2(lat), ln = r2(lng);
      const { data: hit } = await sb.from("weather_cache").select("fetched_at").eq("lat", la).eq("lng", ln).eq("type", type).maybeSingle();
      if (hit && Date.now() - Date.parse(hit.fetched_at) < (ttlHours ?? TTL[type]) * 36e5 - 6e5) return "cached";
      if (!(await canCall())) return "skipped";
      const path = type === "daily" ? "forecast/days:lookup" : type === "hourly" ? "forecast/hours:lookup" : "currentConditions:lookup";
      const q = new URLSearchParams({ "location.latitude": String(la), "location.longitude": String(ln), unitsSystem: "IMPERIAL" });
      if (type === "daily") { q.set("days", "10"); q.set("pageSize", "10"); }
      if (type === "hourly") { q.set("hours", "48"); q.set("pageSize", "48"); }
      try {
        const r = await fetch(`https://weather.googleapis.com/v1/${path}?${q}`, { headers: { "X-Goog-Api-Key": key } });
        const d = await r.json().catch(() => null);
        await log("weather", "Weather Usage", couple, r.ok, r.ok ? type : `${type} ${r.status} ${String(d?.error?.message ?? "").slice(0, 140)}`);
        if (!r.ok || !d) return "failed";
        const data = type === "daily" ? (d.forecastDays ?? []).map(packDay) : type === "hourly" ? (d.forecastHours ?? []).map(packHour) : packNow(d);
        const { error } = await sb.from("weather_cache").upsert({ lat: la, lng: ln, type, data, fetched_at: new Date().toISOString() });
        return error ? "failed" : "fetched";
      } catch (_) { return "failed"; }
    }

    const wp = (p: any) => p.place_id ? { placeId: p.place_id } : { location: { latLng: { latitude: p.lat, longitude: p.lng } } };
    const kOf = (p: any) => p.place_id ? String(p.place_id) : `ll:${Number(p.lat).toFixed(4)},${Number(p.lng).toFixed(4)}`;
    // one leg, from the cache when it is there (walking is taken to be the same both ways)
    async function leg(o: any, d: any, mode: "WALK" | "DRIVE", couple: string | null): Promise<{ seconds: number; meters: number; cached?: boolean } | null> {
      const ko = kOf(o), kd = kOf(d); if (ko === kd) return { seconds: 0, meters: 0, cached: true };
      const { data: hits } = await sb.from("route_cache").select("o,d,seconds,meters,fetched_at").eq("mode", mode).in("o", [ko, kd]).in("d", [ko, kd]);
      const hit = ((hits ?? []) as any[]).find((h) => (h.o === ko && h.d === kd) || (mode === "WALK" && h.o === kd && h.d === ko));
      if (hit && Date.now() - Date.parse(hit.fetched_at) < 30 * 864e5) return hit.seconds == null ? null : { seconds: hit.seconds, meters: hit.meters ?? 0, cached: true };
      if (!(await canCall())) return null;
      try {
        const body: Record<string, unknown> = { origin: wp(o), destination: wp(d), travelMode: mode };
        if (mode === "DRIVE") body.routingPreference = "TRAFFIC_UNAWARE";
        const r = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", { method: "POST",
          headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key, "X-Goog-FieldMask": "routes.duration,routes.distanceMeters" }, body: JSON.stringify(body) });
        const j = await r.json().catch(() => null);
        await log("routes", "Compute Routes Essentials", couple, r.ok, r.ok ? mode : `${mode} ${r.status} ${String(j?.error?.message ?? "").slice(0, 140)}`);
        if (!r.ok) return null;
        const rt = j?.routes?.[0]; const s = rt ? parseInt(String(rt.duration ?? "").replace("s", ""), 10) : NaN;
        await sb.from("route_cache").upsert({ o: ko, d: kd, mode, seconds: Number.isFinite(s) ? s : null, meters: rt?.distanceMeters ?? null, fetched_at: new Date().toISOString() });
        return Number.isFinite(s) ? { seconds: s, meters: rt.distanceMeters ?? 0 } : null;
      } catch (_) { return null; }
    }

    // Trips: once both have said yes to a place to stay, find it once, then measure from it to each planned item that has a location.
    async function stays(): Promise<Record<string, number>> {
      const out: Record<string, number> = { located: 0, not_found: 0, legs: 0 };
      const { data: todo } = await sb.rpc("_stay_todo");
      for (const t of (todo ?? []) as any[]) {
        let st = t.stay ?? {}; const patch: Record<string, unknown> = {};
        if (st.lat == null) {
          if (!(await canCall())) break;
          try {
            const r = await fetch("https://places.googleapis.com/v1/places:searchText", { method: "POST",
              headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key, "X-Goog-FieldMask": "places.id,places.location,places.displayName" },
              body: JSON.stringify({ textQuery: `${t.name}, ${t.city}`, pageSize: 1, locationBias: { circle: { center: { latitude: t.clat, longitude: t.clng }, radius: 40000 } } }) });
            const j = await r.json().catch(() => null);
            await log("places", "Text Search Pro", t.couple, r.ok, r.ok ? "stay" : `stay ${r.status} ${String(j?.error?.message ?? "").slice(0, 140)}`);
            if (!r.ok) continue;
            const p = j?.places?.[0]; const here = p?.location ? { lat: p.location.latitude, lng: p.location.longitude } : null;
            if (!p || !here || miles(here, { lat: t.clat, lng: t.clng }) > 40) { await sb.rpc("_stay_set", { v: t.couple, p_city: t.city, p_patch: { geo: "none" } }); out.not_found++; continue; }
            Object.assign(patch, { place_id: p.id, lat: here.lat, lng: here.lng, found: p.displayName?.text ?? null, geo: "ok" }); st = { ...st, ...patch }; out.located++;
          } catch (_) { continue; }
        }
        const legs: Record<string, unknown> = { ...(st.legs ?? {}) }; let added = 0;
        for (const c of (t.cards ?? []) as any[]) {
          if (legs[c.id]) continue;
          const mode = miles(st, c) <= 1 ? "WALK" : "DRIVE";
          const g = await leg({ place_id: st.place_id, lat: st.lat, lng: st.lng }, c, mode, t.couple);
          if (!g) continue;
          legs[c.id] = { mode: mode === "WALK" ? "walk" : "drive", min: Math.max(1, Math.ceil(g.seconds / 60)) }; added++;
        }
        if (added) patch.legs = legs;
        if (Object.keys(patch).length) await sb.rpc("_stay_set", { v: t.couple, p_city: t.city, p_patch: patch });
        out.legs += added;
      }
      return out;
    }

    if (a.action === "sweep") {
      const { data: spots } = await sb.rpc("_wx_places");
      const out: Record<string, number> = {};
      for (const s of (spots ?? []) as any[]) { const r = await weather(Number(s.lat), Number(s.lng), "daily", s.couple ?? null, Number(s.ttl) || 24); out[r] = (out[r] ?? 0) + 1; }
      const st = await stays();
      return json({ ok: true, spots: (spots ?? []).length, ...out, stays: st, google_calls: made });
    }
    if (a.action === "stays") return json({ ok: true, stays: await stays(), google_calls: made });

    if (a.action === "weather") {
      const out: Record<string, string> = {};
      for (const t of (Array.isArray(a.types) && a.types.length ? a.types : ["daily"]) as string[]) if (TTL[t]) out[t] = await weather(Number(a.lat), Number(a.lng), t, a.couple ?? null);
      return json({ ok: true, ...out, google_calls: made });
    }

    if (a.action === "plan") {
      const { data: plan } = await sb.from("plans").select("id,couple_id,day,items,status,by_member,auto,legs,mode").eq("id", String(a.plan ?? "")).maybeSingle();
      if (!plan) return json({ ok: false, reason: "bad_plan" });
      const items = ((plan.items ?? []) as any[]).map((x) => ({ ...x }));
      const ids = items.filter((i) => typeof i.card === "string").map((i) => i.card);
      const { data: cards } = ids.length ? await sb.from("cards").select("id,deck,kind,data").in("id", ids) : { data: [] as any[] };
      const cardOf = (id: unknown) => ((cards ?? []) as any[]).find((x) => x.id === id) ?? null;
      const spot = (c: any) => { const la = Number(c?.data?.lat), ln = Number(c?.data?.lng);
        if (!c || c.deck === "movie") return null;
        if (c.data?.lat != null && Number.isFinite(la) && Number.isFinite(ln)) return { id: c.id, place_id: c.data.place_id ?? null, lat: la, lng: ln };
        return c.data?.place_id ? { id: c.id, place_id: String(c.data.place_id), lat: null, lng: null } : null; };   // Google can route from the place alone
      // every stop with a time; one without a known place still takes up its time (night-in plans have no travel)
      const stops = items.map((it, i) => { const c = cardOf(it.card); return { i, it, c, p: spot(c) }; })
        .filter((s) => s.c && /^\d{2}:\d{2}$/.test(String(s.it.time ?? ""))).sort((x, y) => mins(x.it.time) - mins(y.it.time));
      const keyOf = () => "v4|" + stops.map((s) => `${s.c.id}@${s.it.time}`).join("|");
      if (plan.legs?.key === keyOf() && !a.force) return json({ ok: true, unchanged: true, google_calls: 0 });
      const legs: any[] = []; let shifted = 0;
      const mayShift = plan.by_member === "auto" && plan.status === "sent";
      const home = plan.mode === "in";
      for (let k = 0; k + 1 < stops.length; k++) {
        const A = stops[k], B = stops[k + 1];
        let min = 0, mode = "home", meters = 0, measured = false;
        if (!home && A.p && B.p) {
          const mi = A.p.lat != null && B.p.lat != null ? miles(A.p, B.p) : 3; mode = mi <= 1 ? "walk" : "drive";
          const g = await leg(A.p, B.p, mode === "walk" ? "WALK" : "DRIVE", plan.couple_id);
          if (g) { min = Math.max(1, Math.ceil(g.seconds / 60)); meters = g.meters; measured = true; } else min = estMin(mi);
        } else if (!home) { mode = "drive"; min = 15; }   // somewhere we can't place: a fair guess
        const ci = home ? 0 : checkin(B.it, B.c), pk = home ? 0 : SETTLE + (mode === "drive" ? PARK : 0);
        const need = min + pk + ci, arrive = mins(A.it.time) + stayOf(A.it, A.c) + need; let late = arrive > mins(B.it.time);
        if (late && mayShift && !isFixed(B.it, B.c)) {
          const to = Math.ceil(arrive / 5) * 5; shifted += to - mins(B.it.time); B.it.time = hhmm(to); items[B.i].time = B.it.time; late = false;
          stops.sort((x, y) => mins(x.it.time) - mins(y.it.time));
        } else if (late && mayShift && !isFixed(A.it, A.c)) {   // the next stop has a set start: start this one earlier instead, if the one before allows it
          const to = Math.floor((mins(A.it.time) - (arrive - mins(B.it.time))) / 5) * 5, P = stops[k - 1];
          if (to >= 9 * 60 && (!P || mins(P.it.time) + stayOf(P.it, P.c) + 15 <= to)) { shifted += mins(A.it.time) - to; A.it.time = hhmm(to); items[A.i].time = A.it.time; late = false; }
        }
        if (measured || late) legs.push({ from: A.c.id, to: B.c.id, mode, min, meters, ...(measured ? {} : { est: true }), park: pk, checkin: ci, need,
          ...(late ? { late: true, short_by: arrive - mins(B.it.time), fixed: isFixed(B.it, B.c) } : {}) });
      }
      const upd: Record<string, unknown> = { legs: { key: keyOf(), at: new Date().toISOString(), legs } };
      if (shifted) upd.items = items;
      await sb.from("plans").update(upd).eq("id", plan.id);
      return json({ ok: true, legs, shifted, google_calls: made });
    }

    if (a.action === "pairs") {
      const { data: todo } = await sb.rpc("_near_pairs_todo", { p_n: Math.min(Number(a.limit ?? 40), 80) });
      let done = 0;
      if (left === null) await canCall();
      for (const t of (todo ?? []) as any[]) { if (left !== null && left <= PLAN_RESERVE) break; const g = await leg({ place_id: t.a_pid, lat: t.a_lat, lng: t.a_lng }, { place_id: t.b_pid, lat: t.b_lat, lng: t.b_lng }, "WALK", t.couple ?? null); if (g) done++; if (left !== null && left <= 0) break; }
      return json({ ok: true, todo: (todo ?? []).length, measured: done, google_calls: made });
    }
    return json({ ok: false, reason: "bad_action" });
  } catch (e) { return json({ ok: false, reason: "error", detail: String(e).slice(0, 200) }); }
});
