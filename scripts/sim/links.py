import asyncio, json, sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
EX="navigator.geolocation.getCurrentPosition = (ok,err) => setTimeout(() => err&&err({code:1}), 30); window.__HS=[]; window.__TCR.hungry_spots = a => { window.__HS.push([a.p_kind,a.p_lat,a.p_lng]); return [{id:'h1',km:0.3,img:null,title:'The Skip',likers:['Bee','Ace'],rank:'1',closes_in:240,place_id:'p1'},{id:'h2',km:0.5,img:null,title:'Quiet Bar',likers:[],rank:'2',closes_in:200,place_id:'p2'}]; };"
SHEET="(document.querySelector('.sheet')?.innerText||'no sheet').replace(/\\s+/g,' ').slice(0,170)"
async def main():
  async with async_playwright() as p:
    for path in ['l','t']:
      ph=Phone('ln_'+path); await ph.start(p,path=path,extra=EX,at='2026-11-19T20:00:00-05:00'); await ph.see(CLEAN); await ph.pg.wait_for_timeout(300)
      pid=await ph.see("(document.querySelector('[data-pl^=\"view|\"]')?.dataset.pl||'').split('|')[1]||''")
      await ph.see("navigator.serviceWorker.dispatchEvent(new MessageEvent('message',{data:{open:location.origin+'/%s/?plan=%s'}}))"%(path,pid)); await ph.pg.wait_for_timeout(1500)
      print(path,'app open, plan push tapped ->', await ph.see(SHEET))
      await ph.see("navigator.serviceWorker.dispatchEvent(new MessageEvent('message',{data:{open:location.origin+'/%s/?drinks=1'}}))"%path); await ph.pg.wait_for_timeout(7000)
      print(path,'app open, bar-night push tapped ->', await ph.see(SHEET), '| asked', await ph.see("JSON.stringify(window.__HS)"))
      await ph.pg.screenshot(path=f'/tmp/h/sim/shots/drinks_{path}.png')
      await ph.pg.goto(f'http://127.0.0.1:8765/{path}/?drinks=1'); await ph.pg.wait_for_timeout(10500)
      print(path,'cold open on the link ->', await ph.see(SHEET), 'errs', ph.errs)
      await ph.close()
asyncio.run(main())
