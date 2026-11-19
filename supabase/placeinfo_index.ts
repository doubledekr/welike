import { createClient } from "npm:@supabase/supabase-js@2";

// Two jobs, both for day plans.
// 1. Fill in where a saved place is, its opening hours and its main category, for cards saved before those were kept.
//    Only places somebody has liked are looked up (liked by both first), a few per call, so the cost follows real use.
//    With "any": true, places the weekend planner may also use (well rated, not yet liked) are filled in too, after
//    the liked ones: the planner never places somewhere whose hours are unknown.
//    Body: { code, limit? }  or, with the x-sync-key header, { all: true, any?: true, limit? } to sweep every couple.
// 2. Check a plan against the real opening hours for its date (Google publishes the next seven days, holidays and
//    special hours included). Anything that will be closed, or closes before the visit is over, is saved on the plan.
//    Body: { code, plan }  or, with the x-sync-key header, { plan, notify: true } to also tell both people.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
function packHours(h: any): unknown {
  const ps = h?.periods; if (!Array.isArray(ps) || !ps.length) return null;
  if (ps.length === 1 && ps[0].open && !ps[0].close) return "always";
  const out: number[][] = [];
  for (const p of ps) { const o = p.open, c = p.close; if (!o || !c) continue; out.push([o.day ?? 0, (o.hour ?? 0) * 100 + (o.minute ?? 0), c.day ?? 0, (c.hour ?? 0) * 100 + (c.minute ?? 0)]); }
  return out.length ? out : null;
}
const STAY: Record<string, number> = { day: 120, dinner: 90 };   // minutes; everything else an hour
// Wall-clock minutes, with no time zone involved: Google gives each period's date and time in the place's own time.
const wall = (y: number, m: number, d: number, h = 0, mi = 0) => Date.UTC(y, m - 1, d, h, mi) / 60000;
// The planner also uses places neither person has swiped yet when they are well rated (see _ap_pick).
const plannable = (c: any) => Number(c.data?.rating ?? 0) >= 4.4 && Number(c.data?.ratings ?? c.data?.reviews ?? 0) >= 50;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const key = Deno.env.get("GOOGLE_PLACES_KEY");
    if (!key) return json({ error: "no_key" }, 503);
    const body = await req.json().catch(() => ({}));
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const synced = async () => { const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "sync_key").maybeSingle(); return !!sec?.value && req.headers.get("x-sync-key") === sec.value; };

    if (body.plan) {
      const { data: plan } = await sb.from("plans").select("id,couple_id,day,items,closed,status,mode").eq("id", String(body.plan)).maybeSingle();
      if (!plan) return json({ error: "bad_plan" }, 404);
      const { data: couple } = await sb.from("couples").select("id,code").eq("id", plan.couple_id).maybeSingle();
      if (!couple) return json({ error: "bad_plan" }, 404);
      if (!(await synced()) && String(body.code ?? "").trim().toUpperCase() !== couple.code) return json({ error: "forbidden" }, 403);
      const [y, m, d] = String(plan.day).split("-").map(Number);
      const days = (wall(y, m, d) - Date.now() / 60000) / 1440;
      if (days > 6.5 || days < -1) return json({ ok: true, skipped: "too_far", closed: plan.closed ?? [] });   // only the coming week is published
      const items = ((plan.items ?? []) as any[]).filter((i) => typeof i.card === "string");
      const { data: cards } = await sb.from("cards").select("id,title,data,event_date").in("id", items.map((i) => i.card));
      const closed: string[] = [], names: string[] = [];
      let checked = 0;
      await Promise.all(items.map(async (it) => {
        const c = ((cards ?? []) as any[]).find((x) => x.id === it.card);
        if (!c?.data?.place_id || !/^\d{2}:\d{2}$/.test(String(it.time ?? ""))) return;
        try {
          const r = await fetch(`https://places.googleapis.com/v1/places/${encodeURIComponent(c.data.place_id)}`, { headers: { "X-Goog-Api-Key": key, "X-Goog-FieldMask": "currentOpeningHours,businessStatus" } });
          const p = await r.json();
          if (!r.ok) return;
          checked++;
          if (p.businessStatus && p.businessStatus !== "OPERATIONAL") { closed.push(c.id); names.push(c.title); return; }
          const ps = p.currentOpeningHours?.periods;
          if (!Array.isArray(ps) || !ps.length) return;   // no hours published: nothing to go on
          const [hh, mm] = String(it.time).split(":").map(Number), from = wall(y, m, d, hh, mm), to = from + (STAY[it.slot] ?? 60);
          const open = ps.some((q: any) => {
            const o = q.open, cl = q.close; if (!o?.date) return false;
            const a = wall(o.date.year, o.date.month, o.date.day, o.hour ?? 0, o.minute ?? 0);
            const b = cl?.date ? wall(cl.date.year, cl.date.month, cl.date.day, cl.hour ?? 0, cl.minute ?? 0) : Infinity;
            return from >= a && to <= b;
          });
          if (!open) { closed.push(c.id); names.push(c.title); }
        } catch (_) { /* leave it unchecked */ }
      }));
      const before = new Set((plan.closed ?? []) as string[]);
      await sb.from("plans").update({ closed, checked_at: new Date().toISOString() }).eq("id", plan.id);
      const fresh = closed.filter((id) => !before.has(id));
      if (body.notify && fresh.length && ["sent", "agreed"].includes(plan.status)) {
        await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/nudge`, { method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ code: couple.code, member: "-", kind: "plan", title: "Heads up about tomorrow’s plan", plan: plan.id,
            body: `${names[0].split(",")[0]}${names.length > 1 ? " and " + (names.length - 1) + " more" : ""} will not be open at the time you planned. Open the plan to swap it or move the time.`, url: `./?plan=${plan.id}` }) }).catch(() => {});
      }
      return json({ ok: true, checked, closed });
    }

    let couples: any[] = [];
    if (body.all) {
      if (!(await synced())) return json({ error: "forbidden" }, 403);
      const { data } = await sb.from("couples").select("id");
      couples = (data ?? []) as any[];
    } else {
      const { data: c } = await sb.from("couples").select("id").eq("code", String(body.code ?? "").trim().toUpperCase()).maybeSingle();
      if (!c) return json({ error: "bad_code" }, 403);
      couples = [c];
    }
    const any = body.any === true && body.all === true;
    const limit = Math.min(Math.max(Number(body.limit) || 12, 1), body.all ? 60 : 20);
    const today = new Date().toISOString().slice(0, 10);
    let done = 0, failed = 0, left = 0;
    for (const cp of couples) {
      if (done >= limit) break;
      const { data: cards } = await sb.from("cards").select("id,data").eq("couple_id", cp.id).in("deck", ["dinner", "event"]).eq("active", true)
        .not("data->>place_id", "is", null).is("data->>hours_at", null).limit(600);
      const cand = (cards ?? []) as any[];
      if (!cand.length) continue;
      const { data: sw } = await sb.from("swipes").select("card_id,member,verdict,created_at").eq("couple_id", cp.id).in("verdict", ["yes", "love"]).in("card_id", cand.map((c) => c.id).slice(0, 600));
      const likes = new Map<string, Set<string>>();
      for (const s of (sw ?? []) as any[]) { if (!likes.has(s.card_id)) likes.set(s.card_id, new Set()); likes.get(s.card_id)!.add(s.member); }
      const liked = cand.filter((c) => likes.has(c.id) || (any && plannable(c)))
        .sort((a, b) => (likes.get(b.id)?.size ?? 0) - (likes.get(a.id)?.size ?? 0));
      left += Math.max(0, liked.length - (limit - done));
      const take = liked.slice(0, limit - done);
      await Promise.all(take.map(async (c) => {
        try {
          const r = await fetch(`https://places.googleapis.com/v1/places/${encodeURIComponent(c.data.place_id)}`, { headers: { "X-Goog-Api-Key": key, "X-Goog-FieldMask": "location,regularOpeningHours,primaryType,servesDinner" } });
          const p = await r.json();
          if (!r.ok) { failed++; return; }
          const data: Record<string, unknown> = { ...c.data, hours: packHours(p.regularOpeningHours), hours_at: today };
          if (p.location) { data.lat = p.location.latitude; data.lng = p.location.longitude; }
          if (p.primaryType) data.ptype = p.primaryType;
          if (typeof p.servesDinner === "boolean") data.dinner = p.servesDinner;
          const { error } = await sb.from("cards").update({ data }).eq("id", c.id);
          if (error) failed++; else done++;
        } catch (_) { failed++; }
      }));
    }
    return json({ ok: true, done, failed, left });
  } catch (e) {
    return json({ error: String(e) }, 400);
  }
});
