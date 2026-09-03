#!/bin/bash
# v37: owner alert-email registration. Stores the owner's email on the device
# (CY_SMTP_RECIPIENT in /config/.cytech_secrets -- USER/PASS are seeded by the
# installer; the OWNER supplies only their own address), regenerates the smtp
# notify package, and sends a registration notice to support@cytech.biz so
# Cytech learns which unit belongs to which alert address and can contact the
# owner when an alert fires. Runs in HA Core's container via shell_command
# with the email as $1.
#
# Usage: bash /config/cytech_register_email.sh '<email>'
#        bash /config/cytech_register_email.sh '<email>' --dry-run
#
# --dry-run validates and prints the plan but writes/sends nothing (used for
# pre-deployment testing). This script never prints a credential value.
EMAIL="$1"
DRY="$2"

# The actual work is a single python run so the secrets file is edited
# atomically and the registration mail goes out with a properly-framed
# message. Bash then runs the email package generator (and core restart, if
# the recipient actually changed) AFTER the mail + state are persisted --
# never after a restart, which would kill this script mid-flight.
OUT=$(python3 - "$EMAIL" "$DRY" << 'PYEOF' 2>&1
import os
import re
import sys
import smtplib
import time
from email.message import EmailMessage

EMAIL = sys.argv[1].strip()
DRY = sys.argv[2] == '--dry-run'
CFG = '/config/.cytech_secrets'
REG = '/config/.cytech_registered'

def outcome(status, message, result_file=True):
    # shares the caller's stdout: bash decides what to do from the exit code
    if result_file and not DRY:
        with open('/config/.cytech_register_result', 'w') as f:
            f.write('{"ts": %d, "status": "%s", "message": "%s"}' % (
                int(time.time()), status, message.replace('\\', '\\\\').replace('"', '\\"')))
    print('%s: %s' % (status, message))
    sys.exit(0 if status == 'OK' or DRY else 2)

if not re.fullmatch(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}", EMAIL):
    outcome('ERROR', 'Email address rejected -- check the spelling, e.g. name@example.com')

UNIT = ''
if os.path.exists('/config/device_id.txt'):
    with open('/config/device_id.txt') as f:
        UNIT = f.read().strip()

VALUES = {}
if os.path.exists(CFG):
    with open(CFG) as f:
        for line in f:
            line = line.strip()
            if line and '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1)
                VALUES[k.strip()] = v.strip()

if not VALUES.get('CY_SMTP_PASS') or not VALUES.get('CY_SMTP_USER'):
    outcome('ERROR', 'Alert email is not configured for this system yet -- '
                     'ask your installer to finish the email setup first, '
                     'then register again')

existing = ''
if os.path.exists(REG):
    with open(REG) as f:
        existing = f.read().strip()

if DRY:
    print('DRY-RUN: unit=%s creds=OK registered=%r would %s' % (
        UNIT, existing,
        're-send registration and update recipient to %s' % EMAIL if existing != EMAIL else 'report already-registered'))
    sys.exit(4)

if existing == EMAIL:
    outcome('OK', 'Already registered -- alert emails go to %s' % EMAIL)

# 1. update CY_SMTP_RECIPIENT in the secrets file, atomically, only if changed
new_lines = []
found = False
want = 'CY_SMTP_RECIPIENT=%s' % EMAIL
if os.path.exists(CFG):
    with open(CFG) as f:
        for line in f.read().splitlines():
            if line.strip().startswith('CY_SMTP_RECIPIENT='):
                new_lines.append(want)
                found = True
            else:
                new_lines.append(line)
    if not found:
        new_lines.append(want)
    text = '\n'.join(new_lines) + '\n'
    with open(CFG) as f:
        old = f.read()
    if old != text:
        fd = '%s.tmp' % CFG
        with open(fd, 'w') as f:
            f.write(text)
        os.chmod(fd, 0o600)
        os.replace(fd, CFG)
        SECRETS_CHANGED = True
    else:
        SECRETS_CHANGED = False
else:
    with open(CFG, 'w') as f:
        f.write(want + '\n')
    os.chmod(CFG, 0o600)
    SECRETS_CHANGED = True

# 2. registration notice to Cytech (support@cytech.biz) so the unit<->owner
# mapping exists before any alert ever fires. Real mail only -- this is what
# "they must enter their own email, which is sent to our email" means.
msg = EmailMessage()
msg['From'] = 'ucmapi@cytech.biz'
msg['To'] = 'support@cytech.biz'
msg['Subject'] = 'Cytech system email registration: %s' % (UNIT or 'unknown-unit')
msg.set_content(
    'This is an automated registration notice from a Cytech system.\n'
    'Unit:      %s\n'
    'Alert email set by the owner: %s\n\n'
    'Any SD-card trouble / restart-loop alerts from this system use the email '
    'address above as the recipient, and this address is how Cytech can reach '
    'the owner about this unit.' % (UNIT or 'unknown-unit', EMAIL))

send_err = None
for attempt in (1, 2):
    try:
        with smtplib.SMTP_SSL('mail.server282.com', 465, timeout=20) as smtp:
            smtp.login(VALUES['CY_SMTP_USER'], VALUES['CY_SMTP_PASS'])
            smtp.send_message(msg)
        send_err = None
        break
    except Exception as e:
        send_err = e
        time.sleep(3)

if send_err is not None:
    outcome('ERROR', 'Could not send the registration notice to Cytech '
                     '(%s) -- press Register again to retry' % type(send_err).__name__)

# 3. persist the registered state ONLY after the mail is out
with open(REG, 'w') as f:
    f.write(EMAIL)
os.chmod(REG, 0o600)

# 4. success result for the dashboard, then tell bash whether the
# device-local smtp package must be regenerated (bash restarts last, after
# everything above is already on disk and mailed).
with open('/config/.cytech_register_result', 'w') as f:
    f.write('{"ts": %d, "status": "OK", "message": "Registered with Cytech -- '
            'alert emails will go to %s"}' % (int(time.time()), EMAIL))
os.chmod('/config/.cytech_register_result', 0o600)
print('MAIL-SENT recipient=%s secrets_changed=%s' % (EMAIL, SECRETS_CHANGED))
sys.exit(0)
PYEOF
)
RC=$?
echo "$OUT" >> /config/cytech_update.log

[ "$RC" = "4" ] && exit 0               # dry run: nothing to do
if [ "$RC" != "0" ]; then
  echo "register_email: failed (rc=$RC)" >> /config/cytech_update.log
  exit "$RC"
fi

# Regenerate the email package only when the recipient actually changed; an
# unchanged recipient means the live package already matches. The restart
# (if any) happens LAST, after the mail and the registered state are on disk.
if echo "$OUT" | grep -q "secrets_changed=True"; then
  RESULT=$(python3 /config/cytech_email_gen.py 2>&1)
  echo "$RESULT" >> /config/cytech_update.log
  if echo "$RESULT" | grep -qE "written|removed"; then
    echo "Email package changed -- restarting HA to load it." >> /config/cytech_update.log
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/restart >/dev/null || true
  fi
fi
