import asyncio, json, sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
Q="""(()=>{const H=innerHeight,W=innerWidth; return [...new Set([...document.querySelectorAll('button,a[href],[data-act],[data-open],[data-pl],[data-sw],[data-hdeck],[role=button]')].filter(e=>{const r=e.getBoundingClientRect(); const t=document.elementFromPoint(Math.min(W-1,Math.max(0,r.left+r.width/2)),Math.min(H-1,Math.max(0,r.top+r.height/2))); return r.width>0&&r.height>0&&(r.width<43.5||r.height<43.5)&&r.top<H&&r.bottom>0&&t&&(t===e||e.contains(t))}).map(e=>e.tagName.toLowerCase()+'.'+[...e.classList].join('.')+(e.dataset.act?'[act='+e.dataset.act+']':'')+' <'+(e.parentElement.className||e.parentElement.id)+'> '+Math.round(e.getBoundingClientRect().width)+'x'+Math.round(e.getBoundingClientRect().height)))]})()"""
async def main():
  async with async_playwright() as p:
    for tag,steps in [('home',[]),('likes',['text=likes']),('you',['text=you and settings']),('trips',['.dock button[aria-label*=Trips]']),('tonight',['text=tonight']),('planday',['text=plan a day']),('inbox',['text=inbox']),('crew',['text=crew']),('fav',['text=favorites']),('swiped',['swipe:right'])]:
      ph=Phone('sm_'+tag); await ph.start(p,at='2026-11-19T20:00:00-05:00'); await ph.see(CLEAN+";localStorage.setItem('wl_pask','x')"); await ph.pg.wait_for_timeout(300)
      await ph.tap('text=not now',must=False,wait=500)
      for st in steps:
        if st.startswith('swipe:'): await ph.swipe(st[6:])
        else: await ph.tap(st,wait=1200)
      print(tag, await ph.see(Q)); await ph.close()
asyncio.run(main())
