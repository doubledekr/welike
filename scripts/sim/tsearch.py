import asyncio,sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
STUB="""window.__TCR=window.__TCR||{}; window.__SD={places:['Lisbon','Tokyo','Chicago','Charleston','New Orleans','Mexico City','Kyoto'],mine:['Tokyo'],picked:['Tokyo'],both:[]};
window.__TCR.someday_get=()=>window.__SD; window.__TCR.someday_set=(a)=>{const m=new Set(window.__SD.mine); a.p_on?m.add(a.p_city):m.delete(a.p_city); window.__SD.mine=[...m]; window.__SD.picked=[...m]; return window.__SD;};"""
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
async def main():
  async with async_playwright() as p:
    for path in ('l','t'):
      ph=Phone('ts_'+path); await ph.start(p,at='2026-11-26T12:00:00-05:00',path=path,extra=STUB); await ph.see(CLEAN); await ph.pg.wait_for_timeout(400)
      local=await ph.see("document.querySelector('.hdr [data-act=search]')?.getAttribute('aria-label')")
      await ph.see("document.querySelector('.dock [data-act=side][data-to=trips], .dock .peek:not(.back)')?.click()"); await ph.pg.wait_for_timeout(1200); await ph.see(CLEAN)
      side=await ph.see("document.querySelector('.hdr [data-act=tsearch]')?.getAttribute('aria-label')||document.querySelector('.hdr [data-act=search]')?.getAttribute('aria-label')")
      await ph.tap('.hdr [data-act=tsearch]',wait=1200); h=await ph.see("(document.querySelector('.sheet h2')||{}).innerText||null")
      await ph.pg.fill('#tsq','chi'); await ph.pg.wait_for_timeout(300); res=await ph.see("[...document.querySelectorAll('#tsres button')].map(b=>b.innerText)")
      await ph.tap('#tsres [data-c=Chicago]',wait=800); on=await ph.see("document.querySelector('#tsres [data-c=Chicago]').classList.contains('on')")
      await ph.pg.fill('#tsq','zzz'); await ph.pg.wait_for_timeout(300); none=await ph.see("document.querySelector('#tsres').innerText")
      await ph.pg.fill('#tsq','chi'); await ph.pg.wait_for_timeout(300); a=await ph.audit('tsearch',shot=True)
      await ph.see("document.querySelector('.sheet [data-act=closesheet], .scrim')?.click()"); await ph.pg.wait_for_timeout(600)
      pills=await ph.see("[...document.querySelectorAll('#tphd .tpills button')].map(b=>b.innerText)")
      print(path,'local:',local,'| trips:',side,'| sheet:',h,'| chi ->',res,'| added:',on,'| none:',none,'| pills:',pills,'| small',a['small'],'errs',ph.errs)
      await ph.close()
asyncio.run(main())
