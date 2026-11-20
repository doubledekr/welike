import { createClient } from "npm:@supabase/supabase-js@2";
import { logAi } from "./ai_log.ts";
import { wikiImages } from "./wikiimg.ts";
logAi("fests");

// Festivals and annual events for a trip city, from Wikipedia (Dave, 20 Nov). Only for a trip with confirmed dates
// (a couple trip with agreed dates, or a group trip whose weekend was picked), and only once per city a year, so
// Claude runs rarely. Candidates: the city's festival categories plus a search; Claude reads each intro and keeps the
// recurring public events still held, with the months they usually happen. Cards go in the trip deck (data.fest) and
// lead the Explore pile when their months overlap the trip. Body: { code, city }.
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const UA = { "User-Agent": "LetsTogether/1.0 (https://letstogether.app)" };
const W = "https://en.wikipedia.org/w/api.php?format=json&";
const apiKey = () => Deno.env.get("ANTHROPIC_API_KEY") ?? Deno.env.get("CLAUDE_API_KEY") ?? Deno.env.get("CLAUDE_KEY") ?? Deno.env.get("ANTHROPIC_KEY") ?? "";
const MODELS = [Deno.env.get("CLAUDE_FESTS_MODEL"), "claude-haiku-5-5", "claude-haiku-4-5", "claude-sonnet-5-5"].filter(Boolean) as string[];
let lastErr = "";
async function claude(prompt: string, maxTokens: number, ms: number): Promise<string | null> {
  const key = apiKey(); lastErr = ""; if (!key) { lastErr = "no key"; return null; }
  const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), ms);
  try {
    for (const model of MODELS) {
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", signal: ctl.signal,
        headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" },
        body: JSON.stringify({ model, max_tokens: maxTokens, messages: [{ role: "user", content: prompt }] }) });
      if (!r.ok) { const t = (await r.text()).slice(0, 240); lastErr = `${model} ${r.status} ${t}`; if (r.status === 404 || (r.status === 400 && /model/i.test(t))) continue; return null; }
      const d = await r.json(); const text = (d.content ?? []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("").trim();
      if (text) return text; lastErr = `${model} empty`; return null;
    }
    return null;
  } catch (e) { lastErr = String(e); return null; } finally { clearTimeout(timer); }
}
const parseArr = (t: string | null): any[] => { const m = (t ?? "").match(/\[[\s\S]*\]/); try { const a = JSON.parse(m?.[0] ?? "[]"); return Array.isArray(a) ? a : []; } catch (_) { return []; } };
const tidy = (s: string) => s.trim().replace(/\s+/g, " ").slice(0, 40).toLowerCase().replace(/(^|[\s-])([a-z])/g, (_m, a, b) => a + b.toUpperCase());
async function wj(q: string) { try { const r = await fetch(W + q, { headers: UA }); return await r.json(); } catch (_) { return {}; } }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const b = await req.json().catch(() => ({}));
    const city = tidy(String(b.city || "")); if (city.length < 2) return json({ ok: false, why: "bad_city" });
    const { data: couple } = await db.from("couples").select("id, settings").eq("code", String(b.code || "").toUpperCase()).maybeSingle();
    if (!couple) return json({ ok: false, why: "bad_code" }, 403);
    // Confirmed trips only: this couple's trip there with agreed dates, or a group trip there with its weekend picked.
    const pm = ((couple.settings as any)?.plan_meta || {}) as Record<string, any>;
    const mine = Object.entries(pm).find(([k, m]) => k.toLowerCase() === city.toLowerCase() && m?.from && m?.dates_ok);
    let ok = !!mine;
    if (!ok) { const { count } = await db.from("fr_plans").select("id", { count: "exact", head: true }).ilike("city", city).not("day_from", "is", null).gte("day_from", new Date().toISOString().slice(0, 10)); ok = (count || 0) > 0; }
    if (!ok) return json({ ok: false, why: "not_confirmed" });
    const { data: done } = await db.from("city_fests").select("at, n").eq("city", city).maybeSingle();
    if (done && Date.now() - new Date(done.at).getTime() < 300 * 864e5) return json({ ok: true, cached: true, n: done.n });
    await db.from("city_fests").upsert({ city, at: new Date().toISOString(), n: 0, note: "working" });   // one run at a time per city

    const ids = new Map<number, string>();
    for (const cat of [`Festivals in ${city}`, `Annual events in ${city}`, `Music festivals in ${city}`]) {
      const d = await wj(`action=query&list=categorymembers&cmtype=page&cmlimit=40&cmtitle=${encodeURIComponent("Category:" + cat)}`);
      for (const p of d?.query?.categorymembers ?? []) ids.set(p.pageid, p.title);
    }
    for (const q of [`${city} festival`, `${city} annual festival celebration`]) {
      const d = await wj(`action=query&list=search&srlimit=20&srsearch=${encodeURIComponent(q)}`);
      for (const p of d?.query?.search ?? []) ids.set(p.pageid, p.title);
    }
    const cands = [...ids.entries()].filter(([, t]) => !/^(List of|Category:|\d{4} )/.test(t)).slice(0, 40);
    if (!cands.length) { await db.from("city_fests").upsert({ city, at: new Date().toISOString(), n: 0, note: "no candidates" }); return json({ ok: true, n: 0 }); }
    const ex = new Map<number, string>();
    for (let i = 0; i < cands.length; i += 20) {
      const d = await wj(`action=query&prop=extracts&exintro=1&explaintext=1&exlimit=20&pageids=${cands.slice(i, i + 20).map(([id]) => id).join("%7C")}`);
      for (const p of Object.values(d?.query?.pages ?? {}) as any[]) ex.set(Number(p.pageid), String(p.extract ?? "").replace(/\s+/g, " ").slice(0, 600));
    }
    const list = cands.map(([id, t], i) => `${i + 1}. ${t}\n${ex.get(id) || "(no text)"}`).join("\n\n");
    const text = await claude(
      `Below are Wikipedia articles found for festivals and events in ${city}. Keep only recurring public festivals, fairs, parades, holidays with public celebrations, or annual events a visitor could attend in or right around ${city}, that are still held. ` +
      `Leave out one-off past events, organisations, venues, films, songs, sports teams, ordinary sports matches, and anything you are not confident still happens.\n\n${list}\n\n` +
      `For each one you keep give: n (list number); months (the month numbers it usually falls in, 1 to 12); when (a short phrase like "Usually mid-June" or "Usually the first weekend of March", only from the text); ` +
      `line (one sentence, at most 20 words, plain warm words about what it is, facts from the text only, no copied phrases, no quotation marks); k (two or three word type, like Street festival or Film festival).\n` +
      `Reply with JSON only: [{"n": 1, "months": [6], "when": "...", "line": "...", "k": "..."}]`, 3000, 60000);
    if (!text) { await db.from("city_fests").delete().eq("city", city); return json({ ok: false, why: "ai", err: lastErr.slice(0, 120) }); }   // try again another time
    const keep = parseArr(text).filter((x) => Number.isInteger(x?.n) && x.n >= 1 && x.n <= cands.length && Array.isArray(x.months) && x.months.length && String(x.line || "").length > 15);
    const pics = await wikiImages(keep.map((x) => cands[x.n - 1][0]));
    const items = keep.map((x) => { const [id, title] = cands[x.n - 1], im = pics.get(id);
      const months = [...new Set((x.months as any[]).map(Number).filter((m) => m >= 1 && m <= 12))];
      return { code: "wpf:" + id, city, title: String(title).replace(/\s*\([^)]*\)$/, ""), subtitle: String(x.when || "Held every year").slice(0, 60), image: im?.url || "",
        data: { fest: true, explore: "fest", city, months, when: String(x.when || "").slice(0, 60), notes: String(x.line).replace(/["“”]/g, "").slice(0, 200), kind: String(x.k || "").slice(0, 40),
          src: `https://en.wikipedia.org/?curid=${id}`, source: "wikipedia", ...(im ? { photo_credit: im.credit } : {}) } }; }).filter((it) => it.data.months.length);
    let n = 0; if (items.length) { const { data } = await db.rpc("fests_upsert", { p_items: items }); n = data ?? 0; }
    await db.from("city_fests").upsert({ city, at: new Date().toISOString(), n, note: keep.length ? `candidates ${cands.length}, kept ${keep.length}, photos ${pics.size}` : ("none kept " + lastErr).slice(0, 200) });
    return json({ ok: true, n, cands: cands.length, photos: pics.size });
  } catch (e) { return json({ ok: false, error: String(e) }, 500); }
});
