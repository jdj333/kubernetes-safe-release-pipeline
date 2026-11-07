"""Render real Helm templates and check operational invariants and invalid values."""
from pathlib import Path
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = str(ROOT / 'charts/safe-release')


def render(*args):
    return list(yaml.safe_load_all(subprocess.check_output(['helm', 'template', 'safe-release', CHART, *args], text=True)))


for overlay, fault in [(None, None), ('broken-readiness', 'FAIL_READINESS'), ('broken-business', 'FAIL_BUSINESS')]:
    objects = render(*(['-f', str(ROOT / f'examples/{overlay}.yaml')] if overlay else []))
    by_kind = {item['kind']: item for item in objects if item}
    dep = by_kind['Deployment']['spec']
    pod = dep['template']['spec']
    app = pod['containers'][0]
    assert dep['replicas'] == 2
    assert dep['strategy']['rollingUpdate'] == {'maxUnavailable': 0, 'maxSurge': 1}
    assert dep['progressDeadlineSeconds'] > dep['minReadySeconds']
    assert pod['terminationGracePeriodSeconds'] >= 20
    assert not pod['automountServiceAccountToken']
    assert app['securityContext']['readOnlyRootFilesystem']
    assert app['lifecycle']['preStop']['exec']['command'] == ['python', '/app/server.py', 'drain']
    assert [app[p]['httpGet']['path'] for p in ('startupProbe', 'readinessProbe', 'livenessProbe')] == ['/startupz', '/readyz', '/healthz']
    assert by_kind['Service']['spec']['selector'] == dep['selector']['matchLabels']
    assert by_kind['PodDisruptionBudget']['spec']['selector']['matchLabels'] == dep['selector']['matchLabels']
    env = {v['name']: v['value'] for v in app['env']}
    assert env['FAIL_READINESS'] == str(fault == 'FAIL_READINESS').lower()
    assert env['FAIL_BUSINESS'] == str(fault == 'FAIL_BUSINESS').lower()

for invalid in ('replicaCount=1', 'terminationGracePeriodSeconds=5', 'rollout.maxUnavailable=1',
                'rollout.maxSurge=0', 'rollout.progressDeadlineSeconds=5', 'app.startupDelaySeconds=100'):
    p = subprocess.run(['helm', 'template', 'safe-release', CHART, '--set', invalid], capture_output=True)
    assert p.returncode != 0, f'Unsafe configuration accepted: {invalid}'
digest = 'sha256:' + 'a' * 64
objects = render('--set-string', f'image.digest={digest}')
app = next(x for x in objects if x and x['kind'] == 'Deployment')['spec']['template']['spec']['containers'][0]
assert app['image'] == 'safe-release@' + digest
print('PASS: chart defaults, both faults, selectors, probes, digest, and six invalid configurations')
