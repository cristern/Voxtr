"""Fail if any vendored production module differs from the recorded Git blob."""
import hashlib
import json
from pathlib import Path
root = Path(__file__).resolve().parents[2] / 'Tests/Fixtures/DeviceActions'
pin = json.loads((root / 'backend-pin.json').read_text())
assert pin['revision'] == '419f70e80b69ae524edb066e367093b1b8455a9a'
for name, expected in pin['files'].items():
    data = (root / 'backend' / name).read_bytes()
    assert hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == expected['gitBlob'], name
    assert hashlib.sha256(data).hexdigest() == expected['sha256'], name
print('PASS: 3 unchanged production backend modules match pinned Git blobs/SHA-256')
