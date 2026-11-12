"""Run only reviewed Project1 suites with live DB/network connections denied.

No .env edits, startup lifespan, existing PostgreSQL cluster or provider calls.
Use --output outside the repository for test evidence.
"""
from pathlib import Path
import argparse
import os
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--suite', choices=['integration', 'successor', 'candidate', 'workflow', 'bcb', 'domain'])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    suites = {
        'integration': ['tests/integration'],
        'successor': ['tests/cq_successor'],
        'candidate': ['tests/candidate'],
        'workflow': ['tests/project1/test_workflow.py'],
        'bcb': ['tests/project1/bcb'],
        'domain': ['tests/domain'],
    }
    if args.worker:
        if os.environ.get('P1_OFFLINE_GUARD') != '1':
            raise SystemExit('Guarded parent required.')
        import socket
        pipes = [socket.socketpair() for _ in range(128)]
        socket.socketpair = lambda *a, **kw: pipes.pop()
        def denied(*a, **kw):
            raise RuntimeError('Project1 offline verification refuses external connections.')
        socket.socket.connect = denied
        socket.socket.connect_ex = denied
        socket.create_connection = denied
        import psycopg2
        psycopg2.connect = denied
        from sqlalchemy.engine import Engine
        original = Engine.connect
        def guarded_connect(engine, *a, **kw):
            if engine.url.get_backend_name() != 'sqlite' or engine.url.database not in (None, '', ':memory:'):
                return denied()
            return original(engine, *a, **kw)
        Engine.connect = guarded_connect
        import pytest
        targets = suites[args.suite]
        cut = 'tests/project1' if args.suite == 'workflow' else targets[0]
        try:
            return pytest.main([*targets, '--confcutdir='+cut, '-q',
                '--junitxml='+str(args.output/(args.suite+'.xml'))])
        finally:
            for pair in pipes:
                for sock in pair:
                    sock.close()
    args.output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    fake = 'postgresql+psycopg2://disabled:disabled@127.0.0.1:1/project1_offline'
    env.update(DATABASE_URL=fake, ANALYTICS_DATABASE_URL=fake,
        PROJECT1_CP07_ENABLED='false', PROJECT1_WORKFLOW_ENABLED='false',
        M2_UPSTREAM_ENABLED='false', P1_OFFLINE_GUARD='1', PYTHONDONTWRITEBYTECODE='1',
        PYTHONIOENCODING='utf-8', PYTHONPATH=str(root/'src')+os.pathsep+str(root))
    codes = []
    for suite in ([args.suite] if args.suite else suites):
        env['M2_UPSTREAM_ENABLED'] = 'true' if suite == 'integration' else 'false'
        env['P1_CONTRACT_OUTPUT'] = str(args.output.resolve()/'readiness_contract.json')
        result = subprocess.run([sys.executable, '-B', str(Path(__file__).resolve()),
            '--worker', '--suite', suite, '--output', str(args.output.resolve())],
            cwd=root, env=env, capture_output=True, text=True, encoding='utf-8', timeout=180)
        (args.output/(suite+'.log')).write_text(result.stdout+result.stderr,encoding='utf-8')
        codes.append(result.returncode)
        print(suite+': '+('PASS' if result.returncode == 0 else 'FAIL/BLOCKED'), flush=True)
        print(result.stdout[-1800:], flush=True)
    return int(any(codes))


if __name__ == '__main__':
    raise SystemExit(main())
