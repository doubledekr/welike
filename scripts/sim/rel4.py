import asyncio,sys,json
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
P=sys.argv[1] if len(sys.argv)>1 else 'n'
async def main():
  async with async_playwright() as p:
    # A. someone already in: nothing pops up; the quiet doors are there
    ph=Phone('r4a'); await ph.start(p,at='2026-11-25T17:00:00-05:00',path=P); await ph.see(CLEAN); await ph.pg.wait_for_timeout(3800)
    a=await ph.see("JSON.stringify({popped:(document.querySelector('.sheet h2')||{}).innerText||null, crewKey:!!document.querySelector('[data-act=people]'), signedIn: !!(window.__sess)})")
    await ph.audit('home',shot=True)
    await ph.tap('[data-act=people]',wait=1200,must=False); crew=(await ph.see("document.querySelector('#app').innerText")).replace('\n',' | ')[:260]; ac=await ph.audit('crew',shot=True)
    await ph.tap('text=add your friends',wait=1100,must=False); sh=await ph.see("JSON.stringify({sheet:(document.querySelector('.sheet h2')||{}).innerText||null, apple:!!document.querySelector('[data-act=acctapple]'), email:!!document.querySelector('#aemail,[data-act=acctsend]')})"); asx=await ph.audit('acct',shot=True)
    print('A existing couple:',a,'\n  crew:',crew,'\n  small',ac['small'],'\n  after Add your friends:',sh,'small',asx['small'],'errs',ph.errs); await ph.close()
    ph=Phone('r4y'); await ph.start(p,at='2026-11-25T17:00:00-05:00',path=P); await ph.see(CLEAN); await ph.tap('text=you and settings',wait=1100,must=False)
    print('  You rows:', await ph.see("JSON.stringify([...document.querySelectorAll('.you .yrow b')].map(b=>b.innerText).slice(0,9))"), ph.errs); await ph.audit('you',shot=True); await ph.close()
    # B. brand new: no code on the phone
    ph=Phone('r4b'); await ph.start(p,at='2026-11-25T17:00:00-05:00',path=P,extra="try{localStorage.clear();sessionStorage.clear()}catch(e){}; window.__fresh=1;"); await ph.pg.wait_for_timeout(1500)
    seen=[(await ph.see("document.querySelector('#app').innerText")).replace('\n',' | ')[:80]]
    await ph.tap('text=skip',wait=1200,must=False); seen.append((await ph.see("document.querySelector('#app').innerText")).replace('\n',' | ')[:330])
    await ph.audit('new',shot=True)
    print('B new person, last screen:',seen[-1],'| steps',len(seen),'| links:',await ph.see("JSON.stringify([...document.querySelectorAll('.jlink,.wk-cta')].map(b=>b.innerText))"),'errs',ph.errs)
    await ph.tap('text=i have a code',wait=1000,must=False); print('  partner-code path:',(await ph.see("document.querySelector('#app').innerText")).replace('\n',' | ')[:140]); await ph.close()
asyncio.run(main())
