import asyncio,sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
# stand-in for Apple's script: records whether signIn() ran inside the tap (synchronously with the click)
STUB="""window.__inTap=false; window.__appleLog=[]; document.addEventListener('click',()=>{window.__inTap=true; Promise.resolve().then(()=>setTimeout(()=>{window.__inTap=false},0));},true);
window.AppleID={auth:{init:o=>{window.__appleLog.push('init '+o.clientId+' '+o.redirectURI+' popup:'+o.usePopup+' nonce:'+(o.nonce||'').length)},signIn:()=>{window.__appleLog.push('signIn inTap:'+window.__inTap); return Promise.reject({error:'popup_blocked_by_browser'})}}};"""
async def main():
  async with async_playwright() as p:
    ph=Phone('apple2'); await ph.start(p,at='2026-11-25T15:40:00-05:00',path='t'); await ph.see(CLEAN)
    ph.pg.on('requestfailed', lambda r: print('  failed', r.url[:70]) if 'apple' in r.url else None); ph.pg.on('console', lambda m: print('  console', m.text[:160]) if m.type=='error' else None)
    await ph.pg.route('**/appleid.auth.js', lambda r: r.fulfill(status=200, content_type='application/javascript', body=STUB.replace('window.__inTap=false; window.__appleLog=[]; ','window.__appleLog=window.__appleLog||[]; ')))
    await ph.see("window.__inTap=false; window.__appleLog=[]")
    await ph.tap('text=you and settings',wait=1100,must=False)
    await ph.see("document.querySelector('[data-act=acct]').click()"); await ph.pg.wait_for_timeout(1200)
    print('after sheet opens:', await ph.see("JSON.stringify({log:window.__appleLog, tag:!!document.querySelector('script[src*=appleid]'), has:typeof window.AppleID})"), ph.errs)
    await ph.tap('[data-act=acctapple]',wait=900)
    print('fetch:', await ph.see("fetch('https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/en_US/appleid.auth.js').then(r=>r.text()).then(t=>t.slice(0,80)+' len '+t.length).catch(e=>'ERR '+e)"))
    print('after tap:', await ph.see("JSON.stringify({log:window.__appleLog, toast:(document.querySelector('.toast')||{}).innerText||null, calls:(window.__calls||[]).filter(c=>c==='perf_note').length})"), ph.errs)
    await ph.pg.wait_for_timeout(800); print('  btn:', await ph.see("JSON.stringify({dis:document.querySelector('[data-act=acctapple]').disabled, cls:document.querySelector('[data-act=acctapple]').className})")); await ph.tap('[data-act=acctapple]',wait=900)
    print('second tap:', await ph.see("JSON.stringify(window.__appleLog.slice(-3))"))
    await ph.close()
asyncio.run(main())
