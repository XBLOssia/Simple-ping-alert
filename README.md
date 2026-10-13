# Simple Ping Alert

A small Windows desktop tool that pings a host continuously and tells you when it drops (and when it comes back): an audible beep, a native Windows notification, and - if you want - an email to a list of recipients.

Built for sysadmins and techs who want to "bug me when this thing goes down" without setting up a monitoring platform. It's a single PowerShell script with a WinForms window - nothing to install.

## Features

- Enter a **host/IP** and (optionally) a **comma-separated list of email recipients**, press Start. Leave the recipients blank to get only the beep and the Windows notification on the local PC.
- **DOWN alert** after a configurable number of missed pings in a row (default 2, so one dropped packet doesn't page you): three beeps, a Windows toast, and an email.
- **RECOVERED alert** when the host answers again (2 replies in a row), including how long it was down. The tool keeps watching afterwards, so the next drop alerts again. Untick the box to stop after the first DOWN alert instead.
- **Mute** switch silences the beeps only; the toast and email still go out. It can be toggled while monitoring.
- **Send test alert** button fires a toast, a beep and an email so you can check everything before relying on it.
- Sends via a plain (unauthenticated, unencrypted) **internal SMTP relay**. The From address is the logged-in user's UPN from Active Directory, falling back to `username@<their DNS domain>`.
- Remembers each user's last-used settings in `%APPDATA%\PingAlert\settings.json`.
- Pings are asynchronous, so the window never freezes while a host is timing out.

## Requirements

- Windows 10 / 11 with Windows PowerShell 5.1 (built in). No modules or installs.
- For email: an SMTP relay reachable on your network that accepts mail from the machine running the tool without authentication.

## Quick start

1. Download `PingAlert-vX.Y.Z.zip` from the [latest release](../../releases/latest) (or clone the repo) and extract it. Keep all the files in the same folder. Windows marks files downloaded from the internet, so first right-click the zip, choose **Properties**, tick **Unblock** and press OK, then extract; otherwise SmartScreen may warn when you launch `PingAlert.cmd`.
2. Double-click **`PingAlert.cmd`**. (It launches the script in STA mode with the execution policy bypassed for that process only and hides the console window.)
3. Fill in the host to ping and the email recipients, then press **Start**. On first run also enter the SMTP server, unless your admin shipped a `PingAlert.defaults.json` that already contains it (see [Site defaults](#site-defaults-pingalertdefaultsjson)). Your entries are remembered for next time.

You can also run the script directly, optionally prefilling the form or starting immediately:

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File .\PingAlert.ps1 -Target 10.1.1.1 -To "a@example.com,b@example.com" -AutoStart
```

`PingAlert.cmd` passes extra arguments through, so the same switches work with it, which is handy for pre-made shortcuts.

## Site defaults (`PingAlert.defaults.json`)

So that people don't have to type the SMTP server every time, the script reads an optional **`PingAlert.defaults.json`** from the same folder as `PingAlert.ps1`. The file is read each time the tool starts, so it is the one place to put your organization's settings before you hand the tool out (see [Setting up for your site](#setting-up-for-your-site-admins) below). A filled-in example:

```json
{
  "SmtpServer": "smtp.example.com",
  "SmtpPort": 25,
  "FallbackDomain": "example.com",
  "FailCount": 2,
  "RecoverCount": 2,
  "PingTimeoutMs": 1000,
  "PingIntervalMs": 1000
}
```

| Key | Built-in default | Meaning |
|---|---|---|
| `SmtpServer` | *(blank)* | SMTP relay host pre-filled in the form |
| `SmtpPort` | `25` | SMTP port |
| `FallbackDomain` | *(blank)* | Domain for the From address (`username@domain`) if the Active Directory lookup fails. Blank uses the logged-on user's DNS domain |
| `FailCount` | `2` | Missed pings in a row before a DOWN alert |
| `RecoverCount` | `2` | Replies in a row before a RECOVERED alert |
| `PingTimeoutMs` | `1000` | Per-ping timeout |
| `PingIntervalMs` | `1000` | Gap between pings |

Every key is optional; blank or missing values use the built-in default. Precedence in the form is: **command-line switches > the user's saved settings > `PingAlert.defaults.json` > built-in defaults.** Because saved settings win, a user who has already run the tool keeps their own values; to reset them, delete `%APPDATA%\PingAlert\settings.json`.

Notes on the file:

- It must be valid JSON. If it can't be parsed the tool shows a warning and falls back to the built-in defaults.
- Extra keys (such as the `_readme` note in the shipped template) are ignored.
- It is plain text and travels with the tool, so don't put secrets in it (the tool doesn't need any).

## Setting up for your site (admins)

The copy of `PingAlert.defaults.json` in this repo is a blank template, so the repo itself stays generic. To give your techs a zip that already knows your SMTP relay:

1. **Make a site defaults file outside the repo.** Copy `PingAlert.defaults.json` to somewhere private (e.g. `C:\Work\mysite.defaults.json`) and fill in at least `SmtpServer`, plus `FallbackDomain` if you want a specific domain for the From address.
2. **Build the zip** with `Make-Package.ps1`, pointing it at that file. It validates the JSON and writes `dist\PingAlert.zip` (or wherever `-Output` says) containing the script, launcher, README, license, and your file as `PingAlert.defaults.json`:

   ```powershell
   .\Make-Package.ps1 -Defaults C:\Work\mysite.defaults.json
   .\Make-Package.ps1 -Defaults C:\Work\mysite.defaults.json -Output C:\Work\PingAlert-mysite.zip
   ```

   Run it with no `-Defaults` to package the blank template from the repo instead.
3. **Hand out the zip.** Techs extract it anywhere, keep the files together, and double-click `PingAlert.cmd`. The SMTP server is already filled in.

Alternatively, skip the script: edit `PingAlert.defaults.json` directly in an extracted copy of the tool and zip the folder yourself. Just don't commit site-specific values to a public repo.

**Changing defaults later.** Edit the defaults file in the tool's folder (or rebuild and redistribute the zip). Anyone who has already run the tool has their own values saved in `%APPDATA%\PingAlert\settings.json`, which take priority over the defaults file. They will only see the new defaults for a setting once that saved value is gone, so have them delete `settings.json` (or just that field) to pick up changed defaults.

## Notes

- **Toasts** are raised through the Windows notification API and attributed to "Windows PowerShell" (so no app registration or registry changes are needed). They're deliberately silent; the beeps are the sound source, which is what Mute controls. Focus Assist / Do Not Disturb can suppress toasts. If the toast API fails the tool falls back to a system-tray balloon.
- **Email** is sent with .NET `SmtpClient` with SSL off, so it is intended for an internal relay. It is not suitable for servers that require TLS or authentication.
- The alert sound uses `[Console]::Beep`, falling back to the Windows exclamation sound if that isn't available.
- Email is sent while the UI thread is busy, so the window may pause for a moment (up to the 10-second SMTP timeout) if the relay is slow.

## Files

| File | Purpose |
|---|---|
| `PingAlert.ps1` | The tool |
| `PingAlert.cmd` | Double-click launcher |
| `PingAlert.defaults.json` | Optional site defaults (SMTP server etc.) read at startup |
| `Make-Package.ps1` | Builds the distributable zip |

## License

[MIT](LICENSE)
