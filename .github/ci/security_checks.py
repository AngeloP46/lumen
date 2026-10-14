"""Small, dependency-free security guardrails for every release/PR."""
import json
import re
import subprocess
import sys
from pathlib import Path

def validate(root):
    errors = []
    for path in sorted((root / '.github/workflows').glob('*.yml')):
        text = path.read_text(encoding='utf-8')
        active = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
        if not re.search(r'^permissions:\n  contents: read\s*$', active, re.M):
            errors.append(f'{path.name}: default token must be read-only')
        if re.search(r'^\s*(pull_request_target|workflow_run):', active, re.M):
            errors.append(f'{path.name}: privileged indirect/untrusted trigger forbidden')
        for action in re.findall(r'^\s*- uses:\s*([^\s#]+)', active, re.M):
            if not re.fullmatch(r'[\w.-]+/[\w./-]+@[0-9a-f]{40}', action):
                errors.append(f'{path.name}: action must use full commit SHA: {action}')
        for checkout in re.finditer(r'^      - uses: actions/checkout@[^\n]+\n([^\n]*(?:\n(?!      -)[^\n]*)*)', active, re.M):
            if 'persist-credentials: false' not in checkout.group(1):
                errors.append(f'{path.name}: checkout must not retain credentials')
        jobs = re.split(r'^  ([\w-]+):\s*$', active.split('\njobs:\n', 1)[-1], flags=re.M)
        for i in range(1, len(jobs), 2):
            job, body = jobs[i:i+2]
            if re.search(r'contents:\s*write', body):
                if path.name != 'build.yml' or job != 'publish':
                    errors.append(f'{path.name}/{job}: only isolated release publication may write')
                for guard in ["github.repository == 'AngeloP46/lumen'", "github.ref == 'refs/heads/main'", "github.event_name != 'pull_request'", 'needs: [build, ready]']:
                    if guard not in body:
                        errors.append(f'{path.name}/{job}: missing trusted publication guard {guard}')
        if 'brew install xcodegen' in active:
            errors.append(f'{path.name}: XcodeGen must use the verified pinned installer')
    lock = json.loads((root / '.github/ci/model-lock.json').read_text(encoding='utf-8'))
    for name, model in lock['models'].items():
        if not re.fullmatch(r'[0-9a-f]{40}', model['revision']):
            errors.append(f'{name}: model revision must be immutable')
        for name, file in model['files'].items():
            if not re.fullmatch(r'[0-9a-f]{64}', file['sha256']) or file['size'] <= 0:
                errors.append(f'{name}: model file needs a SHA-256 and size')
    return errors

if __name__ == '__main__':
    root = Path(__file__).resolve().parents[2]
    errors = validate(root)
    for error in errors:
        print(f'::error::{error}')
    if errors:
        sys.exit(1)
    subprocess.run([sys.executable, str(root / '.github/ci/test-model-security.py')], check=True)
    print('Release security guardrails passed.')
