import asyncio, json, sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
EX=r"""
navigator.geolocation.getCurrentPosition = ok => setTimeout(() => ok({coords:{latitude:42.3355,longitude:-83.0497}}), 50);
window.__OM=null; window.__PUSH=[];
const IT=[['o1','Parc',6,true],['o2','Buddy’s Pizza',2,false],['o3','The Hudson Cafe',3,false]];
const omj=()=>({id:'om1',by:'Bee',other:'Ace',their_done:true,started:new Date().toISOString(),winner:(window.__OM.mine.find(x=>x!=='o1')||null),
  items:IT.map(([id,t,w,b])=>({id,title:t,image:'/img/'+id+'.jpg',place_id:'pid'+id,address:'1 Main St, Detroit',walk:w,both:b,till:new Date(Date.now()+3*3600e3).toISOString(),said:window.__OM.mine.includes(id),match:id!=='o1'&&window.__OM.mine.includes(id)}))});
window.__TCR.one_more = a => { if(!window.__OM){ if(a.p_lat==null) return {need:'where'}; window.__OM={mine:[]}; return {...omj(),fresh:true}; } return omj(); };
const SW=window.__TCR.swipe; window.__TCR.swipe = a => { if(a.p_session==='om1'){ window.__OM.mine.push(a.p_card); return {match:a.p_card!=='o1'}; } return SW?SW(a):{match:false}; };
window.__FN=window.__FN||{}; window.__FN.nudge = b => { window.__PUSH.push(b.title); return {sent:1}; };
"""
def br(a): return {k:a[k] for k in ['n','small','coral','caps','scr']}
async def main():
  async with async_playwright() as p:
    for path in ['t','l']:
      ph=Phone('om_'+path); await ph.start(p,path=path,extra=EX,at='2026-11-27T21:30:00-05:00'); await ph.see(CLEAN); await ph.pg.wait_for_timeout(300)
      await ph.tap('text=not now',must=False,wait=400)
      await ph.tap('text=tonight',wait=1200)
      ok=await ph.tap('text=already out',wait=1500,must=(path=='t'))
      if path=='l': print('live: entry present =',ok, 'errs',ph.errs); await ph.close(); continue
      a=await ph.audit('one more'); print('three:',br(a)); print('   ',' | '.join(a['labels'])[:400])
      await ph.tap('[data-act=omyes][data-id=o1]',label='pick Parc',wait=900); a=await ph.audit('after first'); print('after first pick:', await ph.see("document.querySelector('.body.om h2').innerText+' | '+[...document.querySelectorAll('.omt small')].map(x=>x.innerText).join(' ; ')"))
      await ph.tap('[data-act=omyes][data-id=o2]',label='pick Buddys',wait=1200); a=await ph.audit('winner'); print('winner:',br(a), await ph.see("document.querySelector('.body.om').innerText.replace(/\\s+/g,' ').slice(0,140)+' | go='+(document.querySelector('.body.om a.btn')?.href||'').slice(0,90)"))
      print('pushes', await ph.see("JSON.stringify(window.__PUSH)"), 'summary', {k:v for k,v in ph.summary().items() if k in ('taps','hard','small','miss','errs')})
      await ph.close()
asyncio.run(main())
