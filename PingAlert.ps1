<#
.SYNOPSIS
    Ping Alert - watches a host with a continuous ping and, when it stops
    answering, beeps, pops a Windows notification and emails a list of recipients.
    It keeps watching and sends a second alert when the host comes back up.

.DESCRIPTION
    Small desktop tool. Enter what to ping and who to email (comma-separated,
    optional), press Start. When the host misses the configured number of pings in a row
    it raises a DOWN alert (beeps, Windows toast, email). With "Also alert when
    the host comes back up" ticked it keeps monitoring and raises a RECOVERED
    alert once the host answers again; otherwise it stops after the DOWN alert.
    "Mute sounds" silences the beeps only - toast and email still go out.

    Normally launched through PingAlert.cmd (double-click). Optional switches
    let you prefill the form or start immediately:
        .\PingAlert.ps1 -Target 10.1.1.1 -To "a@example.com,b@example.com" -AutoStart

    Site defaults (SMTP server, port, etc.) can be supplied in
    PingAlert.defaults.json alongside this script - see README.md.
#>
param(
    [string]$Target,
    [string]$To,
    [switch]$AutoStart
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Version = "1.0.0"

# ==============================================================================
# CONFIGURATION
# Site defaults come from PingAlert.defaults.json next to this script (optional).
# Any key missing from that file falls back to the built-in value below.
# Precedence in the form: command line > user's saved settings > defaults file > built-in.
# ==============================================================================
$Defaults = @{
    SmtpServer     = ""      # SMTP relay host (plain, unauthenticated, no TLS)
    SmtpPort       = 25
    FallbackDomain = ""      # builds the From address if the AD lookup fails (blank = DNS domain of the logged-on user)
    FailCount      = 2       # consecutive missed pings before a DOWN alert
    RecoverCount   = 2       # consecutive replies before a RECOVERED alert
    PingTimeoutMs  = 1000
    PingIntervalMs = 1000    # gap between pings
}
$DefaultsFile = Join-Path $PSScriptRoot "PingAlert.defaults.json"
if (Test-Path $DefaultsFile) {
    try {
        $fromFile = Get-Content $DefaultsFile -Raw | ConvertFrom-Json
        foreach ($key in @($Defaults.Keys)) {
            $v = $fromFile.$key
            if ($null -ne $v -and "$v".Trim() -ne "") { $Defaults[$key] = $v }
        }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Could not read PingAlert.defaults.json - using built-in defaults.`n`n$($_.Exception.Message)", "Ping Alert")
    }
}
$DefaultSmtpServer = [string]$Defaults.SmtpServer
$DefaultSmtpPort   = [int]$Defaults.SmtpPort
$FallbackDomain    = [string]$Defaults.FallbackDomain
$DefaultFailCount  = [int]$Defaults.FailCount
$RecoverCount      = [int]$Defaults.RecoverCount
$PingTimeoutMs     = [int]$Defaults.PingTimeoutMs
$PingIntervalMs    = [int]$Defaults.PingIntervalMs
$SettingsFile      = Join-Path $env:APPDATA "PingAlert\settings.json"
# Toasts are attributed to PowerShell (an app ID Windows already knows about)
$ToastAppId        = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

# ==============================================================================
# HELPERS
# ==============================================================================
function Get-SenderAddress {
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $upn = ([ADSI]"LDAP://<SID=$sid>").UserPrincipalName
        if ($upn) { return [string]$upn }
    } catch { }
    $domain = if ($FallbackDomain) { $FallbackDomain } else { $env:USERDNSDOMAIN }
    if ($domain) { return "$($env:USERNAME)@$($domain.ToLower())" }
    return ""
}

function Get-MailSettingsProblem {
    # Returns a message if email can't be sent with the current form values, else $null.
    if (-not $txtSmtp.Text.Trim()) { return "Enter the SMTP server to send email through." }
    try { [void][System.Net.Mail.MailAddress]$txtFrom.Text.Trim() }
    catch { return "Enter a valid 'Send from' email address." }
    return $null
}

function Get-SavedSettings {
    try {
        if (Test-Path $SettingsFile) { return Get-Content $SettingsFile -Raw | ConvertFrom-Json }
    } catch { }
    return $null
}

