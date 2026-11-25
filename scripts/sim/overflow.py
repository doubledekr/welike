import asyncio,sys,json
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
# text that runs out of its box: a control wider than the box that holds it, or past the edge of the screen or sheet
SCAN="""(()=>{ const out=[]; const root=document.querySelector('.sheet')||document.querySelector('#app'); const W=innerWidth;
  const boxOf=el=>{ let p=el.parentElement; for(let i=0;i<4&&p&&p!==document.body;i++,p=p.parentElement){ const cs=getComputedStyle(p); if(/(auto|scroll)/.test(cs.overflowX)) return null; if(cs.overflowX==='hidden') return {p,clip:true}; const bg=cs.backgroundColor; if((bg&&bg!=='rgba(0, 0, 0, 0)'&&bg!=='transparent')||parseFloat(cs.borderRadius)>0) return {p,clip:false}; } return null; };
  root.querySelectorAll('button,a,.pill,.btn,.chip,b,small,h2,h3,p,span').forEach(el=>{ if(!el.offsetParent||el.closest('.dock')) return; const r=el.getBoundingClientRect(); if(r.width<8||r.height<6||r.bottom<0||r.top>innerHeight) return; const t=(el.innerText||'').trim().slice(0,42); if(!t) return;
    let inScroller=false; for(let p=el.parentElement;p&&p!==document.body;p=p.parentElement){ if(/(auto|scroll)/.test(getComputedStyle(p).overflowX)&&p.scrollWidth>p.clientWidth+2){inScroller=true;break;} } if(inScroller) return;
    if(r.right>W+1||r.left<-1){ out.push('off screen: '+t); return; }
    const b=boxOf(el); if(b){ const pr=b.p.getBoundingClientRect(); if(r.right>pr.right+1.5||r.left<pr.left-1.5) out.push((b.clip?'cut off: ':'out of box: ')+t+' ['+el.className.toString().slice(0,18)+' in '+b.p.className.toString().slice(0,18)+']'); }
    if(/^(BUTTON|A)$/.test(el.tagName)&&el.scrollWidth>el.clientWidth+2&&getComputedStyle(el).textOverflow!=='ellipsis') out.push('text wider than button: '+t); });
  return JSON.stringify([...new Set(out)].slice(0,8)); })()"""
STRESS="""(()=>{ const root=document.querySelector('.sheet')||document.querySelector('#app'); const w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT); const ns=[]; while(w.nextNode()) ns.push(w.currentNode);
  ns.forEach(n=>{ const t=n.nodeValue.trim(); const pe=n.parentElement; if(!pe||!pe.offsetParent||t.length<4||t.length>40) return; if(pe.closest('.dock,.seg,.topbar')) return; const btn=pe.closest('button,a,.pill,.btn'); const ttl=pe.closest('b,h2,h3'); if((ttl&&!(btn&&!btn.querySelector('b')))||(btn&&t.length>14&&!ttl)) n.nodeValue=n.nodeValue.replace(t, t+' and the Long Name Company of Detroit'); }); })()"""
SCREENS=[('home','2026-11-19T20:00:00-05:00',[]),('plan fri','2026-11-19T20:00:00-05:00',['text=look closer']),('plan fri more','2026-11-19T20:00:00-05:00',['text=look closer','text=more options']),
 ('plan sat today','2026-11-21T15:00:00-05:00',['.home.one>.slot [data-pl],.home.one>.slot button']),('tonight','2026-11-20T18:00:00-05:00',['text=tonight']),('plan a day','2026-11-19T20:00:00-05:00',['text=plan a day']),
 ('likes','2026-11-17T20:30:00-05:00',['text=likes']),('favorites','2026-11-17T20:30:00-05:00',['text=favorites']),('inbox','2026-11-19T20:00:00-05:00',['[aria-label*=nbox],[data-act=inbox]']),
 ('you','2026-11-19T20:00:00-05:00',['text=you and settings']),('crew','2026-11-19T20:00:00-05:00',['[data-act=people]']),('account','2026-11-19T20:00:00-05:00',['[data-act=people]','text=add your friends']),
 ('trips','2026-11-22T20:00:00-05:00',['.dock button[aria-label*=Trips]']),('watch','2026-11-22T20:00:00-05:00',['text=watch']),('eat','2026-11-22T20:00:00-05:00',['text=eat & drink']),('go out','2026-11-22T20:00:00-05:00',['text=go out'])]
async def main():
  P=sys.argv[1] if len(sys.argv)>1 else 'l'; bad=0
  async with async_playwright() as p:
    for name,at,steps in SCREENS:
      for w,h in ((393,852),(375,667)):
        ph=Phone('ov'); 
        try:
          await ph.start(p,at=at,path=P,size=(w,h)) if 'size' in Phone.start.__code__.co_varnames else await ph.start(p,at=at,path=P)
        except TypeError: await ph.start(p,at=at,path=P)
        await ph.see(CLEAN)
        for sx in steps: await ph.tap(sx,wait=1100,must=False)
        a=json.loads(await ph.see(SCAN)); await ph.see(STRESS); await ph.pg.wait_for_timeout(250); b=json.loads(await ph.see(SCAN))
        if a or b: bad+=1; print(f'{name} {w}:', 'AS IS', a, '| LONG NAMES', b[:6])
        await ph.close()
        if 'size' not in Phone.start.__code__.co_varnames: break
  print('screens with something out of its box:',bad)
asyncio.run(main())
