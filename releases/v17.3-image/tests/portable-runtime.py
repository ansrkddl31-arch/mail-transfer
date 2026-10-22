"""Exercise the final portable ZIP with the actual PowerShell HTTP server."""
import hashlib,json,os,pathlib,re,subprocess,tempfile,time,urllib.request,zipfile
ROOT=pathlib.Path(__file__).resolve().parent.parent
PWSH=os.environ.get('PWSH','/tmp/exmail-pwsh/runtime/pwsh')
PACKAGE=ROOT/'dist/EX메일-익스플로러-포터블-v17.3-이미지4.zip'
def request(path='',body=None,token=None):
    data=None if body is None else json.dumps(body).encode()
    headers={} if token is None else {'Content-Type':'application/json','X-Mail-Transfer-Token':token,'Origin':'http://127.0.0.1:8765'}
    return urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8765/'+path,data=data,headers=headers),timeout=3).read()
def ready(process):
    for _ in range(100):
        if process.poll() is not None:raise AssertionError('server exited before ready: '+process.stdout.read().decode())
        try:return request().decode('utf-8-sig')
        except OSError:time.sleep(.1)
    raise AssertionError('server startup timeout')
with tempfile.TemporaryDirectory(prefix='exmail-portable-runtime-') as temp:
    temp=pathlib.Path(temp)
    with zipfile.ZipFile(PACKAGE) as z:
        assert not any(n.endswith('.bat') or '/installer/' in n for n in z.namelist())
        z.extractall(temp)
    base=temp/'EX메일 익스플로러 포터블'
    manifest=json.loads((base/'portable-manifest.json').read_text())
    for name,sha in manifest['sha256'].items():assert hashlib.sha256((base/name).read_bytes()).hexdigest()==sha,name
    for p in (ROOT/'program').iterdir():
        if p.is_file() and p.suffix in {'.ps1','.cs','.html'}:assert p.read_bytes()==(base/'program'/p.name).read_bytes(),p.name
    # This Linux run replaces only the Windows power-management calls after exact-source verification.
    (base/'program/KeepAwake.ps1').write_text('function Start-MailKeepAwake {return $null}\nfunction Stop-MailKeepAwake {param($Handle)}\n')
    env=os.environ.copy()
    for var,folder in [('XDG_CACHE_HOME','cache'),('XDG_CONFIG_HOME','config'),('XDG_DATA_HOME','xdg-data')]:
        d=temp/folder;d.mkdir();env[var]=str(d)
    def start():return subprocess.Popen([PWSH,'-NoProfile','-File',str(base/'Portable.ps1')],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    process=None
    try:
        process=start();page=ready(process)
        assert '앱 v17.3 · 이미지4' in page
        state=json.loads(request('api/state'));assert state['role'] is None
        token=re.search(r"const token='([^']+)'",page)[1]
        assert not list((base/'data').rglob('MailTransfer-Request-*.txt'))
        # Duplicate-instance detection uses the real owner record and HTTP endpoint.
        # Linux computes process creation time from boot time with sub-ms jitter. Windows
        # uses the exact creation FILETIME; normalize only this native field in the test.
        escaped=str(base).replace("'","''")
        command=". '"+escaped+"/Portable.ps1' -LibraryOnly; $o=Get-Content -Raw '"+escaped+"/data/running.json'|ConvertFrom-Json; $p=Get-Process -Id $o.processId; if([Math]::Abs($p.StartTime.ToUniversalTime().Ticks-[long]$o.startedTicks)-gt1000000){throw 'process timestamp differs'}; function Get-Process {param([int]$Id) $actual=Microsoft.PowerShell.Management\\Get-Process -Id $Id; [pscustomobject]@{ProcessName=$actual.ProcessName;StartTime=[DateTime]::new([long]$o.startedTicks,[DateTimeKind]::Utc)}}; function Open-EXMailPortablePage {param($Url) Write-Output 'REUSED_EXISTING'}; Invoke-EXMailPortable '"+escaped+"'"
        duplicate=subprocess.run([PWSH,'-NoProfile','-Command',command],env=env,capture_output=True,text=True,timeout=12)
        assert duplicate.returncode==0 and 'REUSED_EXISTING' in duplicate.stdout,duplicate.stdout+duplicate.stderr

        inbox=temp/'수신 폴더';inbox.mkdir()
        request('api/role',{'role':'Internal','inbox':str(inbox)},token)
        request('api/count',{'count':37},token)
        settings=json.loads((base/'data/bridge-settings.json').read_text(encoding='utf-8-sig'))
        assert settings['role']=='Internal' and settings['count']==37
        result=base/'data/Internal/last-mail-result.json'
        result.write_text(json.dumps({'mails':[{'subject':'포터블 보관 확인','body':'본문','from':'test@example.invalid'}],'failedMails':[]}),encoding='utf-8')
        process.terminate();process.wait(timeout=8)
        process=start();page=ready(process)
        state=json.loads(request('api/state'))
        assert state['role']=='Internal' and state['lastCount']==37 and state['keyReady'] is False
        assert state['mails'][0]['subject']=='포터블 보관 확인'
        assert not list((base/'data').rglob('MailTransfer-Request-*.txt'))
        assert not (base/'program/bridge-settings.json').exists()
        # Different portable copy must reject the occupied port, not attach to this instance.
        other=temp/'다른 포터블';other.mkdir();(other/'program').mkdir()
        for name in ['Start-Bridge.ps1','Common.ps1','app.html','Maintenance.ps1','Transfer.Image.ps1']:(other/'program'/name).write_text('fixture')
        conflict=subprocess.run([PWSH,'-NoProfile','-Command',". '"+str(base/'Portable.ps1').replace("'","''")+"' -LibraryOnly; try {Invoke-EXMailPortable '"+str(other).replace("'","''")+"';exit 1} catch {Write-Output $_.Exception.Message;exit 0}"],env=env,capture_output=True,text=True,timeout=10)
        assert conflict.returncode==0 and '8765' in conflict.stdout,conflict.stdout+conflict.stderr
        assert not (other/'data/running.json').exists()
        assert json.loads(request('api/state'))['lastCount']==37
        print('PASS final portable ZIP exact app sources and hashes; real HTTP first start, duplicate reuse, role/count/mail persistence after restart, no startup transmission, other-instance port rejection; Windows keep-awake and exact process timestamp mocked')
    finally:
        if process is not None and process.poll() is None:process.terminate();process.wait(timeout=8)
