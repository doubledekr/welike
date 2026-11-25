import asyncio, json, sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
def br(a): return {k:a[k] for k in ['n','small','coral','caps','scr']}
async def main():
  async with async_playwright() as p:
    for at,tag,path in [('2026-11-21T10:00:00-05:00','sat','t'),('2026-11-19T20:00:00-05:00','thu','t'),('2026-11-21T10:00:00-05:00','live','l')]:
      ph=Phone('calm_'+tag); await ph.start(p,at=at,path=path); await ph.see(CLEAN); await ph.pg.wait_for_timeout(400)
      await ph.tap('text=look closer' if path=='t' else '[data-pl^="view|"]',wait=1500); a=await ph.audit('plan closed'); print(tag,'closed',br(a)); print('   ',' | '.join(a['labels'])[:500])
      if path=='t':
        await ph.tap('.pcalm .pstop:nth-child(2) .grow b',label='tap a stop',wait=500); a=await ph.audit('stop open'); print(tag,'open',br(a)); print('   ',' | '.join(a['labels'])[:600])
        await ph.tap('text=more options',wait=600); a=await ph.audit('more'); print(tag,'more',br(a)); print('   ',' | '.join(a['labels'])[-400:])
      print('  errs',ph.errs); await ph.close()
asyncio.run(main())
