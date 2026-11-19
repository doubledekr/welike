import { createClient } from "npm:@supabase/supabase-js@2";

// Planning helper, second version: one find for a group trip, matched to what the group agreed on, with a reason.
// Beta plans only (group plans exist only in the beta). Called by a signed-in person who is in the plan.
//
// What the AI sees: descriptions of cards the group agreed on (already shown to every member as "Everyone's in" or
// "Most are in") and descriptions of candidate cards. It never sees people, names, counts, or anything anyone passed on.
// What the AI returns: which candidate, which one or two agreed cards it resembles, and a short phrase about the find.
// The phrase is kept only if every meaningful word in it comes from the find's own description; the database then
// re-checks the agreed cards and writes the sentence itself. A phrase that fails is replaced by the card's own type, or
// left out. With no match at all it falls back to the plain pick, with no reason shown.
// Body: { plan }. The backend can call it with the x-sync-key header and { plan, uid }; with dry:true it saves nothing
// and returns the reading.
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-key", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const apiKey = () => Deno.env.get("ANTHROPIC_API_KEY") ?? Deno.env.get("CLAUDE_API_KEY") ?? Deno.env.get("CLAUDE_KEY") ?? Deno.env.get("ANTHROPIC_KEY") ?? "";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Card = { id: string; title: string; type: string | null; about: string | null };

let trace = "";
async function ask(prompt: string, max = 220): Promise<string | null> {
  const key = apiKey(); if (!key) { trace = "no key"; return null; }
  for (const [model, off] of [["claude-haiku-5-5", true], ["claude-haiku-5-5", false], ["claude-haiku-4-5", false]] as [string, boolean][]) {
    try {
      const body: Record<string, unknown> = { model, max_tokens: off ? max : max + 2500, messages: [{ role: "user", content: prompt }] }; if (off) body.thinking = { type: "disabled" };
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" }, body: JSON.stringify(body) });
      if (!r.ok) { trace += ` ${model}:${r.status}`; continue; }
      const d = await r.json(); const t = (d.content ?? []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("").trim(); if (t) return t;
    } catch (_) { /* next */ }
  }
  return null;
}

const line = (c: Card) => `${c.title}${c.type ? ` (${c.type})` : ""}${c.about ? `: ${c.about}` : ""}`.replace(/\s+/g, " ").slice(0, 260);
const words = (s: string) => s.toLowerCase().match(/[a-z0-9']+/g) ?? [];
const SMALL = new Set(["with", "that", "this", "from", "into", "over", "your", "their", "where", "when", "while", "through", "around", "inside", "about", "more", "some", "also", "then", "than", "each", "them", "they", "have", "been", "being", "there", "here", "what", "which", "another", "place", "spot"]);
// A phrase is kept only if it says nothing the find's own description does not: every word of four letters or more
// (bar small joining words) and every number must be in that description.
export function linkOk(link: string, pick: Card): boolean {
  const l = link.trim();
  if (l.length < 8 || l.length > 70 || /["\n\r]/.test(l) || /\blike\b/i.test(l)) return false;
  const have = words(`${pick.title} ${pick.type ?? ""} ${pick.about ?? ""}`);
  const stem = (w: string) => w.slice(0, Math.max(4, Math.min(w.length - 1, 6)));
  for (const w of words(l)) {
    if (/\d/.test(w)) { if (!have.includes(w)) return false; continue; }
    if (w.length < 4 || SMALL.has(w)) continue;
    if (!have.some((h) => h === w || (h.length >= 4 && (h.startsWith(stem(w)) || w.startsWith(stem(h)))))) return false;
  }
  return words(l).length >= 2 && words(l).length <= 12;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const a = await req.json().catch(() => ({}));
    const plan = String(a.plan ?? ""); if (!UUID.test(plan)) return json({ ok: false, why: "plan" }, 400);
    // Who is asking: a signed-in person (their own token), or the backend itself with the sync key, on behalf of a member.
    let uid = "", backend = false;
    const sk = req.headers.get("x-sync-key");
    if (sk) { const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle(); backend = !!sec?.value && sk === sec.value; if (backend && UUID.test(String(a.uid ?? ""))) uid = String(a.uid); }
    else { const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, ""); const { data: u } = await sb.auth.getUser(token); uid = u?.user?.id ?? ""; }
    if (!uid) return json({ ok: false, why: "signin" }, 401);

    const { data: brief, error } = await sb.rpc("_fr_match_brief", { p_plan: plan, p_uid: uid });
    if (error) return json({ ok: false, why: "error" });
    if (!brief?.ok) return json({ ok: true, added: false, why: brief?.why ?? "not_due" });
    const liked = (brief.liked ?? []) as Card[], cands = (brief.cands ?? []) as Card[];

    let pick: Card | null = null, like: string[] = [], link = "", note = "no reading", raw = ""; trace = "";
    if (cands.length && liked.length >= 2) {
      const L = "ABCDEFGHIJKL";
      const ans = await ask(`A group of friends is planning a trip to ${brief.city}. These are things to do there that the group agreed on:\n` +
        liked.map((c, i) => `${L[i]}. ${line(c)}`).join("\n") +
        `\n\nThese are other things to do there that the group has not seen yet:\n` + cands.map((c, i) => `${i + 1}. ${line(c)}`).join("\n") +
        `\n\nPick the ONE numbered item that best fits what the group agreed on. Reply with one JSON object and nothing else, no words before or after it:\n` +
        `{"pick": the number, or 0 if nothing really resembles what they agreed on, "like": [the letters of the one or two agreed items it most resembles], ` +
        `"link": "3 to 9 words saying what the picked item is, in the way it resembles them"}\n` +
        `Rules for "link": copy its words from the picked item's own description above (its type and the sentence after the colon); do not add any word that is not there, ` +
        `not even a fair summary such as "historic" when the description only gives a year. No place names, no opinions, and not the word "like". Example: "a quiet garden with stone ledges and calm water".`);
      raw = (ans ?? "").slice(0, 300);
      let o: any = null; try { o = JSON.parse(((ans ?? "").match(/\{[\s\S]*\}/) ?? ["null"])[0]); } catch (_) { o = null; }
      if (o) {
        const n = Number(o.pick) || 0; const p = n >= 1 && n <= cands.length ? cands[n - 1] : null;
        const lk = [...new Set((Array.isArray(o.like) ? o.like : []).map((x: unknown) => L.indexOf(String(x).trim().toUpperCase().slice(0, 1))).filter((i: number) => i >= 0 && i < liked.length))].slice(0, 2) as number[];
        const ln = String(o.link ?? "").trim().replace(/[\s.,;:!]+$/, "");
        if (!p) note = "nothing resembled what they agreed on";
        else if (!lk.length) note = "no agreed card named";
        else {   // the pick stands; a phrase that is not backed by the description is dropped for the card's own type, or nothing
          pick = p; like = lk.map((i) => liked[i].id);
          if (linkOk(ln, p)) { link = ln; note = "matched"; } else { link = p.type ?? ""; note = `matched; phrase dropped, not backed by the description: ${ln.slice(0, 80)}`; }
        }
      }
    }
    if (a.dry && backend) return json({ ok: true, dry: true, note, raw, trace, pick: pick?.title ?? null, link, like: like.map((id) => liked.find((c) => c.id === id)?.title) });
    const { data: saved } = await sb.rpc("_fr_match_save", { p_plan: plan, p_card: pick?.id ?? null, p_link: link || null, p_like: like.length ? like : null });
    return json({ ok: true, added: !!saved?.added, matched: !!saved?.matched });
  } catch (_) { return json({ ok: false, why: "error" }); }
});