function Save-Settings {
    try {
        $dir = Split-Path $SettingsFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [pscustomobject]@{
            Target = $txtTarget.Text; To = $txtTo.Text
            Smtp = $txtSmtp.Text; Port = [int]$numPort.Value
            From = $txtFrom.Text; Fails = [int]$numFails.Value
            Recover = $chkRecover.Checked; Mute = $chkMute.Checked
        } | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8
    } catch { }
}

function Get-Recipients {
    # Returns @{ Valid = @(...); Bad = @(...) }
    $valid = @(); $bad = @()
    foreach ($r in ($txtTo.Text -split '[,;\s]+' | Where-Object { $_ })) {
        try { $valid += ([System.Net.Mail.MailAddress]$r).Address } catch { $bad += $r }
    }
    @{ Valid = $valid; Bad = $bad }
}

function Write-Log([string]$text) {
    $line = "{0:HH:mm:ss}  {1}" -f (Get-Date), $text
    $txtLog.AppendText($line + [Environment]::NewLine)
}

function Format-Duration([timespan]$ts) {
    if ($ts.TotalHours -ge 1) { return "{0}h {1}m {2}s" -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds }
    if ($ts.TotalMinutes -ge 1) { return "{0}m {1}s" -f $ts.Minutes, $ts.Seconds }
    return "{0}s" -f [int][math]::Floor($ts.TotalSeconds)
}

function Send-Mail([string[]]$recipients, [string]$subject, [string]$body) {
    $msg = New-Object System.Net.Mail.MailMessage
    $smtp = $null
    try {
        $msg.From = New-Object System.Net.Mail.MailAddress($txtFrom.Text.Trim())
        foreach ($r in $recipients) { $msg.To.Add($r) }
        $msg.Subject = $subject
        $msg.Body = $body
        $smtp = New-Object System.Net.Mail.SmtpClient($txtSmtp.Text.Trim(), [int]$numPort.Value)
        $smtp.EnableSsl = $false
        $smtp.Timeout = 10000
        $smtp.Send($msg)
    } finally {
        $msg.Dispose()
        if ($smtp) { $smtp.Dispose() }
    }
}

function Show-Toast([string]$title, [string]$text) {
    # Native Windows toast (lands in the notification centre); falls back to a tray balloon.
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $t = [System.Security.SecurityElement]::Escape($title)
        $b = [System.Security.SecurityElement]::Escape($text)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        # audio is silent: the beeps (and the Mute switch) are the sound source
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual><audio silent='true'/></toast>")
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAppId).Show($toast)
    } catch {
        try {
            if (-not $State.Tray) {
                $State.Tray = New-Object System.Windows.Forms.NotifyIcon
                $State.Tray.Icon = [System.Drawing.SystemIcons]::Warning
                $State.Tray.Visible = $true
            }
            $State.Tray.ShowBalloonTip(10000, $title, $text, [System.Windows.Forms.ToolTipIcon]::Warning)
        } catch {
            Write-Log "Windows notification failed: $($_.Exception.Message)"
        }
    }
}

function Play-Tones([int[]]$freqs, [int]$ms) {
    if ($chkMute.Checked) { return }
    foreach ($f in $freqs) {
        try { [Console]::Beep($f, $ms) }
        catch { [System.Media.SystemSounds]::Exclamation.Play() }
        Start-Sleep -Milliseconds 200
    }
}

function Publish-Event([string]$title, [string]$message, [string]$subject, [string]$body, [int[]]$tones, [int]$toneMs) {
    # Windows toast first (instant), then sound, then email.
    Show-Toast $title $message
    Play-Tones $tones $toneMs
    $rcpt = (Get-Recipients).Valid
    if ($rcpt.Count -eq 0) { return }
    try {
        Write-Log "Sending email via $($txtSmtp.Text.Trim()):$([int]$numPort.Value) ..."
        Send-Mail $rcpt $subject $body
        Write-Log "Email sent to $($rcpt -join ', ')."
    } catch {
        Write-Log "EMAIL FAILED: $($_.Exception.GetBaseException().Message)"
    }
}

function Set-Running([bool]$running) {
    $State.Running = $running
    $btnStart.Enabled = -not $running
    $btnStop.Enabled  = $running
    $btnTest.Enabled  = -not $running
    foreach ($c in $txtTarget, $txtTo, $txtSmtp, $numPort, $txtFrom, $numFails, $chkRecover) { $c.Enabled = -not $running }
    if (-not $running) { $timer.Stop() }
}

