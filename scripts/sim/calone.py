import asyncio,sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
async def main():
  async with async_playwright() as p:
    ph=Phone('cal1'); await ph.start(p,at='2026-11-27T12:00:00-05:00',path='l',extra="localStorage.setItem('wl_tg2026','1');")
    await ph.see("document.querySelectorAll('.wn,.phero').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''")
    await ph.tap('text=you and settings',wait=1100,must=False)
    row=await ph.see("(document.querySelector('[data-act=calsub]')||{}).innerText||null")
    await ph.tap('[data-act=calsub]',wait=1200); txt=await ph.see("(document.querySelector('.sheet')||{}).innerText||null"); await ph.audit('cal',shot=True)
    print('row:',row,'| sheet:',txt,'| errs',ph.errs); await ph.close()
asyncio.run(main())
