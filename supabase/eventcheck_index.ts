import { createClient } from "npm:@supabase/supabase-js@2";
import { logAi } from "./ai_log.ts";
logAi("eventcheck");

// eventcheck: confirms an event is real before it goes on anyone's deck (Dave, 19 Nov).
// For events from listing sites and web finds (not ticketing feeds), Claude searches the web — the venue's own site and
// social posts, other listings, local news, community boards, Reddit — and reports what independent sources say.
// _eventcheck_apply (database) then shows the card with corrected details, or keeps it off when nothing confirms it.
// Body: { ids?: uuid[], limit?: number }. With no ids it takes the next cards from _eventcheck_queue. Auth: x-sync-key.
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const apiKey = () => Deno.env.get("ANTHROPIC_API_KEY") ?? Deno.env.get("CLAUDE_API_KEY") ?? Deno.env.get("CLAUDE_KEY") ?? Deno.env.get("ANTHROPIC_KEY") ?? "";
const MODELS = [Deno.env.get("CLAUDE_EVENTCHECK_MODEL"), "claude-sonnet-5-5", "claude-sonnet-4-5"].filter(Boolean) as string[];

async function ask(prompt: string): Promise<{ text: string | null; err: string; searches: number }> {
  const key = apiKey(); if (!key) return { text: null, err: "no key", searches: 0 };
  const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), 110000);
  let err = "";
  try {
    for (const model of MODELS) {
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", signal: ctl.signal,
        headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" },
        body: JSON.stringify({ model, max_tokens: 1500, tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 5 }],
          messages: [{ role: "user", content: prompt }] }) });
      if (!r.ok) { const t = (await r.text()).slice(0, 300); err = `${model} ${r.status} ${t}`; if (r.status === 404 || (r.status === 400 && /model/i.test(t))) continue; return { text: null, err, searches: 0 }; }
      const d = await r.json();
      const blocks = (d.content ?? []) as any[];
      const text = blocks.filter((b) => b.type === "text").map((b) => b.text).join("\n").trim();
      const searches = blocks.filter((b) => b.type === "server_tool_use").length;
      return { text: text || null, err: text ? "" : `${model} empty (${d.stop_reason})`, searches };
    }
    return { text: null, err, searches: 0 };
  } catch (e) { return { text: null, err: String(e), searches: 0 }; } finally { clearTimeout(timer); }
}

const STOP = new Set(["theater", "theatre", "cafe", "club", "park", "hall", "center", "centre", "house", "room", "detroit", "music", "live", "downtown", "lounge"]);
// is the listing's web address the venue's own site? then it is a source in its own right
const venueSite = (d: any, title: string) => { const h = host(String(d?.url ?? "")); if (!h) return false;
  return String(d?.venue || title || "").toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length >= 4 && !STOP.has(w)).some((w) => h.includes(w)); };
const host = (u: string) => { try { return new URL(u).hostname.replace(/^www\./, ""); } catch (_) { return ""; } };
const day = (d: string) => { try { return new Date(d + "T12:00:00").toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", year: "numeric" }); } catch (_) { return d; } };

Deno.serve(async (req: Request) => {
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle();
    if (!sec?.value || req.headers.get("x-sync-key") !== sec.value) return json({ error: "forbidden" }, 403);
    const a = await req.json().catch(() => ({}));
    let ids: string[] = Array.isArray(a.ids) ? a.ids.map(String).slice(0, 12) : [];
    if (!ids.length) { const { data } = await sb.rpc("_eventcheck_queue", { p_n: Math.min(Math.max(Number(a.limit) || 6, 1), 12) }); ids = ((data ?? []) as any[]).map((x) => String(x.id ?? x)); }
    if (!ids.length) return json({ ok: true, done: 0 });
    const { data: cards } = await sb.from("cards").select("id,title,event_date,data").in("id", ids);
    const out: any[] = [];
    // three at a time: each check can run several searches
    const list = (cards ?? []) as any[];
    for (let i = 0; i < list.length; i += 3) {
      await Promise.all(list.slice(i, i + 3).map(async (c) => {
        const d = c.data ?? {}, own = venueSite(d, c.title), src = own ? "" : host(String(d.url ?? ""));
        const today = new Date().toLocaleDateString("en-US", { timeZone: "America/Detroit", weekday: "long", month: "long", day: "numeric", year: "numeric" });
        const where = [d.venue, d.address, d.area, d.city || "Detroit area, Michigan"].filter(Boolean).join(", ");
        const prompt = `Today is ${today} in Detroit. An app for couples shows local events. Before we show this one, check that it is real and that its details are right.

Event as listed${own ? " on the venue's own website (" + host(String(d.url)) + ")" : src ? ` on ${src}` : ""}:
- Title: ${c.title}
- Date: ${day(c.event_date ?? d.date)}
- Time: ${d.time ?? "not given"}
- Where: ${where}
${d.notes ? `- Listing text: ${String(d.notes).slice(0, 300)}\n` : ""}
Search the web for this event: the venue's own website and social posts, other event listings, local news, community boards and Reddit. A weekly or recurring event counts if a source shows it runs on this weekday now. Use only what the sources say. Never guess or fill a gap from general knowledge. If sources disagree on the time, the venue's own page for this event wins; if you can't tell which time is right, set "found" to false and say why in "note".

Reply with only this JSON, no other text:
{"found": true or false, "same_date": true or false, "date": "YYYY-MM-DD or null", "time": "e.g. 7:00 pm or 7:00 pm - 10:00 pm, or null", "venue": "name or null", "address": "street address or null", "about": "one plain sentence on what the event is, from the sources, or null", "price": "e.g. Free or $10, or null", "link": "the best page for this specific event, or null", "sources": ["urls that show it"], "note": "a few words on what you found"}

"found" is true only if ${own ? "the venue's own website or another source still lists this event" : `at least one source other than ${src || "the listing"} (the venue's own site and posts count) shows this event at this venue`}, with a time you are sure of. "same_date" is true only if a source shows it on ${day(c.event_date ?? d.date)}.`;
        const r = await ask(prompt);
        let v: any = null;
        try { v = JSON.parse((r.text ?? "").match(/\{[\s\S]*\}/)?.[0] ?? "null"); } catch (_) { v = null; }
        if (!v) { out.push({ id: c.id, title: c.title, error: r.err || "no answer" }); if (!r.err) await sb.rpc("_eventcheck_apply", { p_id: c.id, p_res: { found: false, note: "no readable answer" } }); return; }
        v.searches = r.searches;
        const { data: res } = await sb.rpc("_eventcheck_apply", { p_id: c.id, p_res: v });
        out.push({ id: c.id, title: c.title, result: res });
      }));
    }
    return json({ ok: true, checked: out.length, out });
  } catch (e) { return json({ error: String(e) }, 400); }
});
