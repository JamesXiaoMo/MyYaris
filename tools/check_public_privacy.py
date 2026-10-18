#!/usr/bin/env python3
"""Check tracked files for environment identifiers before publishing.

Run from any repository: python3 /path/to/check_public_privacy.py [repo]
This is a narrow privacy guard, not a complete secret or binary-content audit.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else '.').resolve()
patterns = {
    'personal Tailnet hostname': re.compile(rb'[A-Za-z0-9.-]+\.tail[a-f0-9]{4,}\.ts\.net', re.I),
    'absolute user home path': re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+'),
    'GitHub credential': re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})'),
}
paths = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).decode().split('\0')
findings = []
for name in filter(None, paths):
    p = root / name
    if not p.is_file():
        continue
    if p.name == '.env' or p.suffix.lower() in {'.p12', '.mobileprovision', '.keystore', '.jks', '.db', '.sqlite'}:
        findings.append((name, 0, 'credential/signing/runtime data file'))
        continue
    if p.stat().st_size > 4_000_000:
        continue
    data = p.read_bytes()
    if b'\0' in data[:1024]:
        continue
    for category, pattern in patterns.items():
        for match in pattern.finditer(data):
            # Upstream container-internal home, not a developer's personal path.
            if name == 'deploy/anisette/docker-compose.anisette.yml' and match.group() == b'/home/Alcoholic':
                continue
            findings.append((name, data.count(b'\n', 0, match.start()) + 1, category))
for path, line, category in findings:
    print(f'{path}:{line}: {category}')
print(f'Privacy guard: {len(findings)} finding(s); values are intentionally not printed.')
sys.exit(bool(findings))
