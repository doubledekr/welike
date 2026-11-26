import asyncio,sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
STUB="""localStorage.setItem('wl_allv1','1');localStorage.setItem('wl_deck','movie');localStorage.setItem('wl_lbmode','swipe');localStorage.setItem('wl_tip_watch','1');localStorage.setItem('wl_tg2026','1');
localStorage.setItem('wl_bl',JSON.stringify({d:new Date().toDateString(),n:{movie:2},more:{}}));
window.__TCR=window.__TCR||{}; window.__bm=-100; window.__str=99;"""
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
async def main():
  async with async_playwright() as p:
    for path in ('l','t'):
      ph=Phone('mv_'+path); await ph.start(p,at='2026-11-27T20:00:00-05:00',path=path,extra=STUB); await ph.see(CLEAN); await ph.pg.wait_for_timeout(600)
      seen=[]; steers=0; goal=False; waits=0
      for i in range(90):
        txt=await ph.see("(document.getElementById('stack')||{}).innerText||''")
        if 'Two saved' in txt: goal=True; break
        if await ph.see("!!document.querySelector('#stack .steerc, #stack .gopts')"):
          steers+=1; await ph.see("document.querySelector('#stack .gopt')?.click()"); await ph.pg.wait_for_timeout(300); await ph.see("document.querySelector('[data-act=steerno]')?.click()"); await ph.pg.wait_for_timeout(900); continue
        t=await ph.see("(document.querySelector('#stack .card:not(.under)')||{}).dataset?.id||null")
        if not t:
          waits+=1; await ph.pg.wait_for_timeout(700)
          if waits>8: break
          continue
        seen.append(t); await ph.swipe('left' if i%3 else 'right',wait=450)
      print(path,'cards:',len(seen),'steering cards:',steers,'two-likes stop:',goal,'stalls:',waits,'last:',seen[-3:],'errs',ph.errs)
      await ph.audit('end',shot=True); await ph.close()
asyncio.run(main())
