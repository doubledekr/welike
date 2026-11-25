import asyncio,sys,json
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
# stand-in for Google's script: draws a plain key, then swaps it for a frame a moment later, the way the real one does
G = r"""window.google={accounts:{id:{initialize(){},renderButton(el){ el.innerHTML='<div style="width:300px;height:40px;background:#fff">plain</div>'; setTimeout(()=>{ el.innerHTML='<div><iframe srcdoc="<body style=margin:0;background:#131314;color:#fff>Continue as Bee</body>" style="width:300px;height:40px;border:0"></iframe></div>'; },250); }}}};"""
WATCH="""window.__mut=[]; window.__lay=[]; (()=>{ const t0=performance.now(); const L=document.querySelector('#layer'); new MutationObserver(ms=>{ for(const m of ms){ if(m.target===L||m.target.classList?.contains('scrim')) window.__mut.push(Math.round(performance.now()-t0)+':'+m.addedNodes.length); } }).observe(L,{childList:true,subtree:false});
  const tick=()=>{ const e=document.getElementById('aemail'), g=document.getElementById('gbtn'); if(e) window.__lay.push([Math.round(performance.now()-t0), Math.round(e.getBoundingClientRect().top), g?getComputedStyle(g.firstElementChild||g).opacity:'-', g?g.classList.contains('ok'):null]); if(performance.now()-t0<2600) requestAnimationFrame(tick); }; requestAnimationFrame(tick); })()"""
async def main():
  async with async_playwright() as p:
    ph=Phone('af'); await ph.start(p,at='2026-11-25T18:20:00-05:00',path='l'); await ph.see(CLEAN)
    await ph.pg.route('**/gsi/client', lambda r: r.fulfill(status=200, content_type='application/javascript', body=G))
    await ph.tap('text=you and settings',wait=1000,must=False); await ph.see(WATCH); await ph.see("document.querySelector('[data-act=acct]').click()"); await ph.pg.wait_for_timeout(2800)
    lay=json.loads(await ph.see("JSON.stringify(window.__lay)")); tops=sorted(set(x[1] for x in lay[8:])); 
    firstok=next((x[0] for x in lay if x[3]),None); vis_before=[x for x in lay if x[2] not in ('0','-') and not x[3]]
    print('sheet drawn (times, nodes):',await ph.see("JSON.stringify(window.__mut)"),'| email field top positions after the opening slide:',tops,'| Google key shown at ms:',firstok,'| frames where it showed before settling:',len(vis_before),'errs',ph.errs)
    await ph.audit('acct',shot=True); await ph.close()
asyncio.run(main())
