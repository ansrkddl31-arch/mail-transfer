import json,os,socket,subprocess,tempfile,urllib.request,urllib.error
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
env=os.environ|{k:'/tmp/mail-transfer-pwsh-validation/'+v for k,v in {'XDG_CACHE_HOME':'cache','XDG_CONFIG_HOME':'config','XDG_DATA_HOME':'data'}.items()}
with tempfile.TemporaryDirectory(prefix='reset-http-') as root:
 p=subprocess.Popen(['/tmp/mail-transfer-pwsh-validation/pwsh','-NoProfile','-File','/workspace/scratch/claude-mail-transfer-v17.2-qa/reset-http.ps1','-QaPort',str(port),'-QaRoot',root],env=env,stdout=-1,stderr=-1,text=True)
 def call(path,body=None,token='qa-token'):
  req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,data=None if body is None else json.dumps(body).encode(),headers={'Content-Type':'application/json','Origin':f'http://127.0.0.1:{port}','X-Mail-Transfer-Token':token})
  try:
   with urllib.request.urlopen(req,timeout=4) as r:return r.status,json.load(r)
  except urllib.error.HTTPError as e:return e.code,json.load(e)
 body={'operationId':'a'*32,'reconnect':True}
 try:
  assert p.stdout.readline().strip()=='READY'
  state=call('/api/state')[1];assert not state['connectionAttempted'] and not state['connecting']
  assert call('/api/connection-reset',body,'bad')[0]==403
  assert call('/api/connection-reset',body|{'operationId':'bad'})[1]['error']=='RESET_ID_INVALID'
  assert call('/api/connection-reset',body|{'reconnect':'true'})[1]['error']=='RESET_REQUEST_INVALID'
  assert call('/api/connection-reset',body)[0]==200
  assert call('/api/connection-reset',body)[0]==200
  state=call('/api/state')[1];assert state['connecting'] and state['connectionAttempted'] and not state['keyReady']
  assert call('/api/connection-reset',body)[1]['error']=='ROLE_NOT_INTERNAL'
  assert call('/api/connection-reset',body)[1]['error']=='SETUP_IN_PROGRESS'
  out,err=p.communicate(timeout=4);assert p.returncode==0,(out,err);print(out.strip())
 finally:
  if p.poll() is None:p.kill();p.communicate()
