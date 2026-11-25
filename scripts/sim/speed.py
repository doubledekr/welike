import asyncio,sys,json
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
DELAY="window.__delay=()=>700;"
async def main():
  async with async_playwright() as p:
    for path in ('t','l'):
      ph=Phone('speed_'+path); await ph.start(p,at='2026-11-25T13:00:00-05:00',path=path,extra='window.__here=1;'); await ph.see(CLEAN); await ph.pg.wait_for_timeout(300)
      await ph.tap('text=you and settings',wait=1200,must=False)
      await ph.see(DELAY)
      # back to home: time until the home view is on screen
      r=await ph.see("""(async()=>{const b=document.querySelector('.back,[data-tab=home],[data-act=home]'); const t0=performance.now(); b.click(); let seen=null,bar=false,pulse=false; for(let i=0;i<200;i++){ await new Promise(r=>setTimeout(r,20)); if(document.body.classList.contains('tapbar')) bar=true; if(document.querySelector('.tapw')) pulse=true; if(document.querySelector('.home')){ seen=Math.round(performance.now()-t0); break; } } return JSON.stringify({home_ms:seen,bar,pulse}); })()""")
      print(path,'back to home with 700ms network:',r)
      await ph.pg.wait_for_timeout(1800); print('  here html:', await ph.see("(document.querySelector('#herep')||{}).innerText||(document.querySelector('.herep')||{}).innerText||null"))
      # swipe ten together
      r2=await ph.see("""(async()=>{ const b=document.querySelector('[data-act=liveten]'); if(!b) return 'no here button'; const t0=performance.now(); b.click(); await new Promise(r=>setTimeout(r,60)); const lab=b.textContent, dis=b.disabled; let bar=false,seen=null; for(let i=0;i<300;i++){ await new Promise(r=>setTimeout(r,20)); if(document.body.classList.contains('tapbar')) bar=true; if(!document.querySelector('.home')||document.querySelector('.toast')){ seen=Math.round(performance.now()-t0); break; } } return JSON.stringify({label_at_60ms:lab,disabled:dis,bar,done_ms:seen,toast:(document.querySelector('.toast')||{}).innerText||null}); })()""")
      print(path,'swipe ten:',r2,'errs',ph.errs)
      await ph.close()
asyncio.run(main())
