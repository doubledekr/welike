# Phone-use simulator for the beta build: touch-driven journeys with a thumb-reach and tap-size log.
import asyncio, json, sys, os
from playwright.async_api import async_playwright
H_='/tmp/h'
src=open(H_+'/lb_test.py').read()
UA=src.split("UA='")[1].split("'\n")[0]
INIT=src.split('INIT=r"""')[1].split('"""')[0]
W,H=393,852
SAFE="document.addEventListener('DOMContentLoaded',()=>{const s=document.createElement('style');s.textContent=':root{--st:59px!important;--sb:34px!important}';document.head.append(s)});"
AUDIT=r"""(()=>{
 const W=innerWidth,H=innerHeight, vis=e=>{const r=e.getBoundingClientRect(),cs=getComputedStyle(e); return r.width>0&&r.height>0&&cs.visibility!=='hidden'&&cs.display!=='none'&&+cs.opacity>0.05&&r.bottom>0&&r.top<H&&r.right>0&&r.left<W};
 const topmost=e=>{const r=e.getBoundingClientRect(); const x=Math.min(W-1,Math.max(0,r.left+r.width/2)), y=Math.min(H-1,Math.max(0,r.top+r.height/2)); const t=document.elementFromPoint(x,y); return t&&(t===e||e.contains(t)||t.contains(e))};
 const lab=e=>((e.getAttribute('aria-label')||e.innerText||e.title||'').trim().replace(/\s+/g,' ').slice(0,38))||('['+(e.dataset.act||e.dataset.open||e.className||e.tagName).toString().slice(0,24)+']');
 const taps=[...document.querySelectorAll('button,a[href],[data-act],[data-open],[data-pl],[data-sw],[data-hdeck],input,select,[role=button]')].filter(e=>vis(e)&&topmost(e)&&!e.disabled);
 const uniq=[]; for(const e of taps){ if(!taps.some(u=>u!==e&&u.contains(e))) uniq.push(e); }
 const small=uniq.filter(e=>{const r=e.getBoundingClientRect(); return r.width<43.5||r.height<43.5}).map(e=>{const r=e.getBoundingClientRect(); return lab(e)+' '+Math.round(r.width)+'x'+Math.round(r.height)});
 const zone=y=>y<H*0.22?'hard':y<H*0.5?'stretch':'easy';
 const zones={easy:0,stretch:0,hard:0}; uniq.forEach(e=>{const r=e.getBoundingClientRect(); zones[zone(r.top+r.height/2)]++});
 const coral=uniq.filter(e=>{const b=getComputedStyle(e).backgroundImage; return /255, 122, 77|255, 77, 126|ff7a4d/i.test(b)}).map(lab);
 const scope=document.querySelector('#layer .sheet')||document.querySelector('#app')||document.body;
 const texts=[...scope.querySelectorAll('b,small,span,p,h1,h2,h3,button,a,label,div')].filter(e=>vis(e)&&e.children.length===0&&e.innerText&&e.innerText.trim().length>1);
 const trunc=texts.filter(e=>e.scrollWidth>e.clientWidth+1&&/hidden|clip/.test(getComputedStyle(e).overflowX)&&topmost(e)).map(e=>e.innerText.trim().slice(0,30));
 const tiny=[...new Set(texts.filter(e=>parseFloat(getComputedStyle(e).fontSize)<12&&topmost(e)).map(e=>e.innerText.trim().slice(0,22)+' '+parseFloat(getComputedStyle(e).fontSize)))];
 const caps=[...new Set(texts.filter(e=>getComputedStyle(e).textTransform==='uppercase'&&topmost(e)).map(e=>e.innerText.trim().slice(0,22)))];
 const emo=[...new Set(texts.filter(e=>/\p{Extended_Pictographic}/u.test(e.innerText)&&topmost(e)&&!e.closest('.pimg,.card .img,.mimg,.cover')).map(e=>e.innerText.trim().slice(0,22)))];
 const sh=document.querySelector('#layer .sheet');
 const scr=sh?{sheet:true,screens:+(sh.scrollHeight/H).toFixed(2),over:sh.scrollHeight-sh.clientHeight}:{sheet:false,over:Math.max(0,document.documentElement.scrollHeight-H)};
 const ov=[]; for(let i=0;i<uniq.length;i++)for(let j=i+1;j<uniq.length;j++){const a=uniq[i].getBoundingClientRect(),b=uniq[j].getBoundingClientRect(); const ix=Math.min(a.right,b.right)-Math.max(a.left,b.left), iy=Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top); if(ix>6&&iy>6&&ix*iy>0.2*Math.min(a.width*a.height,b.width*b.height)) ov.push(lab(uniq[i])+' / '+lab(uniq[j]));}
 const offs=uniq.filter(e=>{const r=e.getBoundingClientRect(); return r.left<-2||r.right>W+2}).map(lab);
 return {n:uniq.length,zones,small,coral,trunc:[...new Set(trunc)],tiny,caps,emo,scr,ov:ov.slice(0,6),offs,labels:uniq.map(e=>{const r=e.getBoundingClientRect(); return lab(e)+'@'+Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2)})};
})()"""
def zone_of(y): return 'hard' if y<H*0.22 else 'stretch' if y<H*0.5 else 'easy'
class Phone:
    def __init__(s,name): s.name=name; s.steps=[]; s.last=(W*0.8,H*0.9); s.errs=[]; s.n=0; s.audits=[]
    async def start(s,p,path='t',extra='',at=None):
        s.b=await p.chromium.launch(executable_path='/usr/bin/google-chrome',args=['--no-proxy-server'])
        s.ctx=await s.b.new_context(viewport={'width':W,'height':H},device_scale_factor=2,has_touch=True,is_mobile=True,user_agent=UA,timezone_id='America/Detroit')
        s.pg=await s.ctx.new_page(); s.pg.on('pageerror',lambda e:s.errs.append(str(e)[:200]))
        imgs=['m_p0.png','m_w1.png','m_a2.png','m_p3.png','m_w4.png','m_a5.png']; cnt=[0]
        async def route(r):
            u=r.request.url
            if '/img/' in u or u.endswith('.jpg'):
                cnt[0]+=1; return await r.fulfill(path=H_+'/'+imgs[cnt[0]%len(imgs)])
            if u.startswith('http://127.0.0.1:8765'): return await r.continue_()
            await r.abort()
        await s.pg.route('**/*',route)
        clock=("(()=>{const T=new Date(%s).getTime()-Date.now(); const D=Date; const N=function(...a){return a.length?new D(...a):new D(D.now()+T)}; N.now=()=>D.now()+T; N.parse=D.parse; N.UTC=D.UTC; N.prototype=D.prototype; window.Date=N;})();"%json.dumps(at)) if at else ''
        await s.pg.add_init_script(clock+SAFE+INIT+"window.__calls=window.__calls||[];"+extra)
        await s.pg.goto(f'http://127.0.0.1:8765/{path}/'); await s.pg.wait_for_timeout(3800)
    async def calls(s): return await s.pg.evaluate("(window.__calls||[]).length")
    async def audit(s,label,shot=True):
        a=await s.pg.evaluate(AUDIT); a['label']=label; s.n+=1
        if shot: a['shot']=f'{s.name}_{s.n:02d}.png'; await s.pg.screenshot(path=f'{H_}/sim/shots/{a["shot"]}')
        s.audits.append(a); return a
    async def tap(s,what,label=None,wait=900,must=True):
        if what.startswith('text='):
            t=what[5:]; q="""(()=>{const H=innerHeight; const c=[...document.querySelectorAll('button,a,[data-act],[data-open],[data-pl],[data-hdeck],[role=button]')].filter(e=>{const r=e.getBoundingClientRect(); return r.width>0&&r.height>0&&r.left>=-2&&r.right<=innerWidth+2&&getComputedStyle(e).visibility!=='hidden'&&((e.innerText||'')+' '+(e.getAttribute('aria-label')||'')).replace(/\\s+/g,' ').trim().toLowerCase().includes(%s)}); const L=e=>((e.innerText||'')+(e.getAttribute('aria-label')||'')).length; const e=c.sort((a,b)=>L(a)-L(b))[0]; if(!e) return null; const r0=e.getBoundingClientRect(); const need=r0.top<0||r0.bottom>H; if(need) e.scrollIntoView({block:'center'}); const r=e.getBoundingClientRect(); return [r.left,r.top,r.width,r.height,need?1:0]})()"""%json.dumps(t.lower())
        else:
            q="""(()=>{const e=[...document.querySelectorAll(%s)].find(e=>{const r=e.getBoundingClientRect(); return r.width>0&&r.height>0}); if(!e) return null; const r0=e.getBoundingClientRect(); const need=r0.top<0||r0.bottom>innerHeight; if(need) e.scrollIntoView({block:'center'}); const r=e.getBoundingClientRect(); return [r.left,r.top,r.width,r.height,need?1:0]})()"""%json.dumps(what)
        r=await s.pg.evaluate(q)
        if not r:
            s.steps.append({'do':label or what,'miss':True})
            if must: print('   MISS',s.name,label or what)
            return False
        x=r[0]+r[2]/2; y=r[1]+r[3]/2
        c0=await s.calls()
        await s.pg.touchscreen.tap(x,y); await s.pg.wait_for_timeout(wait)
        trav=((x-s.last[0])**2+(y-s.last[1])**2)**0.5; s.last=(x,y)
        s.steps.append({'do':label or what,'kind':'tap','w':round(r[2]),'h':round(r[3]),'x':round(x),'y':round(y),'zone':zone_of(y),'travel':round(trav),'small':r[2]<43.5 or r[3]<43.5,'scrolled':r[4]==1,'calls':(await s.calls())-c0})
        return True
    async def swipe(s,dir='right',label=None,sel='#stack .card:not(.under)',wait=700):
        r=await s.pg.evaluate("(()=>{const e=document.querySelector(%s); if(!e) return null; const r=e.getBoundingClientRect(); return [r.left+r.width/2,r.top+r.height*0.55]})()"%json.dumps(sel))
        if not r: s.steps.append({'do':label or 'swipe '+dir,'miss':True}); return False
        dx,dy={'right':(190,0),'left':(-190,0),'up':(0,-260),'down':(0,260)}[dir]
        cdp=await s.ctx.new_cdp_session(s.pg)
        async def ev(t,x,y): await cdp.send('Input.dispatchTouchEvent',{'type':t,'touchPoints':[] if t=='touchEnd' else [{'x':x,'y':y}]})
        c0=await s.calls(); await ev('touchStart',r[0],r[1])
        for i in range(1,9):
            await ev('touchMove',r[0]+dx*i/8,r[1]+dy*i/8); await s.pg.wait_for_timeout(16)
        await ev('touchEnd',0,0); await s.pg.wait_for_timeout(wait)
        s.steps.append({'do':label or 'swipe '+dir,'kind':'swipe','zone':zone_of(r[1]),'x':round(r[0]),'y':round(r[1]),'travel':round(((r[0]-s.last[0])**2+(r[1]-s.last[1])**2)**0.5),'calls':(await s.calls())-c0}); s.last=(r[0]+dx,r[1]+dy); return True
    async def scroll(s,dy=500,label='scroll'):
        await s.pg.evaluate("(()=>{const sh=document.querySelector('#layer .sheet')||document.scrollingElement; sh.scrollBy(0,%d)})()"%dy); await s.pg.wait_for_timeout(350)
        s.steps.append({'do':label,'kind':'scroll','zone':'easy'})
    async def see(s,js): return await s.pg.evaluate(js)
    async def close(s): await s.b.close()
    def summary(s):
        t=[x for x in s.steps if x.get('kind')=='tap']; sw=[x for x in s.steps if x.get('kind')=='swipe']; sc=[x for x in s.steps if x.get('kind')=='scroll']
        return {'journey':s.name,'taps':len(t),'swipes':len(sw),'scrolls':len(sc)+sum(1 for x in t if x.get('scrolled')),'hard':[x['do'] for x in t if x['zone']=='hard'],'stretch':sum(1 for x in t if x['zone']=='stretch'),'small':[x['do']+' %dx%d'%(x['w'],x['h']) for x in t if x['small']],'travel':sum(x.get('travel',0) for x in t+sw),'calls':sum(x.get('calls',0) for x in t+sw),'miss':[x['do'] for x in s.steps if x.get('miss')],'errs':s.errs}
