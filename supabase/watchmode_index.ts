import { createClient } from "npm:@supabase/supabase-js@2";

// Builds the shared Watch catalog (movies and, since the Discover package, TV series) from Watchmode. Called nightly by pg_cron.
// Auth: x-sync-key header must match app_secrets.sync_key.
// Body: { lists?: boolean, per_source?: number, series_per_source?: number, series?: boolean, details?: number, skip?: number }
//   series: false lists movies only, as before. Series cards carry data.type = "series"; the app tags them "Series",
//   and a night-in plan reads "start it: an episode or two".
// The list of streaming services lives in app_secrets.sources as JSON: { "<watchmode source id>": "<name shown in the app>" }.
const DEFAULT_SOURCES: Record<string, string> = {
  "203": "Netflix", "157": "Hulu", "26": "Prime Video",
  "372": "Disney+", "389": "Peacock", "252": "Shudder",
};
const API = "https://api.watchmode.com/v1";

Deno.serve(async (req: Request) => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: secs } = await sb.from("app_secrets").select("key,value");
  const S: Record<string, string> = Object.fromEntries((secs ?? []).map((r: any) => [r.key, r.value]));
  if (!S.sync_key || req.headers.get("x-sync-key") !== S.sync_key) return new Response("forbidden", { status: 403 });
  let SOURCES = DEFAULT_SOURCES;
  try { if (S.sources) SOURCES = JSON.parse(S.sources); } catch (_) { /* keep defaults */ }
  const body = await req.json().catch(() => ({}));
  const key = S.watchmode_key;
  const out: any = { listed: 0, series_listed: 0, added: 0, detailed: 0, errors: [], quota_used: null, quota: null };
  const today = new Date().toISOString().slice(0, 10);

  if (body.lists) {
    const found = new Map<string, any>();
    const kinds: [string, number][] = [["movie", body.per_source ?? 250]];
    if (body.series !== false) kinds.push(["tv_series", body.series_per_source ?? 80]);
    for (const [type, limit] of kinds) {
      for (const [id, name] of Object.entries(SOURCES)) {
        const r = await fetch(`${API}/list-titles/?apiKey=${key}&source_ids=${id}&types=${type}&regions=US&sort_by=popularity_desc&limit=${limit}`);
        out.quota_used = r.headers.get("x-account-quota-used"); out.quota = r.headers.get("x-account-quota");
        if (!r.ok) { out.errors.push(`list ${type} ${name} ${r.status}`); continue; }
        const j = await r.json();
        (j.titles ?? []).forEach((t: any, i: number) => {
          const k = String(t.id);
          const e = found.get(k) ?? { title: t.title, year: t.year, services: [], rank: i, series: type === "tv_series" };
          if (!e.services.includes(name)) e.services.push(name);
          e.rank = Math.min(e.rank, i);
          found.set(k, e);
        });
      }
    }
    out.listed = found.size; out.series_listed = [...found.values()].filter((e) => e.series).length;
    const existing: any[] = [];
    for (let from = 0; ; from += 1000) {
      const { data } = await sb.from("cards").select("id,ext_id,data,active").eq("deck", "movie").is("couple_id", null).range(from, from + 999);
      existing.push(...(data ?? []));
      if (!data || data.length < 1000) break;
    }
    const byExt = new Map(existing.map((c: any) => [c.ext_id, c]));
    const inserts: any[] = [];
    const updates: Promise<unknown>[] = [];
    for (const [k, e] of found) {
      const cur: any = byExt.get(k);
      if (!cur) {
        inserts.push({ deck: "movie", ext_id: k, title: e.title, kind: e.services[0], active: false,
          data: { year: e.year, services: e.services, rank: e.rank, listed_at: today, ...(e.series ? { type: "series" } : {}) } });
      } else {
        const d = { ...cur.data, services: e.services, rank: e.rank, listed_at: today, ...(e.series ? { type: "series" } : {}) };
        updates.push(sb.from("cards").update({ data: d, kind: e.services[0] }).eq("id", cur.id) as unknown as Promise<unknown>);
        if (updates.length >= 20) { await Promise.all(updates.splice(0)); }
      }
    }
    await Promise.all(updates);
    for (let i = 0; i < inserts.length; i += 500) {
      const { error } = await sb.from("cards").insert(inserts.slice(i, i + 500));
      if (error) out.errors.push("insert " + error.message); else out.added += Math.min(500, inserts.length - i);
    }
    // Titles that have not shown up on any of the services for 3 weeks drop out of the deck.
    // A movies-only run (series: false) leaves series alone.
    if (!out.errors.length) {
      const cutoff = new Date(Date.now() - 21 * 864e5).toISOString().slice(0, 10);
      for (const c of existing) {
        if (body.series === false && c.data?.type === "series") continue;
        if (c.active && !found.has(c.ext_id) && (c.data?.listed_at ?? "") < cutoff) {
          await sb.from("cards").update({ active: false }).eq("id", c.id);
        }
      }
    }
  }

  const n = Math.min(Number(body.details ?? 0), 60);
  const skip = Math.max(0, Number(body.skip ?? 0));
  if (n > 0) {
    const stubs: any[] = [];
    for (let from = 0; ; from += 1000) {
      const { data } = await sb.from("cards").select("id,ext_id,data").eq("deck", "movie").is("couple_id", null)
        .filter("data->>detailed", "is", null).range(from, from + 999);
      stubs.push(...(data ?? []));
      if (!data || data.length < 1000) break;
    }
    // Most popular first; rank is per service, so every service fills in evenly.
    const pool = stubs.sort((a, b) => (a.data?.rank ?? 999) - (b.data?.rank ?? 999) || String(a.ext_id).localeCompare(String(b.ext_id))).slice(skip, skip + n);
    const one = async (c: any) => {
      try {
        const r = await fetch(`${API}/title/${c.ext_id}/details/?apiKey=${key}&append_to_response=cast-crew`);
        out.quota_used = r.headers.get("x-account-quota-used") ?? out.quota_used; out.quota = r.headers.get("x-account-quota") ?? out.quota;
        if (!r.ok) { out.errors.push(`details ${c.ext_id} ${r.status}`); return; }
        const t = await r.json();
        const series = c.data?.type === "series" || /tv_(series|miniseries)/.test(String(t.type ?? ""));
        const people = (t.cast ?? t["cast-crew"] ?? []) as any[];
        const cast = people.filter((p) => p.type === "Cast").sort((a, b) => (a.order ?? 999) - (b.order ?? 999)).slice(0, 8)
          .map((p) => ({ name: p.full_name, role: p.role }));
        const directors = people.filter((p) => p.type === "Crew" && /(^|, )Director($|,)/.test(p.role ?? "")).slice(0, 2).map((p) => p.full_name);
        // a series shows its years ("2019 to 2023", "since 2021"), never a runtime
        const bits = series
          ? ["Series", t.end_year && t.end_year !== t.year ? `${t.year} to ${t.end_year}` : t.end_year ? String(t.year) : t.year ? `since ${t.year}` : null, t.us_rating].filter(Boolean)
          : [t.year, t.runtime_minutes ? `${t.runtime_minutes} min` : null, t.us_rating].filter(Boolean);
        const data = { ...c.data, detailed: true, year: t.year, plot: t.plot_overview, genres: t.genre_names ?? [],
          runtime: t.runtime_minutes, user_rating: t.user_rating, critic_score: t.critic_score, us_rating: t.us_rating,
          trailer: t.trailer, backdrop: t.backdrop, poster_large: t.posterLarge, imdb_id: t.imdb_id, cast, directors,
          ...(series ? { type: "series", end_year: t.end_year ?? null } : {}) };
        const { error } = await sb.from("cards").update({ title: t.title, subtitle: bits.join(" · "), image: t.posterLarge || t.poster || null,
          data, active: !!(t.posterLarge || t.poster) }).eq("id", c.id);
        if (error) out.errors.push("update " + error.message); else out.detailed++;
      } catch (e) { out.errors.push(String(e)); }
    };
    for (let i = 0; i < pool.length; i += 4) await Promise.all(pool.slice(i, i + 4).map(one));
  }
  return new Response(JSON.stringify(out), { headers: { "Content-Type": "application/json" } });
});
