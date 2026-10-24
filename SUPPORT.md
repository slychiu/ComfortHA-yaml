# Cytech Comfort — Owner Support Guide

This guide is for owners of a Cytech Comfort system running on Home Assistant.
It explains what the on-screen messages mean, what you can safely do yourself,
how to get answers from an AI assistant (Claude, DeepSeek, ChatGPT and similar)
— including how to ask it to help you set up automations, your own dashboards
and more — and how to reach Cytech support.

**The two GitHub links below are public and safe to share.** Nothing secret is
ever kept in them — email passwords and other private data live only on your
own system.

*Last updated: 2026-10-17.*

---

## 1. Getting help — in this order

1. **Read the message.** Every warning on your system has a short explanation
   here in [section 4](#4-what-the-warnings-mean-and-what-to-do).
2. **Ask an AI assistant.** Paste the ready-made prompt from
   [section 6](#6-getting-help-from-an-ai-assistant) — it gives the assistant
   the public technical references it needs. No Cytech involvement required.
3. **Email support@cytech.biz.** For anything unresolved, destructive, or if
   the assistant tells you to contact your supplier.

Most problems also email Cytech automatically — see
[section 7](#7-how-cytech-hears-about-problems). To **build or change
something** (a new dashboard, an automation), see
[section 9](#9-doing-more-with-your-system).

---

## 2. Your system's pages

| Page | What is there |
|---|---|
| **Config Files** | Your system version, the update buttons, Remote Support Access, System Health, and Alert settings |
| **Remote Access** (Welcome) | Your permanent remote access link and QR code for phones. *Do not share this link outside your household.* |
| **Alarm** | Comfort alarm status and area/zone controls |
| **Battery Levels** | Battery levels reported by the Comfort system |

On the **Config Files** page:

- **System Version** — the configuration version number. Support may ask for it.
- **Check for Update** / **Update Now** / **Skip this version** — see section 3.
- **Remote Support Access** — turns on a 10-hour window in which Cytech support
  can connect remotely for troubleshooting. It switches itself off
  automatically after 10 hours.
- **System Health** — SD Card rows (**Card Errors**, **Write Test**,
  **Warnings**, **Config Check**), a **Network** line and **Check Network Port**
  button.
- **Alerts** — **My Email for Alerts** (type your email here), **Register with
  Cytech** (press it after typing your email), **Send Test Email**.
- **Automatic Test Result** — appears when the system has run a self-check.

---

## 3. Two kinds of updates — do not mix them up

| | Where | What it is |
|---|---|---|
| **Home Assistant update** | Settings → System → Updates | The operating system / core software of Home Assistant. A large update. |
| **Cytech configuration update** | **Check for Update** button on the Config Files page | Small update of your Cytech system's configuration files. Safe and recommended whenever offered; press **Update Now** to install it. |

- **Check for Update is always safe to press**, even when other warnings are showing.
- **If a storage-card problem has been detected, do NOT install a pending
  Home Assistant update.** The system will warn you on screen if this applies
  (see below). Follow the advice in the warning instead.

---

## 4. What the warnings mean and what to do

### SD card warnings (the most important ones)

Your system's storage card holds the whole system. The system checks it every
hour and runs a small write test once a day.

| What you see | What it means | What to do |
|---|---|---|
| Popup **"SD card problem detected"** — or Card Errors shows **FAIL** | The system found error messages from the storage card in its logs. The card may be wearing out. | **Make a backup NOW**: Settings → System → Backups, save it to your PC or Google Drive. Then contact support@cytech.biz. Do **not** install a pending Home Assistant update. |
| Popup **"SD card write test failed"** — or Write Test shows **FAIL** | The daily read/write test on the card did not complete correctly. The card may be failing. | Same as above: **back up now**, contact support, no Home Assistant update. |
| Popup **"Repeated restarts detected"** — or Warnings shows **REPEATED_RESTARTS** | The system restarted several times in 24 hours. If *you* did not restart it, the card may be failing. | If you did restart it yourself, you can press **Dismiss Warning** to clear the notice. If not, treat it like the card warnings above: back up, contact support. |

In every card warning, following the on-screen advice is the safe path. A card
that fails completely takes the system's only copy with it — that is why the
backup step matters.

### The update warning

**"Do not install the Home Assistant update yet — storage card problem
detected."** This appears only when a Home Assistant update is offered at the
same time as a card problem. Installing a Home Assistant update writes a large
amount of data and could make a failing card worse.

- Do not install the Home Assistant update. Contact support@cytech.biz.
- Your Comfort system and its **Check for Update** keep working normally — this
  warning is only about the update under Settings → System → Updates.
- Cytech has been emailed about this automatically.

### Other messages

| What you see | What it means | What to do |
|---|---|---|
| Popup **"Cytech: data integrity issue detected"** — or Config Check is not OK | A configuration file was found damaged or changed unexpectedly. The system usually repairs this **by itself** automatically. | If the message repeats or the system behaves oddly, contact support. Otherwise no action needed. |
| **Network** line shows a warning (⚠️) | The network port check or the internet reachability check failed. | Press **Check Network Port**. If it warns again, check the network cable/router and contact support. |
| Comfort controls stop updating; the add-on log shows **"MQTT_DEVICE_COMFORT not ready"** | The bridge cannot reach the Comfort panel over its serial connection. | Check the Comfort panel's power and the cable between panel and this device. If it persists, contact support. |
| Remote Access page says **"Generating Secure Remote Link… Please wait"** | Setup is still finishing (usually a few minutes). | Wait a few minutes and refresh the page. If it still says this after a full restart, contact support. |
| Supervisor banner **"Unsupported system — DNS server issues"** | A single check against your DNS server failed. It usually clears itself on the next check. | Wait a few hours. If it persists, contact support. |
| Repair popup **"Insecure secrets detected in app configuration"** naming the app *Cytech Comfort* | Home Assistant's new leaked-password check found that a password/code stored in the Comfort app's own settings (for example the local MQTT password) appears in a public list of leaked passwords. Nothing is broken, and nothing has left your system — only a scrambled fingerprint of each code is compared, never the code itself. | It is safe to press **Ignore** on these repairs. Do not change any passwords or codes yourself. This warning does not mean your system is compromised. Cytech is aware of it and can tidy up the underlying codes during a future support session. |

---

## 5. Safe things you can do yourself

- **Check for Update** — always safe. **Update Now** when it offers a
  configuration update. **Skip this version** to decline an offered
  configuration update.
- **Restart Home Assistant** — Settings → System → Restart. Your data is kept.
- **Backups** — Settings → System → Backups. Do this especially when any card
  warning is showing — the backup is your only copy if the card fails.
- **Register with Cytech** — type your email in **My Email for Alerts** and
  press the button. Then **Send Test Email** to confirm it works. Alerts then
  reach you *and* Cytech.
- **Remote Support Access** — turn on during a support session; it turns itself
  off after 10 hours.
- **Dismiss Warning** — only to clear a notice that was expected (for example,
  restarts you did yourself).

Please do **not**: edit the configuration files by hand, delete files in
`.storage`, install a Home Assistant update while a card warning is showing, or
make a backup and then keep using the card for months without telling anyone —
the warnings exist to be acted on.

---

## 6. Getting help from an AI assistant

AI assistants (Claude, DeepSeek, ChatGPT and similar) can read the public
Cytech repositories and explain your system's messages. This works today with
no setup:

1. Open the assistant (app or website). A version that can browse web links
   works best.
2. Paste this prompt, filling in your details:

> I own a Cytech Comfort smart-home system running on Home Assistant.
>
> Public technical references (safe to share):
> - Cytech configuration files: https://github.com/slychiu/ComfortHA-yaml
> - Comfort bridge app: https://github.com/cytechtech/ucmpi4
> - Owner support guide (this page): https://raw.githubusercontent.com/slychiu/ComfortHA-yaml/main/SUPPORT.md
>
> My system version is: *(from the System Version card on the Config Files page)*
>
> What my system shows: *(paste the exact message, or describe what is not working)*
>
> Question: what does this mean, and what can I safely do myself?

3. If the assistant cannot open web links, paste or attach this whole guide —
   open the raw link above and copy everything.

**Never share with an AI assistant (or anyone outside your household):**

- your remote access link or its QR code,
- the Home Assistant login, username or password,
- any file whose name contains `cytech_secrets`, or any password from it,
- backup archives.

An AI assistant can explain and suggest, but it **cannot see or change your
system** — only press what is listed in section 5. If its advice conflicts
with this guide, follow this guide and email support@cytech.biz.

---

## 7. How Cytech hears about problems

When the system detects a card problem, repeated restarts, or a configuration
integrity issue, it emails **support@cytech.biz** automatically and sends a
second copy to your registered address. So when you receive one of those alert
emails, support already knows — you can simply reply to it, or write to
**support@cytech.biz**.

---

## 8. Note for AI assistants helping the owner of this system

This repository is the public configuration for Cytech Comfort systems
deployed on Home Assistant (bridge app: https://github.com/cytechtech/ucmpi4).
Grounding facts for owner questions:

- Owner-visible diagnostics: `sensor.cytech_sd_card_status` and
  `sensor.cytech_sd_canary` report **OK/FAIL** (storage-card kernel-log errors
  and a daily write/readback test); `sensor.cytech_warning` reports **OK** or
  **REPEATED_RESTARTS**; `sensor.cytech_integrity_status` /
  `sensor.cytech_integrity_alert` are the configuration self-check, which
  self-heals automatically.
- A Repair titled **"Insecure secrets detected in app configuration"** naming
  the app **"Cytech Comfort"** is Home Assistant's Have I Been Pwned check on
  the bridge app's stored password-type options (the local MQTT password and
  the Comfort login code). It is advisory only: nothing is broken, the check
  uses k-anonymity (no secret leaves the unit), and pressing **Ignore** is the
  documented resolution for the owner. It does not indicate a compromise and
  does not affect Comfort operation.
- The **"Do not install the Home Assistant update yet"** alert means a
  storage-card problem was detected while a Home Assistant OS/Core update is
  offered. Home Assistant updates write heavily and can worsen a failing card;
  the correct advice is: back up (Settings → System → Backups), contact
  support@cytech.biz, and do not install the Home Assistant update. Cytech's
  own configuration update (**Check for Update**) is a different mechanism and
  remains safe to use.
- On any storage-card warning, the backup advice is the priority: the card
  holds the system's only copy.
- Alerts email support@cytech.biz automatically and copy the owner when
  registered. For anything destructive or unresolved, direct the owner to
  support@cytech.biz.

---

## 9. Doing more with your system

Cytech's own pages focus on the alarm. Everything else Home Assistant can do —
automations, your own dashboards, phone notifications and more — is available
on the same device, and you do not need to learn it in advance.

**The easiest way is to ask an AI assistant.** Claude, DeepSeek, ChatGPT and
similar can walk you through almost anything, step by step. Open the
assistant, paste this prompt, and fill in what you want to do:

> I own a Cytech Comfort smart-home system running on Home Assistant.
>
> I want to: *(describe what you want — for example "make my own dashboard
> with the alarm status and my zone sensors", "send a phone notification when
> the front door opens while the alarm is armed", or "show the Comfort battery
> voltage on a page")*
>
> Facts about my system:
> - The alarm is `alarm_control_panel.comfort_alarm` (states: disarmed,
>   armed_home, armed_away, armed_night). The Alarm page's arm buttons call
>   `script.comfort_arm_away`, `script.comfort_arm_night` and
>   `script.comfort_arm_home`.
> - Each Comfort zone is a binary sensor named like
>   `binary_sensor.cytech_comfort_mqtt_input005` (on = open, off = closed).
>   Bypass controls are `button.<zone name>_set_bypass` /
>   `button.<zone name>_clear_bypass`, with the state in
>   `sensor.<zone name>_bypass_status`.
> - Battery readings: `sensor.cytech_comfort_mqtt_battery_status`,
>   `sensor.cytech_comfort_mqtt_charger_status`,
>   `sensor.cytech_comfort_mqtt_battery_main_voltage` and
>   `sensor.cytech_comfort_mqtt_dc_supply_main_voltage`. Alarm/trouble status:
>   `sensor.comfort_am_status`.
> - Public references (safe to share):
>   https://github.com/slychiu/ComfortHA-yaml and
>   https://github.com/cytechtech/ucmpi4
>
> Give me step-by-step instructions using the current Home Assistant menus,
> and tell me which screen to start from. If anything I do could affect the
> alarm or lose my settings, warn me first.

Then work through the assistant's answer in the Home Assistant app or a
browser. If its steps do not match your screens, tell it your Home Assistant
version (Settings → About) and ask it to adjust.

**Rules that still apply:**

- The four Cytech pages (Remote Access, Alarm, Battery Levels, Config Files)
  are replaced by Cytech updates. Ask the assistant to help you create a
  **new** dashboard for your own ideas — do not edit the Cytech pages.
- Do not edit configuration files or `.storage` by hand, and do not change or
  delete the automations Cytech installed (they run the self-checks, updates
  and alert emails).
- Never give an AI assistant your remote access link, Home Assistant login,
  secret files or alarm PIN — see section 6. The assistant cannot see or
  change your system; it only gives you instructions to carry out.
- An automation can control the alarm. Be careful with anything that disarms
  it, and never put your PIN on a dashboard or in a notification.
- For the Comfort panel itself (zones, users, codes, programming), contact
  Cytech support — the panel is programmed in Comfigurator, not in Home
  Assistant.
