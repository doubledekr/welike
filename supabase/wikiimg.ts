// Wikipedia lead photos, only when they are good enough for a card (Dave, 20 Nov): a real photo (JPEG), at least
// 1200 px wide and 700 px tall, not a strip or a sliver, and under a free licence (public domain, CC0, CC BY, CC BY-SA),
// never a non-free (fair use) file. Each comes back with its credit line, which the card shows.
const UA = { "User-Agent": "LetsTogether/1.0 (https://letstogether.app)" };
const strip = (s: string) => String(s || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();
export type WikiImg = { url: string; credit: string; w: number; h: number };
export async function wikiImages(pageids: (number | string)[]): Promise<Map<number, WikiImg>> {
  const out = new Map<number, WikiImg>(); const files = new Map<string, number>();
  for (let i = 0; i < pageids.length; i += 40) {
    try {
      const r = await fetch(`https://en.wikipedia.org/w/api.php?action=query&prop=pageimages&piprop=name%7Coriginal&format=json&pageids=${pageids.slice(i, i + 40).join("%7C")}`, { headers: UA });
      const d = await r.json();
      for (const p of Object.values(d?.query?.pages ?? {}) as any[]) {
        const o = p.original, nm = String(p.pageimage || "");
        if (!o || !nm || !/\.jpe?g$/i.test(nm)) continue;
        const ratio = o.width / Math.max(1, o.height);
        if (o.width < 1200 || o.height < 700 || ratio < 0.6 || ratio > 2.2) continue;
        files.set("File:" + nm.replace(/_/g, " "), Number(p.pageid));
      }
    } catch (_) { /* that batch keeps its Google photo */ }
  }
  const names = [...files.keys()];
  for (let i = 0; i < names.length; i += 25) {
    try {
      const r = await fetch(`https://en.wikipedia.org/w/api.php?action=query&prop=imageinfo&iiprop=url%7Csize%7Cextmetadata&iiurlwidth=1200&format=json&titles=${names.slice(i, i + 25).map(encodeURIComponent).join("%7C")}`, { headers: UA });
      const d = await r.json();
      const norm = new Map<string, string>(); for (const n of (d?.query?.normalized ?? [])) norm.set(n.to, n.from);
      for (const p of Object.values(d?.query?.pages ?? {}) as any[]) {
        const ii = p.imageinfo?.[0]; if (!ii) continue;
        const md = ii.extmetadata || {}, lic = strip(md.LicenseShortName?.value), nonfree = String(md.NonFree?.value || "").toLowerCase() === "true";
        if (nonfree || !/^(public domain|pd|cc0|cc by(-sa)?( \d(\.\d)?)?)/i.test(lic)) continue;
        const pid = files.get(p.title) ?? files.get(norm.get(p.title) || ""); if (pid == null) continue;
        const artist = strip(md.Artist?.value).slice(0, 60);
        out.set(pid, { url: ii.thumburl || ii.url, w: ii.thumbwidth || ii.width, h: ii.thumbheight || ii.height, credit: `Photo: ${artist ? artist + ", " : ""}${lic}, via Wikimedia Commons` });
      }
    } catch (_) { /* keep going */ }
  }
  return out;
}
