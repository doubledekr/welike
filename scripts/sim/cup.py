import asyncio,sys,json,re
sys.path.insert(0,'/tmp/h/sim'); from lib import *
src=open('/tmp/h/sim/overflow.py').read(); SCAN=re.search(r'SCAN="""(.*?)"""',src,re.S).group(1)
CLEAN="document.querySelectorAll('.wn,.phero,.ph,.a2arrow').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
STUB="""window.__TCR=window.__TCR||{}; window.__TCR.coming_up=()=>({from:'2026-11-25',days:14,items:[
 {id:'e1',deck:'event',kind:'Festival',title:"America's Thanksgiving Parade, 100th year",image:null,day:'2026-11-26',mi:1.2,both:false,mine:true,plan:false,data:{time:'8:45 am',venue:'Woodward Ave and Kirby St'}},
 {id:'e2',deck:'event',kind:'Outdoors',title:'S3 Turkey Trot Detroit',image:null,day:'2026-11-26',mi:0.4,both:false,mine:false,plan:false,data:{time:'7:30 am',venue:'Campus Martius'}},
 {id:'e3',deck:'event',kind:'Festival',title:"Santa's City of Plymouth Parade and Tree Lighting, with a very long name to test wrapping",image:null,day:'2026-11-27',mi:22.4,both:true,mine:true,plan:false,data:{time:'6:00 pm - 8:30 pm',venue:'Kellogg Park'}},
 {id:'e4',deck:'event',kind:'Market',title:'Eastern Market Holiday Twilight Stroll',image:null,day:'2026-11-28',mi:2.0,both:true,mine:true,plan:true,data:{time:'5:00 pm',venue:'Eastern Market'}}]});"""
async def main():
  async with async_playwright() as p:
    for path in ('t','l'):
      ph=Phone('cup_'+path); await ph.start(p,at='2026-11-25T21:00:00-05:00',path=path,extra=STUB); await ph.see(CLEAN)
      await ph.tap('text=plan a day',wait=1300,must=False)
      row=await ph.see("!!document.querySelector('[data-act=cup]')")
      if row:
        await ph.tap('[data-act=cup]',wait=1200)
        t=(await ph.see("(document.querySelector('.sheet')||{}).innerText||''")).replace('\n',' | ')
        a=await ph.audit('cup',shot=True); print(path,'row:',row,'| sheet:',t[:420],'| out of box:',await ph.see(SCAN),'small',a['small'])
        await ph.tap('[data-act=lbopen]',wait=1200,must=False); print('   tap opens:', (await ph.see("(document.querySelector('.sheet h2, .det h2, .detail h2, .card.flipped h2')||{}).innerText||document.querySelector('#layer')?.innerText?.slice(0,80)||null")), 'errs',ph.errs)
      else: print(path,'row:',row,'errs',ph.errs)
      await ph.close()
asyncio.run(main())
