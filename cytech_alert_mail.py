#!/usr/bin/env python3
# v48a: fleet-owned alert mail sender. Replaces the two
#   notify: - platform: smtp
# platforms HA is retiring (the legacy notify services stop working in HA
# 2027.3, and HA 2026.8+ raises homeassistant/deprecated_yaml_smtp against the
# generated packages/cytech_email.yaml that used to define them). This sends
# mail with smtplib directly -- the same idiom cytech_register_email.sh has
# always used -- so the behaviour is identical on every HA version in the fleet
# (the 2026.6 bench image through 2026.9) and nothing has to be written into
# HA's own storage or config entries.
#
# Usage:  python3 /config/cytech_alert_mail.py <kind> [--dry-run]
#   kinds: integrity | sdcard | canary | boot | test
#
# It is called from packages/cytech.yaml by five FIXED shell_commands, one per
# kind. The kind is a device-side constant: no alert text, no owner input and
# no template ever reaches a shell command line. The message is read HERE, out
# of the same device-local result file HA's own command_line sensors read, so
# the wording is exactly what the dashboards show.
#
# Exit codes. The exit code IS the alarm: every call site is inline (no
# nohup/&), because a detached send would look successful no matter what
# happened (the v45b rule -- a failure must never be reported as a success).
#   0  every intended copy was sent
#   1  bad usage / unknown kind
#   2  email not configured (no CY_SMTP_USER/CY_SMTP_PASS), or 'test' with no
#      address to send to. The on-screen alert/popup is unaffected either way.
#   3  send failed after ATTEMPTS tries
# HA hard-kills a shell_command at 60s: ATTEMPTS x TIMEOUT + backoff is ~42s
# for one copy, and a failed support copy stops the run before the owner copy
# is attempted, so that budget is never exceeded.
import json
import os
import smtplib
import sys
import time
from email.message import EmailMessage

SUPPORT = 'support@cytech.biz'
ATTEMPTS = 2
TIMEOUT = 20
BACKOFF = 2

# The env overrides are for OFFLINE TESTING ONLY; on-device these are the real
# paths (the same convention as ensure_comfort_alarm_template's CY_CFG).
SECRETS = os.environ.get('CY_SECRETS', '/config/.cytech_secrets')
REGISTERED = os.environ.get('CY_REGISTERED', '/config/.cytech_registered')
DEVICE_ID = os.environ.get('CY_DEVICE_ID', '/config/device_id.txt')
LOG = os.environ.get('CY_ALERT_LOG', '/config/cytech_alerts.log')
RESULT_DIR = os.environ.get('CY_RESULT_DIR', '/config')

# kind -> (result file, subject, body prefix). The subject and body wording is
# byte-identical to what the four automations sent through
# notify.cytech_alert_support / notify.cytech_alert_email before v48a, and the
# result files are the ones their command_line sensors already read.
KINDS = {
    'integrity': ('.cytech_integrity_alert', 'Cytech data integrity alert: %s', '%s: '),
    'sdcard': ('.cytech_sdcard_result', 'Cytech SD card alert: %s', '%s: SD card problem: '),
    'canary': ('.cytech_canary_result', 'Cytech SD canary alert: %s', '%s: SD canary failed: '),
    'boot': ('.cytech_boot_result', 'Cytech repeated restarts alert: %s',
             '%s: Repeated restarts detected: '),
    'test': (None, 'Cytech test email: %s', ''),
}
FALLBACK = 'see sensor'
TEST_BODY = 'Test email from a Cytech system.'


def load_values(path):
    """KEY=VALUE pairs, parsed -- never sourced, so a value containing shell
    metacharacters can never become code."""
    values = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and '=' in line and not line.startswith('#'):
                    k, v = line.split('=', 1)
                    values[k.strip()] = v.strip()
    return values


def first_line(path):
    try:
        with open(path) as f:
            return f.readline().strip()
    except OSError:
        return ''


def read_message(path):
    """The alert text, straight out of the result file the sensor is showing.

    Deliberately NOT re-checking the file's own status field: the automation
    only fires on the sensor's state change, and a re-check would silently DROP
    the mail if the check ran again in between. A rare stale line is far better
    than a missing alert. Missing/garbled file -> the generic wording, still
    sent."""
    try:
        with open(path) as f:
            return (json.load(f).get('message') or '').strip() or FALLBACK
    except Exception:
        return FALLBACK


