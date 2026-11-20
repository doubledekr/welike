// AI call log (Dave, 19 Nov): every Anthropic call an edge function makes is written to the ai_calls table with the
// model, input and output tokens, cached tokens, web searches, time taken and whether it worked. It wraps fetch once per
// function, so the calls themselves are unchanged. Logging never blocks or breaks the call: failures are ignored.
// Use: import { logAi } from "./ai_log.ts"; logAi("gems");
export function logAi(fn: string) {
  const g = globalThis as any; if (g.__aiLog) return; g.__aiLog = true;
  const raw = globalThis.fetch.bind(globalThis);
  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  globalThis.fetch = (async (input: any, init?: any) => {
    const u = typeof input === "string" ? input : input?.url ?? String(input);
    if (!u.startsWith("https://api.anthropic.com/") || !url || !key) return raw(input, init);
    const t0 = Date.now(); let model = "";
    try { model = JSON.parse(String(init?.body ?? "{}")).model ?? ""; } catch (_) { /* no body */ }
    const res = await raw(input, init);
    const p = res.clone().json().catch(() => ({})).then((d: any) => {
      const us = d?.usage ?? {};
      return raw(`${url}/rest/v1/ai_calls`, { method: "POST",
        headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json", Prefer: "return=minimal" },
        body: JSON.stringify({ fn, model: d?.model ?? model, in_tok: us.input_tokens ?? null, out_tok: us.output_tokens ?? null,
          cache_tok: us.cache_read_input_tokens ?? null, searches: us.server_tool_use?.web_search_requests ?? null,
          ms: Date.now() - t0, ok: res.ok, note: res.ok ? null : String(d?.error?.message ?? res.status).slice(0, 200) }) });
    }).catch(() => {});
    try { g.EdgeRuntime?.waitUntil?.(p); } catch (_) { /* fine */ }
    return res;
  }) as typeof fetch;
}
