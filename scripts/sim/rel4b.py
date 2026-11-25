import asyncio,sys,json
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
P=sys.argv[1] if len(sys.argv)>1 else 'n'
COUPLE={'u-bee':{'code':'TESTTEST','name':'Bee','partner':'Ace','puid':'u-ace'},'u-ace':{'code':'TESTTEST','name':'Ace','partner':'Bee','puid':'u-bee'}}
INIT="window.__noinst=1;window.__poll=false;window.__frCouple=%s;try{window.__sess=JSON.parse(sessionStorage.getItem('fk_sess')||'null')}catch(e){};" % json.dumps(COUPLE)
T=lambda ph: ph.see("(document.querySelector('.sheet')||document.querySelector('#app')).innerText")
async def main():
  async with async_playwright() as p:
    ph=Phone('r4s'); await ph.start(p,at='2026-11-25T17:00:00-05:00',path=P,extra=INIT); await ph.see(CLEAN)
    await ph.tap('text=you and settings',wait=1000,must=False); await ph.see("document.querySelector('[data-act=acct]').click()"); await ph.pg.wait_for_timeout(900)
    inp=await ph.see("(()=>{const i=document.querySelector('.sheet input[type=email],#aemail'); return i? i.id||'input':null})()"); print('email field:',inp)
    await ph.pg.fill('.sheet input[type=email],#aemail','bee@example.com'); await ph.tap('[data-act=acctsend]',wait=1200)
    print('after send:',(await T(ph)).replace('\n',' | ')[:200])
    code=await ph.see("window.__otp||window.__code||null"); 
    await ph.pg.fill('#acode', '123456'); await ph.pg.wait_for_timeout(300); await ph.see("[...document.querySelectorAll('.sheet button')].find(b=>b.innerText.trim()==='Sign in')?.click()"); await ph.pg.wait_for_timeout(1500)
    print('after code:',(await T(ph)).replace('\n',' | ')[:220],'| acct:',await ph.see("JSON.stringify(window.__sess?.user?.email||null)"))
    await ph.see(CLEAN); await ph.see("document.querySelector('[data-tab=home],.back')?.click()"); await ph.pg.wait_for_timeout(900)
    await ph.pg.wait_for_timeout(900); await ph.see(CLEAN); print('  people key:', await ph.see("(()=>{const b=document.querySelector('[data-act=people]'); if(b){b.click(); return 'clicked'} return 'none: '+[...document.querySelectorAll('.ib')].map(x=>x.dataset.act||x.getAttribute('aria-label')).join(',')})()")); await ph.pg.wait_for_timeout(1600); txt=(await ph.see("document.querySelector('#app').innerText")).replace('\n',' | ')
    a=await ph.audit('crew_in',shot=True); print('crew signed in:',txt[:700],'\n  small',a['small'],'coral',a['coral'])
    await ph.see("document.querySelector('[data-fr=open]')?.click()"); await ph.pg.wait_for_timeout(1800)
    t2=(await ph.see("(document.querySelector('.sheet')||document.querySelector('#app')).innerText")).replace('\n',' | '); a2=await ph.audit('friends',shot=True); print('after Add your friends (signed in):',t2[:900],'\n  small',a2['small'])
    await ph.see("document.querySelector('[data-fr=group]')?.scrollIntoView(); document.querySelector('[data-fr=group]')?.click()"); await ph.pg.wait_for_timeout(1000); print('new group:',(await T(ph)).replace('\n',' | ')[:260]); await ph.audit('group',shot=True)
    print('errs',ph.errs); await ph.close()
asyncio.run(main())
