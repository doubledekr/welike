import asyncio,sys,json,re
sys.path.insert(0,'/tmp/h/sim'); from lib import *
src=open('/tmp/h/sim/overflow.py').read(); SCAN=re.search(r'SCAN="""(.*?)"""',src,re.S).group(1)
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
async def main():
  async with async_playwright() as p:
    ph=Phone('ovc'); await ph.start(p,at='2026-11-19T20:00:00-05:00',path='l'); await ph.see(CLEAN); await ph.tap('text=look closer',wait=1100,must=False)
    await ph.see("""(()=>{const st=document.querySelector('.pstop'); st.insertAdjacentHTML('afterend','<div class="pgap" id="tg"><b>Free from about 3pm until 4:43pm</b><small>That’s 1½ hours between Vintage Eastern Market and Detroit Shipping Company.</small><span class="psb"><button class="pill">Fill the time nearby</button><button class="pill" id="tp">Move Vintage Eastern Market to 2:15pm</button></span></div>')})()""")
    print('with the fix:', await ph.see(SCAN), await ph.see("JSON.stringify((r=>[Math.round(r.right),innerWidth])(document.getElementById('tp').getBoundingClientRect()))"))
    await ph.pg.screenshot(path='/tmp/gapfix.png',clip={'x':0,'y':330,'width':393,'height':260})
    await ph.see("document.getElementById('tp').style.whiteSpace='nowrap'"); print('as it was (nowrap):', await ph.see(SCAN)); await ph.close()
    ph=Phone('look'); await ph.start(p,at='2026-11-19T20:00:00-05:00',path='l'); await ph.see(CLEAN); await ph.tap('text=not now',wait=700,must=False)
    print('slot go:', await ph.see("JSON.stringify((g=>g?{txt:g.innerText,after:getComputedStyle(g,'::after').display,bg:getComputedStyle(g).backgroundColor,anim:getComputedStyle(g).animationName}:null)(document.querySelector('.home.one .slot .go')))"))
    await ph.pg.screenshot(path='/tmp/lookfix.png',clip={'x':0,'y':40,'width':393,'height':90}); await ph.close()
asyncio.run(main())
