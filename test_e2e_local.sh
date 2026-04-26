#!/usr/bin/env bash
# E2E test for secrets-lambda — runs locally without Docker
# Uses Cloudflare Turnstile test key (always passes) to validate full flow
set -e

export SECRET_KEY="${SECRET_KEY:-local-test-secret-key-xyz}"
export CF_SECRET_KEY="${CF_TEST_KEY:-1x0000000000000000000000000000000AA}"

echo "Running E2E tests..."
PYTHONPATH="$(pwd)" python3 - << 'PYEOF'
import sys, os, json
from unittest.mock import MagicMock, patch

stored = {}
with patch('utils.vault_manager.VaultManager') as MockVM:
    vm = MagicMock()
    vm.set_secret.side_effect = lambda n,v: stored.__setitem__(n,v)
    vm.get_secret.side_effect = lambda n: stored.get(n)
    vm.delete_secret.side_effect = lambda n: stored.pop(n, None)
    MockVM.return_value = vm
    from lambda_handler import lambda_handler as handler

    CF = "XXXX.DUMMY.TOKEN.XXXX"
    mk = lambda a, **kw: {'body': json.dumps({'action':a,'turnstile_token':CF,**kw})}
    fail = 0

    def check(name, status, val=None, expect=None):
        global fail
        ok = (val == expect) if expect is not None else True
        ok = ok and status in (200, 201)
        print(f"  {'✅' if ok else '❌'} {name}: HTTP {status}" + (f" | {val}" if val else ""))
        if not ok: fail += 1

    r = handler(mk('create', secret='github-pat-abc123', password='s3cr3t'), None)
    b = json.loads(r['body']); uuid = b.get('uuid')
    check("Create PQC secret", r['statusCode'], uuid[:8]+"..." if uuid else None)

    pqc = any(str(v).startswith('PQC:') for v in stored.values())
    print(f"  {'✅' if pqc else '❌'} Stored as PQC encrypted")
    if not pqc: fail += 1

    r2 = handler(mk('retrieve', uuid=uuid, password='s3cr3t'), None)
    b2 = json.loads(r2['body'])
    check("Retrieve + decrypt", r2['statusCode'], b2.get('secret'), 'github-pat-abc123')

    r3 = handler(mk('create', secret='x'*(17*1024), password='p'), None)
    ok3 = r3['statusCode'] == 400
    print(f"  {'✅' if ok3 else '❌'} Size limit 17KB: HTTP {r3['statusCode']} (expect 400)")
    if not ok3: fail += 1

    r4 = handler({'body': json.dumps({'action':'healthcheck'})}, None)
    b4 = json.loads(r4['body'])
    ok4 = r4['statusCode'] == 200 and b4.get('status') == 'healthy'
    print(f"  {'✅' if ok4 else '❌'} Healthcheck: {b4.get('status')}")
    if not ok4: fail += 1

    print(f"\n{'✅ All tests PASSED!' if fail==0 else f'❌ {fail} test(s) FAILED'}")
    sys.exit(fail)
PYEOF
