"""Exercise the actual PowerShell CDP receiver against a local protocol fixture."""
import asyncio, json, os, pathlib, tempfile
import websockets

ROOT=pathlib.Path(__file__).resolve().parent
PWSH=os.environ.get('PWSH','/tmp/exmail-pwsh/runtime/pwsh')
NOTICE='최종사용정보\n최종 접속 시각: 2026.10.20 09:01:09\n최종 접속 아이피: 192.0.2.1\n현재 접속 아이피: 192.0.2.2\n최종 접속 아이피와 현재 아이피가 다릅니다.'

async def scenario(label,message,url,kind,expected,should_ack):
    observed=[]
    async def handler(ws):
        enable=json.loads(await ws.recv());assert enable['method']=='Page.enable'
        command=json.loads(await ws.recv());assert command['method']=='Runtime.evaluate'
        await ws.send(json.dumps({'id':enable['id'],'result':{}}))
        await ws.send(json.dumps({'method':'Page.javascriptDialogOpening','params':{'type':kind,'message':message,'url':url}}))
        await ws.send(json.dumps({'id':command['id'],'result':{'result':{'value':1}}}))
        try:
            ack=json.loads(await asyncio.wait_for(ws.recv(),4))
            observed.append(ack)
            assert ack['method']=='Page.handleJavaScriptDialog' and ack['params']=={'accept':True}
            await ws.send(json.dumps({'id':ack['id'],'result':{}}))
            await ws.wait_closed()
        except websockets.exceptions.ConnectionClosed:
            pass
    with tempfile.TemporaryDirectory(prefix='exmail-cdp-notice-') as temp:
        env=os.environ.copy()
        for key in ('XDG_CACHE_HOME','XDG_CONFIG_HOME','XDG_DATA_HOME'):
            folder=pathlib.Path(temp)/key;folder.mkdir();env[key]=str(folder)
        async with websockets.serve(handler,'127.0.0.1',0) as server:
            port=server.sockets[0].getsockname()[1]
            process=await asyncio.create_subprocess_exec(PWSH,'-NoProfile','-File',str(ROOT/'mail-notice-client.ps1'),'-SocketUrl',f'ws://127.0.0.1:{port}/devtools/page/test','-Expected',expected,env=env,stdout=-1,stderr=-1)
            stdout,stderr=await asyncio.wait_for(process.communicate(),15)
            assert process.returncode==0,(label,stdout.decode(),stderr.decode())
            assert bool(observed)==should_ack,(label,observed)
            print('PASS CDP fixture:',label,'acknowledged='+str(bool(observed)))

async def main():
    await scenario('recognized last-access notice resumes command',NOTICE,'https://mail.ex.co.kr/mail/mainframe','alert','OK',True)
    await scenario('unknown alert requires user','파일을 삭제하시겠습니까?','https://mail.ex.co.kr/mail/mainframe','alert','WEBMAIL_DIALOG_REQUIRES_CONFIRMATION',False)
    await scenario('same text at another origin requires user',NOTICE,'https://example.invalid/mail/mainframe','alert','WEBMAIL_DIALOG_REQUIRES_CONFIRMATION',False)
    await scenario('confirmation never auto accepted',NOTICE,'https://mail.ex.co.kr/mail/mainframe','confirm','WEBMAIL_DIALOG_REQUIRES_CONFIRMATION',False)
    await scenario('password failure still returned','비밀번호가 틀렸습니다.','https://mail.ex.co.kr/login','alert','LOGIN_INVALID_CREDENTIALS',True)

if __name__=='__main__':asyncio.run(main())
