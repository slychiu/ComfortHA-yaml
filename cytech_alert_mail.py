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
#   kinds: integrity | sdcard | canary | boot | test | updatehold
#
# v52a: new kind 'updatehold' -- the SD-trouble/update-offer gate in
# packages/cytech.yaml. Unlike the other kinds it has no result file of its
# own: gate_message() composes the body from whichever card-check files are
# currently reporting trouble, in priority order, so the letter always matches
# what the dashboards are showing at send time.
#
# v52d: every card-trouble letter (sdcard, canary, boot, updatehold) closes
# with BACKUP_ADVICE -- keep a copy while the card still works. The same
# sentence is appended to the matching popups in packages/cytech.yaml; the
# two live in step, and a card that dies otherwise takes the only copy of
# the system with it (2026-10-15 customer case).
#
# It is called from packages/cytech.yaml by six FIXED shell_commands, one per
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
    # v52a: body comes from gate_message() -- there is no single result file
    # behind the gate. Support-always / owner-when-known copies, same as the
    # other alert kinds.
    'updatehold': (None,
                   'Cytech: do not install the pending Home Assistant update: %s',
                   '%s: '),
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


# v52d: the closing line of every card-trouble letter. Byte-identical to the
# sentence appended to the popups in packages/cytech.yaml -- change both
# together.
BACKUP_ADVICE = ('Please make a backup of your system to your PC or Google '
                 'Drive while it is still working -- Settings > System > '
                 'Backups.')

# v52a: the update gate's advice line. The per-check detail is appended from
# the same result files the notification popup reads, in the same priority
# order (SD status, canary, boot storm, integrity). The wording names the
# Home Assistant update explicitly (pre-release fold into 52, 2026-10-16):
# "the update" alone could be read as the Comfort Check for Update.
GATE_ADVICE = ('Home Assistant is offering a software update (Home Assistant '
               'OS or Core) and Cytech has been notified, but the storage card '
               'health checks on this system are reporting a problem. Please '
               'do NOT install the Home Assistant update until Cytech support '
               'has looked at this -- the update writes a large amount of data '
               'and could make a failing card worse. This warning is only '
               'about the Home Assistant update offered under Settings > '
               'System > Updates; your Comfort system and its Check for Update '
               'keep working normally. Please make a backup of your system to '
               'your PC or Google Drive while it is still working -- Settings '
               '> System > Backups.')


def gate_message():
    """Compose the update-gate body: the advice line, plus the most specific
    trouble detail currently on disk. Like read_message, this never re-decides
    whether the gate should have fired (the automation already confirmed
    that) -- a missing/garbled file just falls through to the generic
    advice."""
    for name, bad in (('.cytech_sdcard_result', ('FAIL',)),
                      ('.cytech_canary_result', ('FAIL',)),
                      ('.cytech_boot_result', ('REPEATED_RESTARTS',)),
                      ('.cytech_integrity_alert', None)):
        try:
            with open(os.path.join(RESULT_DIR, name)) as f:
                data = json.load(f)
        except Exception:
            continue
        if bad is not None and data.get('status') not in bad:
            continue
        detail = (data.get('message') or '').strip()
        if detail:
            return GATE_ADVICE + ' What the checks report: ' + detail
    return GATE_ADVICE


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
    # sensor.cytech_owner_email reads; CY_SMTP_RECIPIENT is the recorded
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
    elif kind == 'updatehold':
        # v52a: composed from the card-check files; this is an alert, so the
        # v41 rule applies -- support always, owner's registered copy when
        # one is known.
        body = prefix % unit + gate_message()
        copies = [('support', SUPPORT)]
        if owner:
            copies.append(('owner', owner))
    else:
        body = prefix % unit + read_message(os.path.join(RESULT_DIR, path))
        # v52d: the card-trouble kinds close with the backup advice. The
        # integrity alert is a data/config alert, not a card alert -- it does
        # not carry it.
        if kind in ('sdcard', 'canary', 'boot'):
            body += ' ' + BACKUP_ADVICE
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
