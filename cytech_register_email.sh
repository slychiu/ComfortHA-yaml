#!/bin/bash
# v40: owner alert-email registration, final owner-facing flow. The OWNER
# supplies only their own address (the "My Email" field -- renamed from
# "Cytech Alert Email": the address is the owner's, not Cytech's, and the old
# name read as if it were Cytech's address). Pressing Register:
#   empty field   -> status "Enter your email first, then press Register."
#                    NOTHING is sent -- no blank notices in support@cytech.biz
#   valid address -> ONE mail To: the owner, Cc: support@cytech.biz: the owner
#                    sees a confirmation in their own inbox and Cytech still
#                    gets the registration notice (unit + owner address) for
#                    the unit<->owner registry. A wrong address fails at send
#                    time with an explicit status, and nothing is stored.
#   no SMTP creds -> "ask your installer" (the owner can never make the
#                    system send mail; only installer-seeded credentials can).
# Every outcome ALSO writes /config/.cytech_register_popup, which the v40
# automation turns into a screen popup -- Register always has a visible
# return status, not just the small inline line. CY_SMTP_RECIPIENT is stored
# in /config/.cytech_secrets (never in this repo; USER/PASS are
# installer-seeded). Runs in HA Core's container via shell_command with the
# email as $1.
#
# Usage: bash /config/cytech_register_email.sh '<email>'
#        bash /config/cytech_register_email.sh '<email>' --dry-run
#
# --dry-run validates and prints the plan but writes/sends nothing (used for
# pre-deployment testing). This script never prints a credential value.
EMAIL="$1"
DRY="$2"

# The actual work is a single python run so the secrets file is edited
# atomically and the mail goes out with a properly-framed message. Bash then
# runs the email package generator (and core restart, if the recipient
# actually changed) AFTER the mail + state are persisted -- never after a
# restart, which would kill this script mid-flight.
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
RESULT = '/config/.cytech_register_result'
POPUP = '/config/.cytech_register_popup'

def write_files(status, message):
    # both files share the shape {ts, status, message}: the popup file backs
    # the screen popup automation, the result file backs the inline line.
    data = '{"ts": %d, "status": "%s", "message": "%s"}' % (
        int(time.time()), status, message.replace('\\', '\\\\').replace('"', '\\"'))
    for path in (RESULT, POPUP):
        with open(path, 'w') as f:
            f.write(data)
        os.chmod(path, 0o600)

def outcome(status, message):
    # shares the caller's stdout: bash decides what to do from the exit code.
    # DRY always exits 4 (no state change, nothing to generate downstream).
    if not DRY:
        write_files(status, message)
    print('%s: %s' % (status, message))
    sys.exit(4 if DRY else (0 if status == 'OK' else 2))

if not EMAIL:
    outcome('ERROR', 'Enter your email first, then press Register.')

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
        'email a confirmation to %s (Cytech on copy) and store it' % EMAIL
        if existing != EMAIL else 'report already-registered'))
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

# 2. ONE mail: To the owner, Cc support@cytech.biz -- the owner gets their
# confirmation (the button visibly does something for them; a wrong address
# fails HERE, so no silent typos) and Cytech still gets the registration
# notice (unit + owner address) for the unit<->owner registry.
msg = EmailMessage()
msg['From'] = 'ucmapi@cytech.biz'
msg['To'] = EMAIL
msg['Cc'] = 'support@cytech.biz'
msg['Subject'] = 'Cytech alert email confirmation: %s' % (UNIT or 'unknown-unit')
msg.set_content(
    'This is an automated confirmation from a Cytech system.\n'
    'System:      %s\n\n'
    'Alert emails from this system (e.g. SD card trouble, restart loops) '
    'will be sent to:\n'
    '%s\n\n'
    'If you are not the owner of this system, no action is needed -- you can '
    'ignore this message.' % (UNIT or 'unknown-unit', EMAIL))

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
    outcome('ERROR', 'Could not send the confirmation to %s (%s) -- check the '
                     'spelling and press Register again'
                     % (EMAIL, type(send_err).__name__))

# 3. persist the registered state ONLY after the mail is out
with open(REG, 'w') as f:
    f.write(EMAIL)
os.chmod(REG, 0o600)

print('MAIL-SENT recipient=%s secrets_changed=%s' % (EMAIL, SECRETS_CHANGED))
outcome('OK', 'Registered with Cytech -- alert emails go to %s' % EMAIL)
PYEOF
)
RC=$?
echo "$OUT" >> /config/cytech_update.log

[ "$RC" = "4" ] && exit 0               # dry run: nothing to do
if [ "$RC" != "0" ]; then
  echo "register_email: failed (rc=$RC)" >> /config/cytech_update.log
  exit "$RC"
fi

# ALWAYS run the email package generator now -- it byte-compares, so an
# unchanged package prints "no change" and never restarts. Gating it on
# "recipient changed" was wrong: after the installer seeds the credentials
# (incl. a recipient), a first-time owner press may change NOTHING in the
# secrets file while the package still has never been generated on this
# device -- email would silently not work until the next boot. The restart
# (if any) happens LAST, after the mail and the registered state are on disk.
RESULT=$(python3 /config/cytech_email_gen.py 2>&1)
echo "$RESULT" >> /config/cytech_update.log
if echo "$RESULT" | grep -qE "written|removed"; then
  echo "Email package changed -- restarting HA to load it." >> /config/cytech_update.log
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/restart >/dev/null || true
fi
