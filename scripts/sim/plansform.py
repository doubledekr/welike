import asyncio, json, sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
async def main():
  async with async_playwright() as p:
    for path in ['l','t']:
      ph=Phone('pf_'+path); await ph.start(p,path=path,extra="window.__SS=[]; const _s=window.__TCR.set_settings; window.__TCR.set_settings = a => { window.__SS.push(a.p_settings); return {...(a.p_settings||{})}; };"); await ph.see(CLEAN); await ph.pg.wait_for_timeout(300)
      await ph.tap('text=not now',must=False,wait=400)
      ok=await ph.tap('[aria-label*=ettings]',wait=1200)
      a=await ph.see("(()=>{const b=[...document.querySelectorAll('[data-pset^=\"pd|\"]')]; if(!b.length) return 'no chips'; b[0].scrollIntoView({block:'center'}); return {chips:b.map(x=>x.innerText+(x.classList.contains('on')?'*':'')), fri:getComputedStyle(document.querySelector('.pfri')).display, note:document.querySelector('.ycard .note b')?.innerText}})()")
      print(path,ok,a)
      await ph.tap('[data-pset="pd|fri"]',wait=300); f1=await ph.see("getComputedStyle(document.querySelector('.pfri')).display")
      await ph.tap('[data-pset="pd|sun"]',wait=300); f2=await ph.see("getComputedStyle(document.querySelector('.pfri')).display")
      await ph.pg.screenshot(path=f'/tmp/h/sim/shots/pf_{path}.png')
      await ph.tap('text=save weekend plans',wait=900)
      print('  fri shows:',f1,'| sun hides:',f2,'| saved:',await ph.see("JSON.stringify(window.__SS)"),'| note now:',await ph.see("document.querySelector('.ycard .note b')?.innerText"),'errs',ph.errs)
      await ph.close()
asyncio.run(main())
