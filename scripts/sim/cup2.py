import asyncio,sys,re
sys.path.insert(0,'/tmp/h/sim'); from lib import *
src=open('/tmp/h/sim/cup.py').read(); STUB=re.search(r'STUB="""(.*?)"""',src,re.S).group(1)
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
async def main():
  async with async_playwright() as p:
    ph=Phone('cup2'); await ph.start(p,at='2026-11-25T21:00:00-05:00',path='t',extra=STUB); await ph.see(CLEAN)
    out=[]
    for i in range(4):
      await ph.tap('.dock [data-act=cup]',wait=900,must=False)
      out.append(await ph.see("(document.querySelector('.sheet h2')||{}).innerText||'NOTHING'"))
      await ph.see("document.querySelector('.scrim')?.click()"); await ph.pg.wait_for_timeout(700)
      if i==1: await ph.tap('.dock [data-act=likes]',wait=900,must=False); await ph.see("document.querySelector('.back')?.click()"); await ph.pg.wait_for_timeout(700)
    print('four opens:',out,'| key disabled:',await ph.see("document.querySelector('.dock [data-act=cup]').disabled"),'errs',ph.errs); await ph.close()
asyncio.run(main())
