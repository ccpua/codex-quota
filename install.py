"""Install or update the standalone Codex Quota app."""
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time


def monitor_pids(source, destination, legacy_destination=None):
    allowed = {
        str(source / 'Codex Quota.app/Contents/MacOS/CodexQuota'),
        str(destination / 'Contents/MacOS/CodexQuota'),
    }
    if legacy_destination is not None:
        allowed.add(str(legacy_destination / 'Contents/MacOS/CodexQuota'))
    processes = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
    return [int(pair[0]) for line in processes.splitlines()
            if len(pair := line.strip().split(None, 1)) == 2 and pair[1] in allowed]


def stop_monitors(pids):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    for pid in pids:
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Previous quota monitor has not exited; installation stopped.')


def install():
    source = pathlib.Path(__file__).resolve().parent
    home = pathlib.Path.home()
    destination = home / 'Applications' / 'Codex Quota.app'
    legacy_destination = home / 'Applications' / 'Codex 额度.app'
    built_app = source / 'Codex Quota.app'
    agent = home / 'Library' / 'LaunchAgents' / 'local.ming.codexquota.watcher.plist'
    domain = f'gui/{os.getuid()}'
    service = f'{domain}/local.ming.codexquota.watcher'
    # Validate before stopping the working installation.
    if not (built_app / 'Contents/MacOS/CodexQuota').is_file():
        raise RuntimeError('Build the app first: zsh build.sh')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(built_app)], check=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = pathlib.Path(tempfile.mkdtemp(prefix='.codex-quota-update-', dir=destination.parent))
    incoming = staging / 'new.app'
    previous = staging / 'previous.app'
    previous_legacy = staging / 'previous-legacy.app'
    old_agent = agent.read_bytes() if agent.exists() else None
    watcher_loaded = subprocess.run(['launchctl', 'print', service], stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL).returncode == 0
    paused = False
    replaced = False
    legacy_moved = False
    pids = []
    try:
        shutil.copytree(built_app, incoming)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(incoming)], check=True)
        pids = monitor_pids(source, destination, legacy_destination)
        if watcher_loaded:
            subprocess.run(['launchctl', 'bootout', service], check=True)
        paused = True
        stop_monitors(pids)
        if destination.exists():
            destination.rename(previous)
        if legacy_destination.exists():
            legacy_destination.rename(previous_legacy)
            legacy_moved = True
        try:
            incoming.rename(destination)
        except BaseException:
            if previous.exists():
                previous.rename(destination)
            raise
        replaced = True
        if agent.exists():
            agent.unlink()
        if pids:
            subprocess.run(['open', '-g', str(destination)], check=True)
    except BaseException:
        if paused:
            subprocess.run(['launchctl', 'bootout', service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if replaced:
                destination.rename(staging / 'failed.app')
                if previous.exists():
                    previous.rename(destination)
            if legacy_moved and previous_legacy.exists() and not legacy_destination.exists():
                previous_legacy.rename(legacy_destination)
            if old_agent is not None:
                agent.write_bytes(old_agent)
            elif agent.exists():
                agent.unlink()
            if watcher_loaded and old_agent is not None and agent.exists():
                subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], check=False)
            if pids and destination.exists():
                subprocess.run(['open', '-g', str(destination)], check=False)
        raise
    finally:
        shutil.rmtree(staging)
    print(f'Installed: {destination}')
    print('Automatic Codex launch integration: removed')
    print('Preserved monitor state: ' + ('running' if pids else 'closed or first installation'))


if __name__ == '__main__':
    install()
