import asyncio,sys,json
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
REC="window.__args=[]; window.__delay=(fn,a)=>{ if(/start_all|start_bite/.test(fn)) window.__args.push(fn+':'+JSON.stringify(a.p_opts||null)+':'+(a.p_deck||'')); return window.__lat||0; };"
async def one(p,path):
    ph=Phone('rel3_'+path); await ph.start(p,at='2026-11-25T17:00:00-05:00',path=path,extra=REC); await ph.see(CLEAN); await ph.pg.wait_for_timeout(4500)   # let the warm-up run
    warm=await ph.see("JSON.stringify({args:window.__args, dc:Object.keys(window.__S?.dc||{})})")
    await ph.see("window.__lat=700")
    sw=await ph.see("""(async()=>{ const b=[...document.querySelectorAll('[data-hdeck]')].find(x=>x.dataset.hdeck==='movie'); const before=(document.querySelector('#stack .card h2,#stack .card .ttl,#stack .card')||{}).innerText; const t0=performance.now(); b.click(); let ms=null; for(let i=0;i<150;i++){ await new Promise(r=>setTimeout(r,20)); const now=(document.querySelector('#stack .card h2,#stack .card .ttl,#stack .card')||{}).innerText; if(now && now!==before){ ms=Math.round(performance.now()-t0); break; } } return JSON.stringify({watch_ms:ms}); })()""")
    await ph.see("window.__lat=0"); await ph.pg.wait_for_timeout(900)
    await ph.tap('text=you and settings',wait=1100,must=False)
    you=await ph.see("JSON.stringify({cal:!!document.querySelector('[data-act=calsub]'),acct:!!document.querySelector('[data-act=acct]'),friends:!!document.querySelector('[data-fr=open]')})")
    print(path,'| piles asked:',warm,'| switch to Watch on a 700ms network:',sw,'| You page:',you,'| errs',ph.errs); await ph.close()
async def plan(p,path):
    ph=Phone('rel3p_'+path); await ph.start(p,at='2026-11-19T20:00:00-05:00',path=path); await ph.see(CLEAN)
    await ph.tap('text=look closer',wait=1200,must=False); await ph.tap('text=more options',wait=900,must=False)
    r=await ph.see("JSON.stringify({cal:(document.querySelector('.pcal')||{}).innerText||null, href:((document.querySelector('.pcal')||{}).href||'').replace(/^.*functions/,'…/functions').slice(0,60)})")
    a=await ph.audit('plan',shot=True); print(path,'plan sheet calendar link:',r,'small',a['small'],'errs',ph.errs); await ph.close()
async def main():
  async with async_playwright() as p:
    for path in ('n','l'): await one(p,path)
    pass
asyncio.run(main())
