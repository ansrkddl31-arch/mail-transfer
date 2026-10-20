"""Repackage the supplied v17.2 release with only its app.html popup change."""
from pathlib import Path
import base64, hashlib, io, json, re, zipfile

ROOT = Path(__file__).resolve().parent
DIST = ROOT / 'dist'
DIST.mkdir(exist_ok=True)
NAME = 'EX메일-익스플로러'
REV = 'v17.2-시작프로그램수정3'
template = (ROOT / 'installer/original-v17.2.html').read_text()
original = json.loads(re.search(r'const FILES=(\{.*?\});', template)[1])
files = {p.name: p.read_bytes() for p in sorted((ROOT / 'program').iterdir()) if p.is_file()}
assert set(files) == set(original)
assert [n for n in files if files[n] != base64.b64decode(original[n])] == ['app.html']
bundle = io.BytesIO()
with zipfile.ZipFile(bundle, 'w', zipfile.ZIP_DEFLATED) as z:
    for name, data in files.items():
        z.writestr('EX메일 익스플로러/' + name, data)
payload = bundle.getvalue()
script = (ROOT / 'installer/Install-EXMail.ps1').read_text(encoding='utf-8-sig')
script = script.replace('__BUNDLE_SHA256__', hashlib.sha256(payload).hexdigest()).replace('__PAYLOAD_COUNT__', str(len(files))).replace('__LAUNCHER_BASE64__', base64.b64encode((ROOT / 'installer/Launch-EXMail.ps1').read_bytes()).decode())
header = (ROOT / 'installer/automatic-header.bat').read_text().rstrip()
bat = (header + '\n::EXMAIL_SCRIPT:' + base64.b64encode(script.encode()).decode() + '\n::EXMAIL_ZIP:' + base64.b64encode(payload).decode() + '\n').replace('\n','\r\n').encode('ascii')
html = re.sub(r'const FILES=\{[^\n]+\};', lambda _: 'const FILES=' + json.dumps({n: base64.b64encode(v).decode() for n,v in files.items()}, separators=(',', ':')) + ';', template)
for key, value in [('INSTALL_BAT', bat), ('INSTALL_ZIP', payload)]:
    html = re.sub("const " + key + "='[^']+';", lambda _: "const " + key + "='" + base64.b64encode(value).decode() + "';", html)
# Keep the release's entire installation screen and app styling; distinguish download names.
html = html.replace('자동설치-v17.2.bat', '자동설치-' + REV + '.bat').replace('익스플로러-v17.2.zip', '익스플로러-' + REV + '.zip')
html = html.replace('<title>', '<title>시작프로그램 수정3 · ', 1)
html = html.replace('<section class="card"><h2>시작하기 · 3단계</h2>', '<section class="card"><h2>시작프로그램 자동설치 BAT 등록</h2><p>자동설치 BAT를 실행하면 내부·외부 PC 각각의 시작프로그램에 EXMail-Recover.bat가 저장됩니다. Windows 로그인 시 설치 파일을 확인·복구하고 앱을 엽니다. HTML 폴더 저장만으로는 시작프로그램에 등록되지 않습니다.</p></section><section class="card"><h2>시작하기 · 3단계</h2>', 1)
(DIST / f'{NAME}-설치-{REV}.html').write_text(html)
(DIST / f'{NAME}-자동설치-{REV}.bat').write_bytes(bat)
(DIST / f'{NAME}-{REV}.zip').write_bytes(payload)
(DIST / 'build-manifest.json').write_text(json.dumps({'base': 'user supplied v17.2 HTML', 'revision': REV, 'changed_program_files': ['app.html'], 'sha256': {n: hashlib.sha256(d).hexdigest() for n,d in files.items()}}, ensure_ascii=False, indent=2))
with zipfile.ZipFile(DIST / f'{NAME}-{REV}-소스.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for p in sorted(ROOT.rglob('*')):
        if p.is_file() and not any(n in {'dist', '__pycache__'} for n in p.relative_to(ROOT).parts):
            z.write(p, 'EX메일 익스플로러 소스/' + str(p.relative_to(ROOT)))
print('Built v17.2 popup-only HTML/BAT/ZIP/source: 29 original files unchanged; app.html changed')
