"""Repackage the supplied v17.2 release with only its app.html popup change."""
from pathlib import Path
import base64, hashlib, io, json, re, zipfile

ROOT = Path(__file__).resolve().parent
DIST = ROOT / 'dist'
DIST.mkdir(exist_ok=True)
NAME = 'EX메일-익스플로러'
REV = 'v17.2-위치설정수정1'
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
bat = base64.b64decode(re.search(r"const INSTALL_BAT='([^']+)';", template)[1]).decode('ascii')
script = base64.b64decode(re.search(r'^::EXMAIL_SCRIPT:([A-Za-z0-9+/=]+)', bat, re.M)[1]).decode('utf-8-sig')
script, count = re.subn(r"if\(\(Get-EXMailDigest \$bytes\)-ne'[a-f0-9]{64}'\)",
    "if((Get-EXMailDigest $bytes)-ne'" + hashlib.sha256(payload).hexdigest() + "')", script)
assert count == 1
bat = re.sub(r'(?m)^::EXMAIL_SCRIPT:[A-Za-z0-9+/=]+', lambda _: '::EXMAIL_SCRIPT:' + base64.b64encode(script.encode()).decode(), bat)
bat = re.sub(r'(?m)^::EXMAIL_ZIP:[A-Za-z0-9+/=]+', lambda _: '::EXMAIL_ZIP:' + base64.b64encode(payload).decode(), bat).encode('ascii')
html = re.sub(r'const FILES=\{[^\n]+\};', lambda _: 'const FILES=' + json.dumps({n: base64.b64encode(v).decode() for n,v in files.items()}, separators=(',', ':')) + ';', template)
for key, value in [('INSTALL_BAT', bat), ('INSTALL_ZIP', payload)]:
    html = re.sub("const " + key + "='[^']+';", lambda _: "const " + key + "='" + base64.b64encode(value).decode() + "';", html)
# Keep the release's entire installation screen and app styling; distinguish download names.
html = html.replace('자동설치-v17.2.bat', '자동설치-' + REV + '.bat').replace('익스플로러-v17.2.zip', '익스플로러-' + REV + '.zip')
html = html.replace('<title>', '<title>위치설정 수정1 · ', 1)
(DIST / f'{NAME}-설치-{REV}.html').write_text(html)
(DIST / f'{NAME}-자동설치-{REV}.bat').write_bytes(bat)
(DIST / f'{NAME}-{REV}.zip').write_bytes(payload)
(DIST / 'build-manifest.json').write_text(json.dumps({'base': 'user supplied v17.2 HTML', 'revision': REV, 'changed_program_files': ['app.html'], 'sha256': {n: hashlib.sha256(d).hexdigest() for n,d in files.items()}}, ensure_ascii=False, indent=2))
with zipfile.ZipFile(DIST / f'{NAME}-{REV}-소스.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for p in sorted(ROOT.rglob('*')):
        if p.is_file() and not any(n in {'dist', '__pycache__'} for n in p.relative_to(ROOT).parts):
            z.write(p, 'EX메일 익스플로러 소스/' + str(p.relative_to(ROOT)))
print('Built v17.2 popup-only HTML/BAT/ZIP/source: 29 original files unchanged; app.html changed')
