import { createClient } from "npm:@supabase/supabase-js@2";

// One-off research for a place Google holds no opening hours for: read the venue's own website and take the weekly
// hours it states. Used only when a plan spot has nothing else that fits (see _hours_ask).
// Nothing is made up: the website address comes from Google's listing for the place, and every day's hours must come
// with the exact words from the page that give them, which are checked against the page text. If Google does have
// weekly hours, those are used. A place that is not operating, has no website, or whose page gives no clear hours is
// marked as tried and left out of plans. Hours found this way are saved with hours_src "site", so the plan can say so,
// and the real-date check before a plan is announced still applies.
// Body: { card }  (dry: true saves nothing). Auth: x-sync-key.
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const apiKey = () => Deno.env.get("ANTHROPIC_API_KEY") ?? Deno.env.get("CLAUDE_API_KEY") ?? Deno.env.get("CLAUDE_KEY") ?? Deno.env.get("ANTHROPIC_KEY") ?? "";
const decode = (s: string) => s.replace(/&amp;/g, "&").replace(/&#0?39;|&rsquo;|&apos;/g, "'").replace(/&quot;/g, '"').replace(/&nbsp;/g, " ").replace(/&ndash;|&mdash;|&#821[12];/g, "-").replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)));
const strip = (h: string) => decode(h.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>|<!--[\s\S]*?-->/gi, " ").replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim();
const flat = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
const host = (u: string) => { try { return new URL(u).hostname.replace(/^www\./, "").toLowerCase(); } catch (_) { return ""; } };

async function page(url: string): Promise<{ html: string; url: string } | null> {
  const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 9000);
  try {
    const r = await fetch(url, { signal: ctl.signal, redirect: "follow", headers: { "User-Agent": "Mozilla/5.0 (compatible; LetsTogether/1.0; +https://letstogether.app)", "Accept": "text/html,application/xhtml+xml" } });
    if (!r.ok || !/html/i.test(r.headers.get("content-type") ?? "")) return null;
    return { html: (await r.text()).slice(0, 700000), url: r.url || url };
  } catch (_) { return null; } finally { clearTimeout(t); }
}
// a page on the same site that is likely to state the hours
function hoursLink(html: string, base: string): string | null {
  for (const m of html.matchAll(/<a\b[^>]*?href\s*=\s*["']([^"'#][^"']*)["'][^>]*>([\s\S]*?)<\/a>/gi)) {
    let u = ""; try { u = new URL(decode(m[1]), base).toString(); } catch (_) { continue; }
    if (!/^https?:/.test(u) || host(u) !== host(base) || u.replace(/\/$/, "") === base.replace(/\/$/, "")) continue;
    if (/hours|visit|contact|location|find-us|about/i.test(strip(m[2]) + " " + u)) return u;
  }
  return null;
}
// the stretches of page text that talk about days and times, so a long page still fits in one reading
function hoursText(text: string): string {
  const out: string[] = []; let last = -1;
  for (const m of text.matchAll(/\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*\b|\bhours\b|\bdaily\b|\b\d{1,2}(:\d{2})?\s?(am|pm)\b/gi)) {
    const i = m.index ?? 0; if (i < last) continue;
    out.push(text.slice(Math.max(0, i - 200), i + 500)); last = i + 500;
    if (out.join(" ").length > 7000) break;
  }
  return out.join(" … ").slice(0, 8000);
}
async function ask(prompt: string, max = 700): Promise<string | null> {
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
function packGoogle(h: any): unknown {
  const ps = h?.periods; if (!Array.isArray(ps) || !ps.length) return null;
  if (ps.length === 1 && ps[0].open && !ps[0].close) return "always";
  const out: number[][] = [];
  for (const p of ps) { const o = p.open, c = p.close; if (!o || !c) continue; out.push([o.day ?? 0, (o.hour ?? 0) * 100 + (o.minute ?? 0), c.day ?? 0, (c.hour ?? 0) * 100 + (c.minute ?? 0)]); }
  return out.length ? out : null;
}

Deno.serve(async (req: Request) => {
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle();
    if (!sec?.value || req.headers.get("x-sync-key") !== sec.value) return json({ error: "forbidden" }, 403);
    const gkey = Deno.env.get("GOOGLE_PLACES_KEY"); if (!gkey) return json({ error: "no_key" }, 503);
    const a = await req.json().catch(() => ({}));
    const { data: card } = await sb.from("cards").select("id,title,data").eq("id", String(a.card ?? "")).maybeSingle();
    if (!card?.data?.place_id) return json({ ok: false, reason: "no_place" });
    const today = new Date().toISOString().slice(0, 10);
    const save = async (patch: Record<string, unknown>) => { if (!a.dry) await sb.from("cards").update({ data: { ...card.data, hours_tried: today, ...patch } }).eq("id", card.id); };

    const r = await fetch(`https://places.googleapis.com/v1/places/${encodeURIComponent(card.data.place_id)}`, { headers: { "X-Goog-Api-Key": gkey, "X-Goog-FieldMask": "websiteUri,businessStatus,regularOpeningHours" } });
    const g = await r.json(); if (!r.ok) return json({ ok: false, reason: "google", detail: String(g?.error?.message ?? "").slice(0, 120) });
    if (g.businessStatus && g.businessStatus !== "OPERATIONAL") { await save({}); return json({ ok: true, title: card.title, found: false, why: "Google says it is not operating: " + g.businessStatus }); }
    const gh = packGoogle(g.regularOpeningHours);
    if (gh) { await save({ hours: gh, hours_at: today }); return json({ ok: true, title: card.title, found: true, src: "google", hours: gh }); }
    if (!g.websiteUri) { await save({}); return json({ ok: true, title: card.title, found: false, why: "no website on its listing" }); }

    const first = await page(g.websiteUri);
    if (!first) { await save({}); return json({ ok: true, title: card.title, found: false, why: "website did not load", site: g.websiteUri }); }
    let text = strip(first.html); let used = first.url;
    const more = hoursLink(first.html, first.url);
    if (more) { const p2 = await page(more); if (p2) text += " " + strip(p2.html); }
    const part = hoursText(text);
    if (!part) { await save({}); return json({ ok: true, title: card.title, found: false, why: "no hours on its website", site: used }); }
    const ans = await ask(`Below is text from the website of "${card.title}". Find its regular weekly opening hours.\n\n"""${part}"""\n\n` +
      `Answer as JSON only: {"days":[{"day":0-6 (0 = Sunday, 6 = Saturday),"open":"HH:MM","close":"HH:MM" (24-hour; a close after midnight is still written as its clock time, e.g. "02:00"),"quote":"the exact words copied from the text that give this day's hours"}]}\n` +
      `One entry for each day it is open. Leave out days it is closed. Use the main opening hours of the place itself, not a kitchen, happy hour, delivery or another location. ` +
      `If the text does not clearly state weekly hours for this place, answer {"days":[]}. Never guess.`);
    let o: any = null; try { o = JSON.parse(((ans ?? "").match(/\{[\s\S]*\}/) ?? ["null"])[0]); } catch (_) { o = null; }
    const ft = flat(text), hours: number[][] = []; let bad = 0;
    for (const d of (Array.isArray(o?.days) ? o.days : []).slice(0, 14)) {
      const day = Number(d.day), q = flat(String(d.quote ?? "")), mo = String(d.open ?? "").match(/^(\d{2}):(\d{2})$/), mc = String(d.close ?? "").match(/^(\d{2}):(\d{2})$/);
      if (!(day >= 0 && day <= 6) || !mo || !mc || q.length < 4 || !ft.includes(q)) { bad++; continue; }
      const op = Number(mo[1]) * 100 + Number(mo[2]), cl = Number(mc[1]) * 100 + Number(mc[2]);
      if (op > 2359 || cl > 2359) { bad++; continue; }
      hours.push([day, op, cl <= op ? (day + 1) % 7 : day, cl]);
    }
    if (!hours.length || bad) { await save({}); return json({ ok: true, title: card.title, found: false, why: hours.length ? "some of the hours could not be matched to the page" : "no clear hours on its website", site: used }); }
    await save({ hours, hours_src: "site", hours_url: used, hours_at: today });
    return json({ ok: true, title: card.title, found: true, src: "site", site: used, hours });
  } catch (e) { return json({ ok: false, reason: "error", detail: String(e).slice(0, 200) }); }
});
