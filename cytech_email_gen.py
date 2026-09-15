#!/usr/bin/env python3
# v48a: DELETES the generated packages/cytech_email.yaml. The file's name is
# historical -- it no longer generates anything. Through v47 this script wrote
# the two notify: - platform: smtp platforms (cytech_alert_support and
# cytech_alert_email) that all four alert automations mailed through; HA is
# retiring that integration (the legacy notify services stop working in HA
# 2027.3, and HA 2026.8+ raises homeassistant/deprecated_yaml_smtp against the
# package itself), and as of v48a the fleet sends its own mail with
# cytech_alert_mail.py instead -- so the only thing left to do on an existing
# device is remove the leftover package, which is what retires the two notify
# services on the next HA start.
#
# Contract, unchanged: prints exactly one status line, and both callers
# (ensure_email_secrets() in first_boot.sh, cytech_register_email.sh) grep for
# "written"/"removed" to decide whether HA must restart. Only the removal line
# matches, and removing the package is exactly when a restart is needed.
import os

PKG = '/config/packages/cytech_email.yaml'
CFG = '/config/.cytech_secrets'

if os.path.exists(PKG):
    os.remove(PKG)
    print("removed legacy packages/cytech_email.yaml -- smtp notify platforms retired")
else:
    print("no legacy email package on this device -- nothing to remove")

# Reported because both callers echo this into their logs and it is the
# quickest way to see on a boot whether alert mail can be sent at all. Read
# only -- never a value.
HAVE_PASS = False
if os.path.exists(CFG):
    with open(CFG) as f:
        for line in f:
            if line.strip().startswith('CY_SMTP_PASS=') and line.split('=', 1)[1].strip():
                HAVE_PASS = True
if HAVE_PASS:
    print("alert mail: sent by cytech_alert_mail.py (SMTP credential present)")
else:
    print("alert mail: no CY_SMTP_PASS in .cytech_secrets -- alerts are on-screen only")
