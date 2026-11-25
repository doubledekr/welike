import asyncio, json, sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
NONEWS="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove());"
Q="(()=>{const b=document.querySelector('.body.tgc'); return b? b.innerText.replace(/\\s+/g,' ') : 'no card'})()"
async def main():
  async with async_playwright() as p:
    for path,at,tag in [('l','2026-11-26T09:30:00-05:00','thanksgiving live'),('t','2026-11-26T19:00:00-05:00','thanksgiving beta'),('l','2026-11-27T09:30:00-05:00','friday'),('l','2026-11-25T20:00:00-05:00','wednesday')]:
      ph=Phone('tg_'+path+tag[:3]); await ph.start(p,path=path,at=at); await ph.see(NONEWS+"const l=document.querySelector('#layer'); if(l) l.innerHTML=''"); await ph.pg.wait_for_timeout(6500)
      r=await ph.see(Q); a=await ph.audit('tg'); print(tag,'|',r,'| small',a['small'],'coral',a['coral'],'errs',ph.errs)
      if 'Happy' in r and path=='l':
        await ph.tap('text=happy thanksgiving',wait=600); await ph.pg.reload(); await ph.pg.wait_for_timeout(3800); await ph.see(NONEWS); await ph.pg.wait_for_timeout(6500); print('   second open same day:', await ph.see(Q))
      await ph.close()
    # the bar-night link
    ph=Phone('drinks'); ph2=ph
    await ph.start(p,path='l',extra="navigator.geolocation.getCurrentPosition = (ok,err) => setTimeout(() => err&&err({code:1}), 30); window.__HS=[]; const H0=window.__TCR.hungry_spots; window.__TCR.hungry_spots = a => { window.__HS.push([a.p_kind,a.p_lat,a.p_lng]); return [{id:'h1',km:0.3,img:null,title:'The Skip',likers:['Bee','Ace'],rank:'1',closes_in:240,place_id:'p1'},{id:'h2',km:0.5,img:null,title:'Quiet Bar',likers:[],rank:'2',closes_in:200,place_id:'p2'}]; };")
    await ph.pg.goto('http://127.0.0.1:8765/l/?drinks=1'); await ph.pg.wait_for_timeout(9500)
    print('drinks link |', await ph.see("(document.querySelector('.sheet')?.innerText||'no sheet').replace(/\\s+/g,' ').slice(0,260)"), '| called', await ph.see("JSON.stringify(window.__HS)"), 'errs', ph.errs)
    await ph.pg.screenshot(path='/tmp/h/sim/shots/drinks_link.png'); await ph.close()
asyncio.run(main())
