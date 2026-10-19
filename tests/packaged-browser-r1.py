import asyncio,base64,io,json,os,pathlib,re,socket,subprocess,tempfile,urllib.request,zipfile
import websockets
ROOT=pathlib.Path(__file__).resolve().parent.parent
PWSH=os.environ.get('PWSH','/tmp/exmail-pwsh/runtime/pwsh')
async def main():
 html=(ROOT/'dist/EX메일-익스플로러-설치-v18.2-r1.html').read_text()
 bat=base64.b64decode(re.search(r"const BAT='([^']+)'",html)[1]).decode('ascii')
 bundle=base64.b64decode(re.search(r'^::EXMAIL_ZIP:([A-Za-z0-9+/=]+)',bat,re.M)[1])
 with tempfile.TemporaryDirectory(prefix='exmail-package-') as tmp:
  tmp=pathlib.Path(tmp);program=tmp/'EX메일 익스플로러';state=tmp/'state';state.mkdir();profile=tmp/'chrome';profile.mkdir()
  with zipfile.ZipFile(io.BytesIO(bundle)) as z:z.extractall(tmp)
  for p in (ROOT/'program').iterdir():assert p.read_bytes()==(program/p.name).read_bytes(),p.name
  with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
  env=os.environ.copy()
  for key,name in [('XDG_CACHE_HOME','cache'),('XDG_CONFIG_HOME','config'),('XDG_DATA_HOME','data')]:
   folder=tmp/name;folder.mkdir();env[key]=str(folder)
  server=subprocess.Popen([PWSH,'-NoProfile','-File',str(ROOT/'tests/serve-final-r1.ps1'),'-ProgramPath',str(program),'-QaRoot',str(state),'-QaPort',str(port)],env=env,stdout=-1,stderr=-1,text=True)
  browser=None
  try:
   assert server.stdout.readline().strip()=='READY'
   url=f'http://127.0.0.1:{port}/';served=urllib.request.urlopen(url,timeout=5).read().decode();assert '__TOKEN__' not in served
   with open(tmp/'browser.log','w') as log:
    browser=subprocess.Popen(['chromium','--headless','--no-sandbox','--disable-dev-shm-usage','--disable-gpu','--disable-extensions','--no-first-run','--user-data-dir='+str(profile),'--remote-debugging-port=0','about:blank'],stdout=log,stderr=log)
    for _ in range(100):
     await asyncio.sleep(.05)
     if (profile/'DevToolsActivePort').exists():break
    debug=int((profile/'DevToolsActivePort').read_text().splitlines()[0]);pages=json.load(urllib.request.urlopen(f'http://127.0.0.1:{debug}/json/list'));page=next(x for x in pages if x['type']=='page')
    async with websockets.connect(page['webSocketDebuggerUrl'],max_size=16*1024*1024) as ws:
     counter=0
     async def call(method,params):
      nonlocal counter
      counter+=1;ident=counter;await ws.send(json.dumps({'id':ident,'method':method,'params':params}))
      while True:
       result=json.loads(await asyncio.wait_for(ws.recv(),20))
       if result.get('id')==ident:
        assert 'error' not in result,result
        return result.get('result',{})
     async def evaluate(code):
      r=await call('Runtime.evaluate',{'expression':code,'returnByValue':True,'awaitPromise':True});assert not r.get('exceptionDetails'),r;return r['result'].get('value')
     await call('Emulation.setDeviceMetricsOverride',{'width':1400,'height':1000,'deviceScaleFactor':1,'mobile':False})
     await call('Page.navigate',{'url':url})
     for _ in range(60):
      await asyncio.sleep(.1)
      if await evaluate("document.getElementById('firstTransferSetup')?.open"):break
     assert await evaluate("document.getElementById('firstTransferSetup').open")
     assert await evaluate("document.getElementById('appVersion').textContent==='앱 v18.2-r1'")
     image=await call('Page.captureScreenshot',{'format':'png'});(ROOT/'dist/초기-자료교환-설정-안내.png').write_bytes(base64.b64decode(image['data']))
     await evaluate("document.getElementById('firstTransferSetupStart').click()")
     for _ in range(60):
      await asyncio.sleep(.1)
      if (state/'native-calibration-requested').exists():break
     assert (state/'native-calibration-requested').exists()
     assert json.load(urllib.request.urlopen(url+'api/state'))['setupActive']
     assert await evaluate("document.getElementById('settingsDialog').open&&!document.getElementById('setupStep2').hidden")
     await evaluate("document.getElementById('settingsCancel').click()")
     for _ in range(30):
      await asyncio.sleep(.1)
      if not json.load(urllib.request.urlopen(url+'api/state'))['setupActive']:break
     assert not json.load(urllib.request.urlopen(url+'api/state'))['setupActive']
     await call('Emulation.setDeviceMetricsOverride',{'width':390,'height':844,'deviceScaleFactor':1,'mobile':True})
     assert await evaluate('document.documentElement.scrollWidth<=innerWidth')
     print('PASS final HTML → BAT → ZIP exact sources, real PowerShell HTTP/Chromium initial setup popup → Start → setup lease and native-calibration request; cancel lease release; 390px layout (native Windows process simulated)')
  finally:
   (state/'stop').touch()
   if browser:browser.terminate();browser.wait(timeout=5)
   try:server.wait(timeout=5)
   except subprocess.TimeoutExpired:server.kill()
   if server.returncode:raise RuntimeError(server.stderr.read())
asyncio.run(main())
