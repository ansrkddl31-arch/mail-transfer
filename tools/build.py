"""Offline build from committed sources. No downloaded templates or workspace-specific inputs."""
from pathlib import Path
import base64,hashlib,io,json,zipfile,html
ROOT=Path(__file__).resolve().parent.parent
DIST=ROOT/'dist';DIST.mkdir(exist_ok=True)
RELEASE='v18.2-r1'
files={p.name:p.read_bytes() for p in sorted((ROOT/'program').iterdir()) if p.is_file()}
assert len(files)==35
buf=io.BytesIO()
with zipfile.ZipFile(buf,'w',zipfile.ZIP_DEFLATED) as z:
 for name,data in files.items():
  info=zipfile.ZipInfo('EX메일 익스플로러/'+name,date_time=(2026,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;z.writestr(info,data)
bundle=buf.getvalue();digest=hashlib.sha256(bundle).hexdigest()
launcher=(ROOT/'installer/Launch-EXMail.ps1').read_bytes()
installer=(ROOT/'installer/Install-EXMail.ps1').read_text(encoding='utf-8-sig').replace('__BUNDLE_SHA256__',digest).replace('__PAYLOAD_COUNT__',str(len(files))).replace('__LAUNCHER_BASE64__',base64.b64encode(launcher).decode())
assert '__LAUNCHER_BASE64__' not in installer
header=(ROOT/'installer/automatic-header.bat').read_text()
bat=header.rstrip()+'\n::EXMAIL_SCRIPT:'+base64.b64encode(installer.encode()).decode()+'\n::EXMAIL_ZIP:'+base64.b64encode(bundle).decode()+'\n'
bat=bat.replace('\n','\r\n').encode('ascii')
bat_name=f'EX메일-익스플로러-자동설치-{RELEASE}.bat';zip_name=f'EX메일-익스플로러-{RELEASE}.zip'
(DIST/bat_name).write_bytes(bat);(DIST/zip_name).write_bytes(bundle)
template=(ROOT/'installer/install.html').read_text()
template=template.replace('__RELEASE__',RELEASE).replace('__BAT_BASE64__',base64.b64encode(bat).decode()).replace('__BAT_FILENAME__',bat_name).replace('__ZIP_BASE64__',base64.b64encode(bundle).decode()).replace('__ZIP_FILENAME__',zip_name)
(DIST/f'EX메일-익스플로러-설치-{RELEASE}.html').write_text(template)
manifest={'release':RELEASE,'restored_from':'user-provided v18.2 BAT','files':{n:hashlib.sha256(d).hexdigest() for n,d in files.items()},'zip_sha256':digest,'installer_sha256':hashlib.sha256(bat).hexdigest()}
(DIST/'build-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
source_name=f'EX메일-익스플로러-{RELEASE}-소스.zip'
with zipfile.ZipFile(DIST/source_name,'w',zipfile.ZIP_DEFLATED) as z:
 for p in sorted(ROOT.rglob('*')):
  rel=p.relative_to(ROOT)
  if p.is_file() and not any(x in {'.git','dist','node_modules','__pycache__','.test-output'} for x in rel.parts):z.write(p,'EX메일 익스플로러 소스/'+str(rel))
print(f'Built {RELEASE}: {len(files)} exact program files; HTML, self-contained recovery BAT, program ZIP and complete source ZIP')