def log_line(text):
    try:
        if os.path.exists(LOG):
            with open(LOG) as f:
                lines = f.readlines()
            if len(lines) > 500:
                with open(LOG, 'w') as f:
                    f.writelines(lines[-500:])
        with open(LOG, 'a') as f:
            f.write('%s %s\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), text))
    except OSError:
        pass


def send(user, password, sender, to, subject, body, dry):
    if dry:
        print('DRY RUN: To: %s (From: %s)' % (to, sender))
        print('DRY RUN: Subject: %s' % subject)
        print('DRY RUN: body:')
        print(body)
        return None
    last = None
    for attempt in range(1, ATTEMPTS + 1):
        try:
            msg = EmailMessage()
            msg['From'] = sender
            msg['To'] = to
            msg['Subject'] = subject
            msg.set_content(body)
            with smtplib.SMTP_SSL('smtp.gmail.com', 465, timeout=TIMEOUT) as smtp:
                smtp.login(user, password)
                smtp.send_message(msg)
            return None
        except Exception as e:  # noqa: BLE001 -- any failure means "not sent"
            last = e
            if attempt < ATTEMPTS:
                time.sleep(BACKOFF)
    return last


def main():
    args = [a for a in sys.argv[1:] if a != '--dry-run']
    dry = '--dry-run' in sys.argv[1:]
    kind = args[0] if len(args) == 1 else None
    if kind not in KINDS:
        print('usage: cytech_alert_mail.py {%s} [--dry-run]' % '|'.join(sorted(KINDS)))
        return 1

    values = load_values(SECRETS)
    user = values.get('CY_SMTP_USER', '')
    password = values.get('CY_SMTP_PASS', '')
    # .cytech_registered is what the owner themselves registered and what
    # sensor.cytech_owner_email reads; CY_SMTP_RECIPIENT is the installer-seeded
    # recipient (the register script keeps it in step), used only as the test
    # button's fallback so a unit that never had a Register press can still be
    # tested.
    owner = first_line(REGISTERED) or values.get('CY_SMTP_RECIPIENT', '')
    unit = first_line(DEVICE_ID) or 'this system'

    if not user or not password:
        print('email not configured on this device (no CY_SMTP_USER/CY_SMTP_PASS '
              'in .cytech_secrets) -- %s alert not mailed' % kind)
        log_line('unit=%s kind=%s rc=2 not-configured' % (unit, kind))
        return 2

    path, subject_tpl, prefix = KINDS[kind]
    subject = subject_tpl % unit
    if kind == 'test':
        if not owner:
            print('no alert email address registered on this device -- leaving the '
                  'field blank cannot test the mail. Press Register with Cytech first.')
            log_line('unit=%s kind=test rc=2 no-address' % unit)
            return 2
        body = TEST_BODY
        copies = [('owner', owner)]
    else:
        body = prefix % unit + read_message(os.path.join(RESULT_DIR, path))
        # v41 rule, unchanged: support@cytech.biz always gets every alert, and
        # the owner's registered address is added when there is one.
        copies = [('support', SUPPORT)]
        if owner:
            copies.append(('owner', owner))

    sender = user
    results = []
    rc = 0
    for label, to in copies:
        err = send(user, password, sender, to, subject, body, dry)
        results.append('%s=%s' % (label, 'DRY' if dry else 'sent' if err is None else 'FAILED(%s)' % type(err).__name__))
        if err is not None:
            print('send failed (%s copy, %s): %s' % (label, to, err), file=sys.stderr)
            rc = 3
            # The support copy is the one that must not be lost -- a bad owner
            # address must never stop it, and a failed support copy means the
            # problem is the credential/connection, so don't spend the rest of
            # the 60s shell_command budget on the owner copy.
            break
    print('%s alert mail: %s' % (kind, ', '.join(results)))
    log_line('unit=%s kind=%s rc=%d %s' % (unit, kind, rc, ' '.join(results)))
    return rc


if __name__ == '__main__':
    sys.exit(main())
