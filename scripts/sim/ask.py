import asyncio, json, sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
async def main():
  async with async_playwright() as p:
    for at,tag,path in [('2026-11-19T20:00:00-05:00','thu','t'),('2026-11-21T10:00:00-05:00','sat','t'),('2026-11-19T20:00:00-05:00','live','l')]:
      ph=Phone('ask_'+tag); await ph.start(p,at=at,path=path); await ph.see(CLEAN); await ph.pg.wait_for_timeout(400)
      a=await ph.audit('ask')
      fit=await ph.see("(()=>{const d=document.querySelector('.stack .done'); return d? {cls:d.className, over:d.scrollHeight-d.clientHeight, h:d.clientHeight, txt:d.innerText.replace(/\\s+/g,' ').slice(0,150)}:null})()")
      print(tag, fit, 'n',a['n'],'small',a['small'],'coral',a['coral'],'zones',a['zones'])
      if path=='t' and tag=='thu':
        await ph.tap('text=not now'); a=await ph.audit('after not now'); print('  after not now:', await ph.see("document.querySelector('.stack .done')?.className||'pile:'+document.querySelectorAll('#stack .card').length"))
        await ph.pg.reload(); await ph.pg.wait_for_timeout(3800); await ph.see(CLEAN); await ph.pg.wait_for_timeout(300); print('  after reload same day:', await ph.see("document.querySelector('.stack .done')?.className||'pile:'+document.querySelectorAll('#stack .card').length"))
      if tag=='sat':
        await ph.tap('text=i’m in',wait=1800); print('  after in:', await ph.see("(document.querySelector('.stack .done')?.className||'pile:'+document.querySelectorAll('#stack .card').length)+' | toast:'+(document.querySelector('.toast')?.innerText||'')+' | calls:'+JSON.stringify((window.__calls||[]).slice(-6).map(c=>Array.isArray(c)?c[0]:c))"), ph.steps[-1])
      print('  errs',ph.errs); await ph.close()
asyncio.run(main())
