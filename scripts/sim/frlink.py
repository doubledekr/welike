import asyncio,sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
async def main():
  async with async_playwright() as p:
    ph=Phone('frl'); await ph.start(p,at='2026-11-27T12:00:00-05:00',path='l/?f=JOE123&x=',extra="localStorage.setItem('wl_tg2026','1');")
    h=await ph.see("(document.querySelector('.sheet h2')||{}).innerText||null"); t=await ph.see("(document.querySelector('.sheet .muted')||{}).innerText||null")
    pend=await ph.see("localStorage.getItem('wl_fpend')"); a=await ph.audit('invite',shot=True)
    print('sheet:',h,'|',t,'| pending:',pend,'| errs',ph.errs); await ph.close()
    ph=Phone('frl2'); await ph.start(p,at='2026-11-27T12:00:00-05:00',path='l',extra="localStorage.setItem('wl_tg2026','1');")
    print('no link -> sheet:',await ph.see("(document.querySelector('.sheet h2')||{}).innerText||null"),'errs',ph.errs); await ph.close()
asyncio.run(main())
