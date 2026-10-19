"""Package the standalone read-only diagnostic; never modify the released app."""
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parent.parent
source = root / 'tools/transfer-image-probe'
target = root / 'releases/image-probe-v1/자료교환-이미지인식-진단-v1.zip'
target.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name in ['Detector.cs', 'Test-ImageRecognition.ps1', '이미지인식진단.bat', 'README.md']:
        archive.write(source / name, '자료교환 이미지인식 진단/' + name)
with zipfile.ZipFile(target) as archive:
    assert archive.testzip() is None
    assert len(archive.namelist()) == 4
print(target)
