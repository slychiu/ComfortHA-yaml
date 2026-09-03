#!/usr/bin/env python3
# v42: runtime companion to first_boot.sh's boot-time integrity check.
#
# first_boot.sh catches a corrupt configuration.yaml at OS boot; but the
# damage usually happens WHILE the system is running, and the file is only
# re-read when HA core next (re)starts -- which could be weeks later, when
# an update lands and lands in HA recovery mode before any boot ran.
# This script runs periodically from inside HA core (same tolerant YAML
# loader, same snapshot) so corruption is found and repaired the same day:
#   - clean pass  -> refresh the known-good snapshot (mirrors the boot path)
#   - corrupt     -> restore from snapshot (broken copy kept as
#                    configuration.yaml.corrupt.<ts>), write the integrity
#                    alert, fire a core restart (forked by the caller, so the
#                    running core dying does not kill this) and let the
#                    dashboard/popup/email automation tell the owner
#   - corrupt and NO usable snapshot -> alert with "could not self-repair"
#
# Exit codes / status file values: 0=ok, 1=corrupt-no-recovery, 2=restored+restart.
#
# Safe properties, same as the boot path: the snapshot is only refreshed
# after the live config parsed clean, so a corrupt state can never be
# snapshotted as "good"; and no restore happens unless the snapshot itself
# parses, so there is no restore loop. .storage/* is deliberately ignored --
# HA's own storage helper quarantines those files and starts fresh, and
# rewinding them would roll back the owner's settings/edits.

import json
import os
import subprocess
import sys
import time

import yaml

CONFIG = '/config/configuration.yaml'
SNAP = '/config/.cytech_snapshot/configuration.yaml'
SNAP_PREV = '/config/.cytech_snapshot/configuration.yaml.previous'
ALERT = '/config/.cytech_integrity_alert'
STATUS = '/config/.cytech_integrity_status'


class TolerantLoader(yaml.SafeLoader):
    pass


def _construct_any_tag(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    return None


TolerantLoader.add_multi_constructor('!', _construct_any_tag)


def parse_ok(path):
    """True if the file at path parses as YAML under the tolerant loader."""
    try:
        with open(path, 'r', encoding='utf-8') as f:
            yaml.load(f, Loader=TolerantLoader)
        return True
    except Exception:
        return False


def snapshot_refresh():
    """Rolling known-good copy; only called after a clean parse of the live file."""
    os.makedirs('/config/.cytech_snapshot', exist_ok=True)
    # skip the rewrite if unchanged (avoids pointless card writes every cycle)
    try:
        with open(SNAP, 'r', encoding='utf-8') as f:
            if f.read() == open(CONFIG, 'r', encoding='utf-8').read():
                return
    except OSError:
        pass
    try:
        if os.path.exists(SNAP):
            os.replace(SNAP, SNAP_PREV)
    except OSError:
        pass
    tmp = SNAP + '.tmp'
    with open(CONFIG, 'r', encoding='utf-8') as src, open(tmp, 'w', encoding='utf-8') as dst:
        dst.write(src.read())
    os.chmod(tmp, 0o600)
    os.replace(tmp, SNAP)


def write_alert(message):
    with open(ALERT, 'w', encoding='utf-8') as f:
        json.dump({'ts': str(int(time.time())), 'message': message}, f)


def write_status(state_code):
    with open(STATUS, 'w', encoding='utf-8') as f:
        f.write('%s %d\n' % (state_code, int(time.time())))


def restart_core():
    # Fire-and-forget (Popen, never waited on): if this hangs on a busy
    # supervisor it must not stall the checker, and when the restart does
    # land it kills the very container this process runs in anyway. The
    # file is ALREADY restored at this point -- the restart is a nicety to
    # converge core on the recovered config; if it never happens, the next
    # natural restart (or the boot-time path) comes up clean regardless.
    token = os.environ.get('SUPERVISOR_TOKEN', '')
    if not token:
        return
    try:
        with open(os.devnull, 'w') as devnull:
            subprocess.Popen(['curl', '-s', '-X', 'POST', '-o', '/dev/null',
                              '-H', 'Authorization: Bearer ' + token,
                              'http://supervisor/core/restart'],
                             stdout=devnull, stderr=devnull)
    except Exception:  # noqa: BLE001 - best effort, boot path covers the file
        write_status('restart_failed')


def main():
    if not os.path.exists(CONFIG):
        write_status('missing')
        sys.exit(3)
    if parse_ok(CONFIG):
        snapshot_refresh()
        # clean pass clears any stale alert this script or boot left behind
        try:
            os.unlink(ALERT)
        except OSError:
            pass
        write_status('ok')
        sys.exit(0)

    # corrupt
    if os.path.exists(SNAP) and parse_ok(SNAP):
        ts = time.strftime('%Y%m%d-%H%M%S')
        try:
            os.replace(CONFIG, '/config/configuration.yaml.corrupt.' + ts)
        except OSError:
            pass  # if we cannot move the broken copy, copy the good one anyway
        with open(SNAP, 'r', encoding='utf-8') as src, open(CONFIG, 'w', encoding='utf-8') as dst:
            dst.write(src.read())
        write_alert(
            "Data integrity issue detected on this device's SD card: configuration.yaml "
            "was found corrupted while the system was running. It WAS restored from the "
            "last known-good snapshot (the broken copy is saved as "
            "configuration.yaml.corrupt.<timestamp>) and HA is restarting to load the "
            "recovered config. The card is showing the same failure signature as the last "
            "corruption incidents -- check the device soon.")
        write_status('restored')
        restart_core()
        sys.exit(2)
    write_alert(
        "Data integrity issue detected on this device's SD card: configuration.yaml "
        "was found corrupted while the system was running. The system could not "
        "self-repair: no usable snapshot of configuration.yaml exists on this device.")
    write_status('error')
    sys.exit(1)


if __name__ == '__main__':
    main()
