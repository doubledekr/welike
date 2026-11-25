import asyncio, json, sys
sys.path.insert(0,'/tmp/h/sim'); from lib import *
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
V=('-v' in sys.argv)
async def J(p,name,at,steps,goal,clean=True,extra='',path='t'):
    ph=Phone(name); await ph.start(p,at=at,extra=extra,path=path)
    if clean: await ph.see(CLEAN); await ph.pg.wait_for_timeout(300)
    if name not in ('thu_plan_ask','thu_plan_status'): await ph.tap('text=not now',must=False,wait=500); ph.steps=[s_ for s_ in ph.steps if not s_.get('miss')]
    a=await ph.audit('open')
    if V: print('  [open]',' | '.join(a['labels'])[:700])
    for st in steps:
        if st.startswith('swipe:'): await ph.swipe(st[6:])
        elif st.startswith('scroll'): await ph.scroll()
        elif st.startswith('shot:'): a=await ph.audit(st[5:])
        else:
            await ph.tap(st,wait=1200); a=await ph.audit(st,shot=True)
            if V: print('  ['+st+']',' | '.join(a['labels'])[:700])
    done=await ph.see(goal) if goal else None
    sm=ph.summary(); sm['goal']=done
    sm['audit']={ 'small':sorted({x for a in ph.audits for x in a['small']}), 'caps':sorted({x for a in ph.audits for x in a['caps']}), 'maxcoral':max(len(a['coral']) for a in ph.audits), 'coral_at':[a['label']+':'+str(len(a['coral'])) for a in ph.audits if len(a['coral'])>1], 'trunc':sorted({x for a in ph.audits for x in a['trunc']})[:8], 'tiny':sorted({x for a in ph.audits for x in a['tiny']})[:8], 'long':[a['label']+':'+str(a['scr'].get('screens')) for a in ph.audits if a['scr'].get('screens',0)>1.0], 'ov':sorted({x for a in ph.audits for x in a['ov']})[:6], 'maxn':max(a['n'] for a in ph.audits)}
    await ph.close(); return sm
TUE='2026-11-17T20:30:00-05:00'; THU='2026-11-19T20:00:00-05:00'; FRI='2026-11-20T18:00:00-05:00'; SAT='2026-11-21T15:00:00-05:00'; SUN='2026-11-22T20:00:00-05:00'
JS={
 'weeknight': (TUE,['swipe:right','swipe:left','swipe:right','swipe:up','shot:end of pile'],"document.querySelector('.stack .done')?.innerText.replace(/\\s+/g,' ').slice(0,200)"),
 'thu_plan_ask': (THU,['text=i’m in'],"(document.querySelector('.toast')?.innerText||'')+' | '+(document.querySelector('.stack .done')?.className||'pile')"),
 'thu_plan_status': (THU,['text=look closer','text=i’m in'],"document.querySelector('.sheet')?.innerText.replace(/\\s+/g,' ').slice(0,160)"),
 'thu_plan_saturday': (THU,['text=plan a day','text=three stops set','text=i’m in'],"document.querySelector('.sheet')?.innerText.replace(/\\s+/g,' ').slice(0,160)"),
 'thu_fill_hole': (THU,['text=look','text=pick','swipe:right','swipe:right'],"(document.querySelector('.sheet')||document.querySelector('#app')).innerText.replace(/\\s+/g,' ').slice(0,160)"),
 'fri_tonight_dinner': (FRI,['text=tonight','.sheet [data-act=hungry],.sheet [data-hk]','text=drinks'],"document.querySelector('.sheet')?.innerText.replace(/\\s+/g,' ').slice(0,160)"),
 'fri_tonight_spin': (FRI,['text=tonight','text=movie'],"(document.querySelector('.sheet')||document.querySelector('#app')).innerText.replace(/\\s+/g,' ').slice(0,200)"),
 'sat_out': (SAT,['.home.one>.slot [data-pl],.home.one>.slot button','.pcalm .pstop:nth-child(2) .grow b','text=map'],"document.querySelector('.sheet')?.innerText.replace(/\\s+/g,' ').slice(0,200)"),
 'sun_movie': (SUN,['text=watch','swipe:right','swipe:right','text=watch','shot:watch list'],"(document.querySelector('.sheet')||document.querySelector('.stack')).innerText.replace(/\\s+/g,' ').slice(0,200)"),
 'find_liked': (TUE,['text=likes','text=with ace','.lgrid button,.lgstk .mcard,.ltile','shot:liked item'],"(document.querySelector('.sheet')||document.querySelector('#app')).innerText.replace(/\\s+/g,' ').slice(0,200)"),
 'quiet_pushes': (TUE,['text=you and settings','text=notif','shot:notif'],"(document.querySelector('.sheet')||document.querySelector('#app')).innerText.replace(/\\s+/g,' ').slice(0,300)"),
 'inbox': (THU,['text=inbox','shot:inbox'],"(document.querySelector('.sheet')||document.querySelector('#app')).innerText.replace(/\\s+/g,' ').slice(0,400)"),
 'crew': (TUE,['text=crew','shot:crew'],"document.querySelector('#app').innerText.replace(/\\s+/g,' ').slice(0,300)"),
 'trips': (SUN,['.dock button[aria-label*=Trips]','shot:trips'],"document.querySelector('#app').innerText.replace(/\\s+/g,' ').slice(0,300)"),
}
async def main(names):
  async with async_playwright() as p:
    out=[]
    for n in names:
      at,steps,goal=JS[n]; sm=await J(p,n,at,steps,goal,clean=(n!='lapsed'),path=__import__('os').environ.get('SIMPATH','t')); out.append(sm)
      print(json.dumps(sm)[:1600]); print()
    json.dump(out,open('/tmp/h/sim/out_%s.json'%('_'.join(names)[:40]),'w'))
asyncio.run(main([a for a in sys.argv[1:] if not a.startswith('-')]))
