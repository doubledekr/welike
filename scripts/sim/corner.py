import asyncio,sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
STUB="""localStorage.setItem('wl_tg2026','1'); window.__FN={whereis:(b)=>{ if(b.action==='geocode') return {places:[{name:'1 Test St',address:'1 Test St, Detroit, MI 48201',lat:42.3555,lng:-83.066}]};
 if(b.action==='corner') { window.__cm=b.mins; const mk=(n,w,t)=>({id:n,name:n,walk:w,type:t,closes:new Date(Date.now()+3*36e5).toISOString(),maps:'https://maps.google.com',lat:42.35,lng:-83.06,address:'1 Test St',url:w<3?'https://example.com':null});
  return {mins:b.mins,groups:{drinks:[mk('Bronx Bar',2,'Bar'),mk('The Old Miami',4,'Bar')],snacks:[mk('Cafe Sous Terre',3,'Cafe'),mk('Socra Tea',5,'Tea house')],do:[mk('Detroit Artists Market',3,'Art gallery'),mk('Source Booksellers',5,'Book store')]}}; } }};"""
async def main():
  async with async_playwright() as p:
    for path in ('t','l'):
      ph=Phone('cn_'+path); await ph.start(p,at='2026-11-28T15:00:00-05:00',path=path,extra=STUB)
      await ph.see("document.querySelectorAll('.wn,.phero').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''")
      await ph.see("document.querySelector('[data-act=tonight]')?.click()"); await ph.pg.wait_for_timeout(1000)
      row=await ph.see("!!document.querySelector('[data-act=corner]')")
      if not row: print(path,'go:',go,'row:',row,'errs',ph.errs); await ph.close(); continue
      await ph.tap('[data-act=corner]',wait=900); h1=await ph.see("(document.querySelector('.sheet h2')||{}).innerText||null")
      if h1 and 'right spot' in h1:
        await ph.pg.fill('#haq','1 Test St Detroit'); await ph.tap('[data-act=hafind]',wait=700); await ph.tap('[data-act=hapick]',wait=1200)
      h2=await ph.see("(document.querySelector('.sheet h2')||{}).innerText||null"); secs=await ph.see("[...document.querySelectorAll('.sheet .sect')].map(e=>e.innerText)")
      await ph.audit('corner',shot=True)
      first=await ph.see("[...document.querySelectorAll('.tn > *, .sheet .body > *')].slice(0,3).map(e=>e.dataset?.act||e.className).join(',')")
      await ph.tap('[data-act=cgo]',wait=700); go=await ph.see("[...document.querySelectorAll('.sheet a.btn, .sheet .jlink')].map(e=>e.innerText)"); await ph.audit('go',shot=True)
      await ph.tap('.sheet [data-act=corner]',wait=700); await ph.tap('[data-act=corner][data-m=\"10\"]',wait=800)
      print(path,'go:',go,'row:',row,'| first:',h1,'| then:',h2,secs,'| 10 asked:',await ph.see('window.__cm'),'| errs',ph.errs); await ph.close()
asyncio.run(main())
