"""Build the portable Windows x64 launcher with Zig 0.13.0 and package current app."""
from pathlib import Path
import argparse,hashlib,json,os,struct,subprocess,tempfile,zipfile
ROOT=Path(__file__).resolve().parent
DIST=ROOT/'dist'
NAME='EX메일-익스플로러-포터블-v17.3-이미지4'
TOP='EX메일 익스플로러 포터블'
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--zig',default=os.environ.get('ZIG','zig'));args=parser.parse_args()
    DIST.mkdir(exist_ok=True)
    version=subprocess.check_output([args.zig,'version'],text=True).strip()
    if version!='0.13.0':raise RuntimeError('Use Zig 0.13.0 for this release')
    ziglib=Path(json.loads(subprocess.check_output([args.zig,'env'],text=True))['lib_dir'])
    with tempfile.TemporaryDirectory(prefix='exmail-portable-') as tmp:
        exe=Path(tmp)/'EX메일 실행.exe'
        subprocess.run([args.zig,'cc','-target','x86_64-windows-gnu','-nostdlib','-isystem',str(ziglib/'libc/include/any-windows-any'),'-fno-stack-protector','-Wl,--entry,PortableEntry','-Wl,--subsystem,windows','-Os','-s','-lkernel32','-luser32',str(ROOT/'portable/Launcher.c'),'-o',str(exe)],check=True)
        raw=exe.read_bytes();pe=struct.unpack_from('<I',raw,0x3c)[0]
        assert raw[:2]==b'MZ' and raw[pe:pe+4]==b'PE\0\0'
        assert struct.unpack_from('<H',raw,pe+4)[0]==0x8664 # AMD64
        assert struct.unpack_from('<H',raw,pe+24+68)[0]==2 # Windows GUI, no extra launcher console
        files={'EX메일 실행.exe':raw,'Portable.ps1':(ROOT/'portable/Portable.ps1').read_bytes(),'사용방법.txt':(ROOT/'portable/사용방법.txt').read_bytes()}
        for p in sorted((ROOT/'program').iterdir()):
            if p.is_file() and p.suffix in {'.ps1','.cs','.html'}:files['program/'+p.name]=p.read_bytes()
        # Do not ship the installation/startup scripts or old BAT entry point.
        assert 'program/Start-Bridge.ps1' in files and not any(n.endswith('.bat') for n in files)
        manifest={'release':NAME,'base':'v17.3 image4','platform':'Windows x64','compiler':'Zig '+version,'sha256':{n:hashlib.sha256(b).hexdigest() for n,b in files.items()}}
        files['portable-manifest.json']=(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode()
        with zipfile.ZipFile(DIST/(NAME+'.zip'),'w',zipfile.ZIP_DEFLATED) as z:
            for n,b in files.items():z.writestr(TOP+'/'+n,b)
    with zipfile.ZipFile(DIST/(NAME+'-소스.zip'),'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(ROOT.rglob('*')):
            if p.is_file() and not any(n in {'dist','logs','__pycache__'} for n in p.relative_to(ROOT).parts):z.write(p,'EX메일 익스플로러 소스/'+str(p.relative_to(ROOT)))
    (DIST/(NAME+'.sha256')).write_text(hashlib.sha256((DIST/(NAME+'.zip')).read_bytes()).hexdigest()+'  '+NAME+'.zip\n')
    print('Built portable ZIP, source ZIP and SHA256; native AMD64 GUI launcher, no BAT or installer')
if __name__=='__main__':main()
