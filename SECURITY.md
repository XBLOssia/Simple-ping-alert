# Security Policy

## Supported versions

Only the [latest release](../../releases/latest) is supported. Please reproduce any issue against it before reporting.

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Use GitHub's private reporting instead:

1. Go to the repository's **Security** tab.
2. Choose **Report a vulnerability** ([direct link](../../security/advisories/new)).
3. Describe the issue and how to reproduce it.

You can expect an acknowledgement, and a fix or an explanation as time allows. This is a small, volunteer-maintained project.

## Things to be aware of

- Email is sent with .NET `SmtpClient` with SSL disabled and no authentication. It is meant for an internal SMTP relay. Don't use it to send sensitive content or across untrusted networks.
- `PingAlert.defaults.json` and the per-user `%APPDATA%\PingAlert\settings.json` are plain text. The tool doesn't need or store any credentials; don't add any.
- `PingAlert.cmd` runs the script with `-ExecutionPolicy Bypass` for that process only. Review the script before running it, as with any downloaded script.