function Set-Status([string]$text, [System.Drawing.Color]$color) {
    $lblStatus.Text = $text
    $lblStatus.BackColor = $color
}

function Start-Monitoring {
    $target = $txtTarget.Text.Trim()
    if (-not $target) { [void][System.Windows.Forms.MessageBox]::Show("Enter a host or IP to ping.", "Ping Alert"); return }
    $rcpt = Get-Recipients
    if ($rcpt.Bad.Count -gt 0) { [void][System.Windows.Forms.MessageBox]::Show("These don't look like email addresses:`n`n" + ($rcpt.Bad -join "`n"), "Ping Alert"); return }
    if ($rcpt.Valid.Count -gt 0) {
        $problem = Get-MailSettingsProblem
        if ($problem) { [void][System.Windows.Forms.MessageBox]::Show($problem, "Ping Alert"); return }
    }

    Save-Settings
    $State.Target    = $target
    $State.Fails     = 0
    $State.Oks       = 0
    $State.Down      = $false
    $State.DownSince = $null
    $State.Task      = $null
    $State.LastStart = [datetime]::MinValue
    Set-Running $true
    Set-Status "Monitoring $target ..." ([System.Drawing.Color]::LightSkyBlue)
    $recoverNote = if ($chkRecover.Checked) { " and again when it comes back up" } else { "" }
    $who = if ($rcpt.Valid.Count -gt 0) { "Will email $($rcpt.Valid -join ', ')" } else { "No email recipients - notifying on this PC only" }
    Write-Log "Monitoring $target. $who after $([int]$numFails.Value) missed ping(s)$recoverNote."
    $timer.Start()
}

function Stop-Monitoring {
    Set-Running $false
    Set-Status "Stopped." ([System.Drawing.Color]::Gainsboro)
    Write-Log "Stopped."
}

function Invoke-Alert {
    $target = $State.Target
    $State.Down = $true
    $State.DownSince = Get-Date
    $State.Oks = 0
    Set-Status "$target is DOWN" ([System.Drawing.Color]::IndianRed)
    Write-Log "$target is DOWN - alerting."
    $form.Activate()

    $subject = "ALERT: Host $target is DOWN"
    $body = "Automated alert: the host $target stopped responding to ping at $($State.DownSince).`r`n`r`n" +
            "Reported by $($env:USERNAME) on $($env:COMPUTERNAME)."
    Publish-Event "$target is DOWN" "No ping reply since $($State.DownSince.ToString('HH:mm:ss'))." $subject $body @(800, 800, 800) 500

    if ($chkRecover.Checked) {
        Write-Log "Still watching - will alert when it comes back up."
        $State.LastStart = Get-Date
    } else {
        Set-Running $false
        Write-Log "Monitoring stopped. Press Start to watch again."
    }
}

function Invoke-Recovery {
    $target = $State.Target
    $when = Get-Date
    $dur = Format-Duration ($when - $State.DownSince)
    $downSince = $State.DownSince
    $State.Down = $false
    $State.DownSince = $null
    $State.Fails = 0
    $State.Oks = 0
    Set-Status "$target is back UP (was down $dur)" ([System.Drawing.Color]::LightGreen)
    Write-Log "$target is back UP after $dur - alerting."

    $subject = "RECOVERED: Host $target is back UP"
    $body = "Automated alert: the host $target is answering ping again as of $when.`r`n" +
            "It stopped responding at $downSince (down for $dur).`r`n`r`n" +
            "Reported by $($env:USERNAME) on $($env:COMPUTERNAME)."
    Publish-Event "$target is back UP" "Down for $dur." $subject $body @(600, 900) 300
    $State.LastStart = Get-Date
}

# ==============================================================================
# FORM
# ==============================================================================
$State = @{
    Running = $false; Target = ""; Fails = 0; Oks = 0; Down = $false; DownSince = $null
    Task = $null; LastStart = [datetime]::MinValue; Tray = $null
}
$pinger = New-Object System.Net.NetworkInformation.Ping
$saved  = Get-SavedSettings

