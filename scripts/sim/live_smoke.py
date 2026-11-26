import asyncio, datetime
exec(open('lb_test.py').read().split('async def main')[0])
async def main():
  async with async_playwright() as p:
    b=await p.chromium.launch(executable_path='/usr/bin/google-chrome',args=['--no-proxy-server'])
    ctx=await b.new_context(viewport={'width':393,'height':852},device_scale_factor=2,has_touch=True,user_agent=UA,timezone_id='America/Detroit')
    pg=await ctx.new_page(); errs=[]; pg.on('pageerror',lambda e:errs.append(str(e)[:200]))
    await pg.clock.install(time=datetime.datetime(2026,11,21,21,15,tzinfo=datetime.timezone.utc))
    await pg.route('**/*',lambda r: r.continue_() if r.request.url.startswith('http://127.0.0.1:8765') else r.abort())
    await pg.add_init_script(INIT); await pg.goto('http://127.0.0.1:8765/l/'); await pg.clock.run_for(4000)
    clr="document.querySelectorAll('.wn').forEach(e=>e.remove()); const l=document.querySelector('#layer'); if(l) l.innerHTML=''"
    await pg.evaluate(clr)
    print('header:', await pg.evaluate("[...document.querySelectorAll('.hdr .ib')].map(e=>e.getAttribute('aria-label')).join(' | ')"))
    print('dock:', (await pg.evaluate("document.querySelector('.dock').innerText")).replace('\n',' | '))
    for act in ['likes','cup','tonight','planday']:
      await pg.evaluate(f"document.querySelector('.dock [data-act={act}]').click()"); await pg.clock.run_for(1500)
      print(act, '->', (await pg.evaluate("(document.querySelector('.sheet')||document.querySelector('#app')).innerText")).replace('\n',' | ')[:110])
      await pg.goto('http://127.0.0.1:8765/l/'); await pg.clock.run_for(3000); await pg.evaluate(clr)
    await pg.evaluate("document.querySelector('[data-tab=you]').click()"); await pg.clock.run_for(1200)
    t=await pg.evaluate("document.querySelector('#app').innerText"); print('you has account row:', 'Save your account' in t, '| friends row:', 'Friends and group plans' in t)
    print('errs', errs); await b.close()
asyncio.run(main())
