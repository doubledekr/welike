import asyncio,sys,json
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
STUB="window.__TCR=window.__TCR||{}; window.__TCR.plan_side_likes=()=>[{id:'c-a',title:'Two Birds',who:'Ace',deck:'event',kind:'Bar',image:null,data:{place:true,lat:42.33,lng:-83.05}},{id:'c-b',title:'Bar Pigalle',who:'Bee',deck:'event',kind:'Bar',image:null,data:{place:true,lat:42.34,lng:-83.05}}];"
async def main():
  async with async_playwright() as p:
    ph=Phone('pick'); await ph.start(p,at='2026-11-19T20:00:00-05:00',path='l',extra=STUB); await ph.see(CLEAN)
    await ph.tap('text=look closer',wait=1200,must=False); await ph.tap('text=pick',wait=1500,must=False)
    t=(await ph.see("(document.querySelector('.sheet')||{}).innerText||''")).replace('\n',' | '); a=await ph.audit('pick',shot=True)
    print('pick sheet:',t[:520],'\n names shown:', 'Ace liked' in t, 'You liked' in t, '| small',a['small'],'errs',ph.errs); await ph.close()
    ph=Phone('w11'); await ph.start(p,at='2026-11-25T17:10:00-05:00',path='l'); await ph.pg.wait_for_timeout(2500)
    pages=[]
    for i in range(5):
      t=await ph.see("(document.querySelector('.wn.wk .wk-h')||{}).innerText||null")
      if not t: break
      pages.append(t); await ph.pg.screenshot(path=f'/tmp/w11_{i}.png'); await ph.tap('.wn.wk .btn',wait=800,must=False)
    print("what's new pages:",pages,'errs',ph.errs); await ph.close()
asyncio.run(main())
