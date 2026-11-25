import asyncio, json, sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
async def run(p,name,at,steps,path='t'):
    ph=Phone(name); await ph.start(p,at=at,path=path); await ph.see(CLEAN); await ph.pg.wait_for_timeout(300)
    for sx in steps:
        if sx.startswith('swipe:'): await ph.swipe(sx[6:])
        elif sx.startswith('js:'): await ph.see(sx[3:]); await ph.pg.wait_for_timeout(700)
        else: await ph.tap(sx,wait=1200,must=False)
    a=await ph.audit(name,shot=True)
    print(name,'small',a['small'][:4],'coral',a['coral'],'trunc',a['trunc'][:3],'errs',ph.errs,'|',' / '.join(a['labels'][:26])[:420])
    await ph.close()
async def main():
  async with async_playwright() as p:
    await run(p,'r_likes','2026-11-17T20:30:00-05:00',['text=likes'])
    await run(p,'r_tonight6','2026-11-20T18:00:00-05:00',['text=tonight'])
    await run(p,'r_tonight2','2026-11-20T14:00:00-05:00',['text=tonight'])
    await run(p,'r_sat3','2026-11-21T15:00:00-05:00',['.home.one>.slot [data-pl],.home.one>.slot button'])
    await run(p,'r_sat9','2026-11-21T20:30:00-05:00',['.home.one>.slot [data-pl],.home.one>.slot button'])
    await run(p,'r_undo','2026-11-22T20:00:00-05:00',['swipe:right','text=tonight'])
    await run(p,'r_livehome','2026-11-17T20:30:00-05:00',[],path='l')
    await run(p,'r_livetrips','2026-11-22T20:00:00-05:00',['.dock button[aria-label*=Trips]'],path='l')
asyncio.run(main())
