"""Builds the beta copy of the app at /t from the main app.

The beta is the same app with its own Home Screen name and icon ("LT Beta"), its own saved sign-in (so it never
touches the main app's), a small BETA mark, and window.LT_BETA set, which switches on features being tried out
(flowers, for now). Run it from the repo root after changing index.html:  python3 scripts/make_beta.py
"""
import json, pathlib, shutil
from PIL import Image, ImageDraw, ImageFont

root = pathlib.Path(__file__).resolve().parent.parent
out = root / 't'; out.mkdir(exist_ok=True)

s = (root / 'index.html').read_text()
def rep(a, b, n=None):
    global s
    c = s.count(a)
    assert c and (n is None or c == n), (a, c)
    s = s.replace(a, b)

rep('wl_', 'wlt_')                                                     # its own saved sign-in, cookies and flags
rep('<meta name="apple-mobile-web-app-title" content="Let’s Together">', '<meta name="apple-mobile-web-app-title" content="LT Beta">', 1)
rep('<title>Let’s Together: swipe, match, decide tonight</title>', '<title>LT Beta</title>', 1)
rep("name: 'Let’s Together', short_name: 'Let’s Together'", "name: 'LT Beta', short_name: 'LT Beta'")
rep('</head>', '''<script>window.LT_BETA = true;</script>
<style>body::after{content:'BETA';position:fixed;top:calc(env(safe-area-inset-top) + 2px);left:50%;transform:translateX(-50%);font:700 9px/1 system-ui,sans-serif;letter-spacing:.24em;color:#ffb547;opacity:.85;z-index:99999;pointer-events:none}</style>
</head>''', 1)
(out / 'index.html').write_text(s)
shutil.copy(root / 'sw.js', out / 'sw.js')

m = json.loads((root / 'manifest.webmanifest').read_text())
m.update(name='LT Beta', short_name='LT Beta', description='Let’s Together, beta copy for testing.')
(out / 'manifest.webmanifest').write_text(json.dumps(m, ensure_ascii=False, indent=2))

# icons: the real mark with an amber BETA band across the bottom
font_path = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
for name in ['mark-180.png', 'mark-192.png', 'mark-512.png', 'mark-512m.png']:
    im = Image.open(root / name).convert('RGBA'); w, h = im.size
    d = ImageDraw.Draw(im); band = int(h * 0.24); top = h - band - (int(h * 0.1) if name.endswith('m.png') else 0)
    d.rectangle([0, top, w, top + band], fill=(255, 181, 71, 255))
    f = ImageFont.truetype(font_path, int(band * 0.62)); text = 'BETA'
    tw = d.textlength(text, font=f); d.text(((w - tw) / 2, top + band * 0.14), text, font=f, fill=(28, 10, 18, 255))
    im.convert('RGB' if name != 'mark-512m.png' else 'RGBA').save(out / name)
print('beta written to', out)

# ---- the simulation copy at /s: the beta build pointed at its own database of made-up people (the LTbeta project) ----
sim = root / 's'; sim.mkdir(exist_ok=True)
def srep(a, b, n=None):
    global s
    c = s.count(a)
    assert c and (n is None or c == n), (a, c)
    s = s.replace(a, b)
srep('wlt_', 'wls_')
srep("url: 'https://gbzximehndzlsbojoqgj.supabase.co'", "url: 'https://rqzxisubgkkfgdtnwvbf.supabase.co'", 1)
srep("key: 'sb_publishable_2kr1KUhUST6dUy7JdL-5rA_ERVJaCgI'", "key: 'sb_publishable_LceVPEjVbgtpV7LFD_OZww_vA2SUC5l'", 1)
assert 'gbzximehndzlsbojoqgj' not in s.replace('webcal://gbzximehndzlsbojoqgj', ''), 'the sim copy must not point at the live project'
srep('<meta name="apple-mobile-web-app-title" content="LT Beta">', '<meta name="apple-mobile-web-app-title" content="LT Sim">', 1)
srep('<title>LT Beta</title>', '<title>LT Sim</title>', 1)
srep("name: 'LT Beta', short_name: 'LT Beta'", "name: 'LT Sim', short_name: 'LT Sim'")
srep("content:'BETA'", "content:'SIM'", 1)
# takes the sim key from the address once, and runs the page on the simulated date
srep('<script>window.LT_BETA = true;</script>', """<script>window.LT_BETA = true; window.LT_SIM = true;
(function(){try{var q=new URLSearchParams(location.search),k=q.get('simkey');if(k){localStorage.setItem('wls_simkey',k);q.delete('simkey');history.replaceState(null,'',location.pathname+(q.toString()?'?'+q:''))}}catch(e){}
var sh=0;try{sh=Number(localStorage.getItem('wls_simshift')||0)}catch(e){}var R=Date;
function D(){if(!(this instanceof D))return new R(R.now()+sh).toString();var a=arguments;return a.length?new(Function.prototype.bind.apply(R,[null].concat([].slice.call(a)))):new R(R.now()+sh)}
D.prototype=R.prototype;D.now=function(){return R.now()+sh};D.parse=R.parse;D.UTC=R.UTC;window.Date=D;window.__simShift=function(ms){sh=ms}})();</script>""", 1)
(sim / 'index.html').write_text(s)
shutil.copy(root / 'sw.js', sim / 'sw.js')
m.update(name='LT Sim', short_name='LT Sim', description='Let’s Together, simulation copy with made-up people.')
(sim / 'manifest.webmanifest').write_text(json.dumps(m, ensure_ascii=False, indent=2))
for name in ['mark-180.png', 'mark-192.png', 'mark-512.png', 'mark-512m.png']: shutil.copy(out / name, sim / name)
print('sim written to', sim)

