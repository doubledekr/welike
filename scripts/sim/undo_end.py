import asyncio,sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
async def main():
  async with async_playwright() as p:
    for path in ('t','l'):
      ph=Phone('undo_'+path); await ph.start(p,at='2026-11-17T20:30:00-05:00',path=path); await ph.see(CLEAN); await ph.pg.wait_for_timeout(300)
      await ph.tap('text=not now',must=False,wait=400)
      out=[]
      for i in range(8):
        if await ph.see("!!document.querySelector('#stack .done')"): break
        await ph.swipe('right'); await ph.pg.wait_for_timeout(500)
        out.append(await ph.see("JSON.stringify([!!document.querySelector('#stack .done'), !!document.querySelector('.undof')])"))
      await ph.pg.wait_for_timeout(300)
      print(path,'[done, chip] after each swipe:',out,'| end:',await ph.see("JSON.stringify({done:!!document.querySelector('#stack .done'),chip:!!document.querySelector('.undof'),ownUndo:!!document.querySelector('#stack .done [data-sw=undo]')})"),ph.errs)
      await ph.audit('end',shot=True); await ph.close()
asyncio.run(main())
