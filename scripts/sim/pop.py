import asyncio,sys,json
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
X="window.__pop=1; window.__TCR=window.__TCR||{}; window.__TCR.plan_pop_back=()=>{ const s=window.__sat; s.pop={...s.pop,back:true}; return s; };"
async def main():
  async with async_playwright() as p:
    for path in ('l','t'):
      ph=Phone('pop_'+path); await ph.start(p,at='2026-11-19T20:00:00-05:00',path=path,extra=X); await ph.see(CLEAN)
      await ph.see("(()=>{const b=[...document.querySelectorAll('[data-pl]')].find(x=>/p-sat/.test(x.dataset.pl)); if(b){b.click();return 1} return 0})()"); await ph.pg.wait_for_timeout(900)
      if not await ph.see("!!document.querySelector('.sheet')"):
        await ph.tap('text=plan a day',wait=1100,must=False); await ph.see("[...document.querySelectorAll('[data-pl]')].find(x=>/view\\|p-sat|p-sat/.test(x.dataset.pl))?.click()"); await ph.pg.wait_for_timeout(1100)
      t=(await ph.see("(document.querySelector('.sheet')||{}).innerText||''")).replace('\n',' | ')
      pop=await ph.see("JSON.stringify({pop:(document.querySelector('.ppop')||{}).innerText||null, vis:(()=>{const b=document.querySelector('[data-pl^=popback]'); if(!b) return null; const r=b.getBoundingClientRect(); return [Math.round(r.width),Math.round(r.height)]})()})")
      a=await ph.audit('pop',shot=True); print(path,'| sheet:',t[:200],'\n   pop block:',pop,'small',a['small'],'coral',a['coral'])
      await ph.tap('[data-pl^=popback]',wait=1300,must=False)
      print('   after put back:', await ph.see("JSON.stringify({pop:!!document.querySelector('.ppop'), toast:(document.querySelector('.toast')||{}).innerText||null})"),'errs',ph.errs); await ph.close()
asyncio.run(main())