function New-Label($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, ($y + 3)); $l.AutoSize = $true
    $l
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Ping Alert v$Version"
$form.ClientSize = New-Object System.Drawing.Size(540, 510)
$form.MinimumSize = New-Object System.Drawing.Size(460, 430)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$form.Controls.Add((New-Label "Host / IP to ping:" 15 15))
$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Location = New-Object System.Drawing.Point(150, 15); $txtTarget.Width = 370
$txtTarget.Anchor = "Top,Left,Right"
$form.Controls.Add($txtTarget)

$form.Controls.Add((New-Label "Email to (comma-sep.):" 15 50))
$txtTo = New-Object System.Windows.Forms.TextBox
$txtTo.Location = New-Object System.Drawing.Point(150, 50); $txtTo.Width = 370
$txtTo.Anchor = "Top,Left,Right"
$form.Controls.Add($txtTo)
$tips = New-Object System.Windows.Forms.ToolTip
$tips.SetToolTip($txtTo, "Comma-separated email addresses. Leave blank to skip email and only notify on this PC.")

$form.Controls.Add((New-Label "SMTP server / port:" 15 100))
$txtSmtp = New-Object System.Windows.Forms.TextBox
$txtSmtp.Location = New-Object System.Drawing.Point(150, 100); $txtSmtp.Width = 290
$txtSmtp.Anchor = "Top,Left,Right"
$form.Controls.Add($txtSmtp)
$numPort = New-Object System.Windows.Forms.NumericUpDown
$numPort.Location = New-Object System.Drawing.Point(450, 100); $numPort.Width = 70
$numPort.Minimum = 1; $numPort.Maximum = 65535
$numPort.Anchor = "Top,Right"
$form.Controls.Add($numPort)

$form.Controls.Add((New-Label "Send from:" 15 135))
$txtFrom = New-Object System.Windows.Forms.TextBox
$txtFrom.Location = New-Object System.Drawing.Point(150, 135); $txtFrom.Width = 370
$txtFrom.Anchor = "Top,Left,Right"
$form.Controls.Add($txtFrom)

$form.Controls.Add((New-Label "Alert after this many missed pings:" 15 170))
$numFails = New-Object System.Windows.Forms.NumericUpDown
$numFails.Location = New-Object System.Drawing.Point(250, 170); $numFails.Width = 60
$numFails.Minimum = 1; $numFails.Maximum = 60
$form.Controls.Add($numFails)

$chkRecover = New-Object System.Windows.Forms.CheckBox
$chkRecover.Text = "Also alert when the host comes back up"
$chkRecover.Location = New-Object System.Drawing.Point(15, 203); $chkRecover.AutoSize = $true
$form.Controls.Add($chkRecover)

$chkMute = New-Object System.Windows.Forms.CheckBox
$chkMute.Text = "Mute sounds (toast + email still sent)"
$chkMute.Location = New-Object System.Drawing.Point(15, 228); $chkMute.AutoSize = $true
$form.Controls.Add($chkMute)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "Start"; $btnStart.Location = New-Object System.Drawing.Point(15, 258); $btnStart.Size = New-Object System.Drawing.Size(100, 30)
$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "Stop"; $btnStop.Location = New-Object System.Drawing.Point(125, 258); $btnStop.Size = New-Object System.Drawing.Size(100, 30)
$btnStop.Enabled = $false
$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = "Send test alert"; $btnTest.Location = New-Object System.Drawing.Point(235, 258); $btnTest.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.AddRange(@($btnStart, $btnStop, $btnTest))

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(15, 300); $lblStatus.Size = New-Object System.Drawing.Size(505, 28)
$lblStatus.TextAlign = "MiddleLeft"; $lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblStatus.Anchor = "Top,Left,Right"
$lblStatus.Text = "Idle."; $lblStatus.BackColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 338); $txtLog.Size = New-Object System.Drawing.Size(505, 157)
$txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = "Vertical"
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($txtLog)

