import asyncio,sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
async def main():
  async with async_playwright() as p:
    for path in ('t','l'):
      ph=Phone('apple_'+path); await ph.start(p,at='2026-11-25T13:00:00-05:00',path=path); await ph.see(CLEAN)
      await ph.tap('text=you and settings',wait=1100,must=False)
      row=await ph.see("!!document.querySelector('[data-act=acct]')")
      if row: await ph.see("document.querySelector('[data-act=acct]').click()"); await ph.pg.wait_for_timeout(900)
      r=await ph.see("JSON.stringify({sheet:(document.querySelector('.sheet h2')||{}).innerText||null,apple:!!document.querySelector('[data-act=acctapple]'),txt:(document.querySelector('[data-act=acctapple]')||{}).innerText||null,h:(document.querySelector('[data-act=acctapple]')||{getBoundingClientRect:()=>({height:0})}).getBoundingClientRect().height})")
      print(path,'acct row',row,r,ph.errs); await ph.audit('apple',shot=True); await ph.close()
asyncio.run(main())
