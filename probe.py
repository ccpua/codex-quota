import json, subprocess, selectors, time

p = subprocess.Popen(['/Applications/ChatGPT.app/Contents/Resources/codex', 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
def send(value):
    p.stdin.write(json.dumps(value) + '\n')
    p.stdin.flush()
send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'codex_quota_monitor', 'title': 'Codex Quota', 'version': '1.3.0'}}})
s = selectors.DefaultSelector()
s.register(p.stdout, selectors.EVENT_READ)
deadline = time.monotonic() + 35
try:
    while time.monotonic() < deadline:
        if not s.select(1):
            continue
        line = p.stdout.readline()
        if not line:
            raise RuntimeError('App server exited')
        msg = json.loads(line)
        if msg.get('id') == 1:
            if 'error' in msg:
                print(json.dumps(msg)); break
            send({'method': 'initialized'})
            send({'id': 2, 'method': 'account/rateLimits/read'})
        elif msg.get('id') == 2:
            result = msg.get('result', {})
            print(json.dumps({'rateLimits': result.get('rateLimits'), 'rateLimitsByLimitId': result.get('rateLimitsByLimitId'), 'error': msg.get('error')}, ensure_ascii=False))
            break
    else:
        raise RuntimeError('Timed out')
finally:
    p.terminate()
    try: p.wait(timeout=3)
    except subprocess.TimeoutExpired: p.kill()