# Initial values: command-line > saved settings > defaults
$txtTarget.Text = if ($Target) { $Target } elseif ($saved.Target) { $saved.Target } else { "8.8.8.8" }
$txtTo.Text     = if ($To) { $To } elseif ($saved.To) { $saved.To } else { "" }
$txtSmtp.Text   = if ($saved.Smtp) { $saved.Smtp } else { $DefaultSmtpServer }
$numPort.Value  = if ($saved.Port) { [int]$saved.Port } else { $DefaultSmtpPort }
$txtFrom.Text   = if ($saved.From) { $saved.From } else { Get-SenderAddress }
$numFails.Value = if ($saved.Fails) { [int]$saved.Fails } else { $DefaultFailCount }
$chkRecover.Checked = if ($null -ne $saved -and $null -ne $saved.Recover) { [bool]$saved.Recover } else { $true }
$chkMute.Checked    = if ($null -ne $saved -and $null -ne $saved.Mute) { [bool]$saved.Mute } else { $false }

# ==============================================================================
# MONITOR TIMER - polls every 250 ms; pings run asynchronously so the UI never hangs
# ==============================================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250

function Register-PingResult([bool]$ok, [string]$detail, $ms) {
    $target = $State.Target
    if ($ok) {
        $State.Fails = 0
        if ($State.Down) {
            $State.Oks++
            if ($State.Oks -ge $RecoverCount) { Invoke-Recovery }
            else { Set-Status "$target answering again - confirming ($($State.Oks)/$RecoverCount) ..." ([System.Drawing.Color]::Khaki) }
        } else {
            Set-Status "$target is UP  ($ms ms)  -  $(Get-Date -Format 'HH:mm:ss')" ([System.Drawing.Color]::LightGreen)
        }
    } else {
        $State.Oks = 0
        if ($State.Down) {
            Set-Status "$target is DOWN since $($State.DownSince.ToString('HH:mm:ss'))  ($(Format-Duration ((Get-Date) - $State.DownSince)))" ([System.Drawing.Color]::IndianRed)
        } else {
            $State.Fails++
            Write-Log "Missed ping $($State.Fails)/$([int]$numFails.Value): $detail"
            Set-Status "$target missed $($State.Fails) ping(s)" ([System.Drawing.Color]::Khaki)
            if ($State.Fails -ge [int]$numFails.Value) { Invoke-Alert }
        }
    }
}

$timer.Add_Tick({
    if (-not $State.Running) { return }

    if ($State.Task) {
        if (-not $State.Task.IsCompleted) { return }
        $task = $State.Task; $State.Task = $null
        $ok = $false; $detail = "no reply"; $ms = 0
        if ($task.IsFaulted) {
            $detail = $task.Exception.GetBaseException().Message
        } elseif (-not $task.IsCanceled) {
            $reply = $task.Result
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $ok = $true; $ms = $reply.RoundtripTime }
            else { $detail = [string]$reply.Status }
        }
        Register-PingResult $ok $detail $ms
        return
    }

    if (([datetime]::Now - $State.LastStart).TotalMilliseconds -ge $PingIntervalMs) {
        $State.LastStart = [datetime]::Now
        try { $State.Task = $pinger.SendPingAsync($State.Target, $PingTimeoutMs) }
        catch { Register-PingResult $false $_.Exception.GetBaseException().Message 0 }
    }
})

# ==============================================================================
# BUTTONS
# ==============================================================================
$btnStart.Add_Click({ Start-Monitoring })
$btnStop.Add_Click({ Stop-Monitoring })
$btnTest.Add_Click({
    $rcpt = Get-Recipients
    if ($rcpt.Bad.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show("These don't look like email addresses:`n`n" + ($rcpt.Bad -join "`n"), "Ping Alert"); return
    }
    if ($rcpt.Valid.Count -gt 0) {
        $problem = Get-MailSettingsProblem
        if ($problem) { [void][System.Windows.Forms.MessageBox]::Show($problem, "Ping Alert"); return }
    }
    Save-Settings
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Publish-Event "Ping Alert test" "This is a test alert from $($env:COMPUTERNAME)." "Ping Alert test" `
            "This is a test message from Ping Alert on $($env:COMPUTERNAME) ($($env:USERNAME)) at $(Get-Date)." @(800) 500
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

$form.Add_FormClosing({
    $timer.Stop()
    Save-Settings
    if ($State.Tray) { $State.Tray.Visible = $false; $State.Tray.Dispose() }
})
$form.Add_Shown({
    $form.Activate()
    if ($AutoStart) { Start-Monitoring }
})

[void]$form.ShowDialog()
$timer.Dispose(); $pinger.Dispose(); $form.Dispose()
