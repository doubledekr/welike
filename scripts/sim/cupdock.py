import asyncio,sys,json,re
sys.path.insert(0,'/tmp/h/sim'); from lib import *
src=open('/tmp/h/sim/cup.py').read(); STUB=re.search(r'STUB="""(.*?)"""',src,re.S).group(1)
src2=open('/tmp/h/sim/overflow.py').read(); SCAN=re.search(r'SCAN="""(.*?)"""',src2,re.S).group(1)
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
async def main():
  async with async_playwright() as p:
    for path in ('l','t'):
      ph=Phone('cd_'+path); await ph.start(p,at='2026-11-25T21:00:00-05:00',path=path,extra=STUB); await ph.see(CLEAN); await ph.pg.wait_for_timeout(400)
      dock=await ph.see("JSON.stringify([...document.querySelectorAll('.dock button')].map(b=>b.innerText.trim()||b.getAttribute('aria-label')))")
      await ph.audit('home',shot=True)
      if True:
        await ph.tap('.dock [data-act=cup]',wait=1200); h=await ph.see("(document.querySelector('.sheet h2')||{}).innerText||null")
        await ph.see(CLEAN); await ph.tap('.dock [data-act=likes]',wait=1200); fav=await ph.see("!!document.querySelector('.lact [data-act=favs]')"); a=await ph.audit('likes',shot=True)
        await ph.tap('.lact [data-act=favs]',wait=1000); fv=await ph.see("(document.querySelector('.topbar h2')||{}).innerText||null")
        print(path,'dock:',dock,'| cup opens:',h,'| Likes has Favorites key:',fav,'small',a['small'],'| key opens:',fv,'| box:',await ph.see(SCAN),'errs',ph.errs)
      else: print(path,'dock:',dock,'errs',ph.errs)
      await ph.close()
asyncio.run(main())
