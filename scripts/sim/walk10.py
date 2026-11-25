import asyncio,sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
async def main():
  async with async_playwright() as p:
    ph=Phone('walk10'); await ph.start(p,at='2026-11-25T16:00:00-05:00',path='l'); await ph.pg.wait_for_timeout(2500)
    for i in range(4):
      t=await ph.see("(document.querySelector('.wn.wk')||{}).innerText||null"); print(i, (t or 'NONE').replace('\n',' | ')[:230])
      await ph.pg.screenshot(path=f'/tmp/walk{i}.png')
      if not t: break
      await ph.tap('text=next',wait=800,must=False) if i<2 else await ph.tap('.wn.wk .btn',wait=900,must=False)
    await ph.pg.wait_for_timeout(600); await ph.pg.screenshot(path='/tmp/walk_home.png'); print('errs',ph.errs, 'home one:', await ph.see("!!document.querySelector('.home.one')"))
    await ph.close()
asyncio.run(main())
