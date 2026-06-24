param(
    [Parameter(Position = 0)]
    [ValidateSet("init-config", "print-config", "set", "ui", "daemon", "start-daemon", "stop-daemon", "daemon-status", "show-log", "install-startup", "uninstall-startup")]
    [string]$Command = "print-config",

    [Parameter(Position = 1)]
    [string]$Button,

    [Parameter(Position = 2)]
    [string]$Text,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$StartupName = "OSKAR Host Daemon"
$RunKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"

function Get-ScriptDir {
    return Split-Path -Parent $PSCommandPath
}

function Get-ConfigPath {
    if ($env:OSKAR_CONFIG) {
        return $env:OSKAR_CONFIG
    }
    return Join-Path $env:APPDATA "OSKAR\config.txt"
}

function Get-StateDir {
    return Join-Path $env:APPDATA "OSKAR"
}

function Ensure-StateDir {
    New-Item -ItemType Directory -Force -Path (Get-StateDir) | Out-Null
}

function Get-PidPath {
    return Join-Path (Get-StateDir) "oskar-host.pid"
}

function Get-LogPath {
    return Join-Path (Get-StateDir) "oskar-host.log"
}

function Write-Log([string]$Message) {
    Ensure-StateDir
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath (Get-LogPath) -Encoding UTF8 -Value "[$stamp] $Message"
}

function Get-DaemonProcess {
    $pidPath = Get-PidPath
    if (-not (Test-Path -LiteralPath $pidPath)) {
        return $null
    }

    $daemonPidText = (Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $daemonPidText) {
        return $null
    }

    $daemonPid = 0
    if (-not [int]::TryParse($daemonPidText.Trim(), [ref]$daemonPid)) {
        return $null
    }

    return Get-Process -Id $daemonPid -ErrorAction SilentlyContinue
}

function Get-DaemonProcessesFromCommandLine {
    try {
        $scriptName = Split-Path -Leaf $PSCommandPath
        return Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -like "*$scriptName*" -and
                $_.CommandLine -like "* daemon*"
            }
    } catch {
        return @()
    }
}

function Show-DaemonStatus {
    $status = Get-DaemonStatusText
    $status -split "`r?`n" | ForEach-Object { Write-Host $_ }
    Write-Host "pid file: $(Get-PidPath)"
    Write-Host "log file: $(Get-LogPath)"
}

function Get-DaemonStatusText {
    $process = Get-DaemonProcess
    if ($process) {
        return "daemon: running`r`npid: $($process.Id)`r`nstarted: $($process.StartTime)"
    }

    $commandLineProcesses = @(Get-DaemonProcessesFromCommandLine)
    if ($commandLineProcesses.Count -gt 0) {
        $lines = @("daemon: running")
        foreach ($candidate in $commandLineProcesses) {
            $lines += "pid: $($candidate.ProcessId)"
        }
        return ($lines -join "`r`n")
    }

    return "daemon: not running"
}

function ConvertTo-EscapedValue([string]$Value) {
    return $Value.Replace("\", "\\").Replace("`r", "\r").Replace("`n", "\n")
}

function ConvertFrom-EscapedValue([string]$Value) {
    $output = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Value.Length; $i++) {
        if ($Value[$i] -ne "\" -or $i + 1 -ge $Value.Length) {
            [void]$output.Append($Value[$i])
            continue
        }

        $i++
        switch ($Value[$i]) {
            "n" { [void]$output.Append("`n") }
            "r" { [void]$output.Append("`r") }
            "\" { [void]$output.Append("\") }
            default {
                [void]$output.Append("\")
                [void]$output.Append($Value[$i])
            }
        }
    }
    return $output.ToString()
}

function New-DefaultConfig {
    return [ordered]@{
        key1_text = "OSKAR key 1"
        key2_text = "OSKAR key 2"
        key3_text = "OSKAR key 3"
    }
}

function Read-Config {
    $config = New-DefaultConfig
    $path = Get-ConfigPath
    if (-not (Test-Path $path)) {
        return $config
    }

    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or -not $trimmed.Contains("=")) {
            continue
        }
        $parts = $trimmed.Split("=", 2)
        $key = $parts[0].Trim()
        if ($config.Contains($key)) {
            $config[$key] = ConvertFrom-EscapedValue $parts[1].Trim()
        }
    }
    return $config
}

function Save-Config($Config) {
    $path = Get-ConfigPath
    $parent = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $lines = @("# OSKAR host configuration")
    foreach ($key in @("key1_text", "key2_text", "key3_text")) {
        $value = ConvertTo-EscapedValue ($Config[$key])
        $lines += "$key=$value"
    }
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
}

function Show-Config($Config) {
    Write-Host "config: $(Get-ConfigPath)"
    Write-Host "key1/F13 = $($Config["key1_text"])"
    Write-Host "key2/F14 = $($Config["key2_text"])"
    Write-Host "key3/F15 = $($Config["key3_text"])"
}

function Resolve-Button([string]$Value) {
    switch ($Value.ToLowerInvariant()) {
        { $_ -in @("1", "key1", "f13") } { return "key1_text" }
        { $_ -in @("2", "key2", "f14") } { return "key2_text" }
        { $_ -in @("3", "key3", "f15") } { return "key3_text" }
        default { throw "button must be key1, key2, key3, f13, f14, or f15" }
    }
}

function Paste-Text([string]$Value) {
    if ($DryRun) {
        Write-Host "paste: $Value"
        return
    }

    Set-Clipboard -Value $Value
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SendKeys]::SendWait("^v")
}

function Get-HookSourcePath {
    return Join-Path (Get-ScriptDir) "oskar-keyboard-hook.cs"
}

function Start-Daemon {
    $existing = Get-DaemonProcess
    if ($existing -and $existing.Id -ne $PID) {
        Write-Host "oskar-host daemon is already running"
        Write-Host "pid: $($existing.Id)"
        return
    }

    Ensure-StateDir
    Set-Content -LiteralPath (Get-PidPath) -Encoding ASCII -Value ([string]$PID)
    Write-Log "daemon starting; pid=$PID"

    $config = Read-Config
    Save-Config $config
    Write-Host "oskar-host windows daemon started"
    Write-Host "config: $(Get-ConfigPath)"
    Write-Host "log: $(Get-LogPath)"

    $hookSource = Get-HookSourcePath
    if (-not (Test-Path -LiteralPath $hookSource)) {
        throw "missing keyboard hook source: $hookSource"
    }

    Add-Type -Path $hookSource -ReferencedAssemblies System.Windows.Forms

    $callback = [System.Action[int]]{
        param([int]$vkCode)
        try {
            $config = Read-Config
            switch ($vkCode) {
                0x7C {
                    Write-Log "F13 pressed"
                    Paste-Text ($config["key1_text"])
                }
                0x7D {
                    Write-Log "F14 pressed"
                    Paste-Text ($config["key2_text"])
                }
                0x7E {
                    Write-Log "F15 pressed"
                    Paste-Text ($config["key3_text"])
                }
            }
        } catch {
            Write-Log "paste failed: $($_.Exception.Message)"
            Write-Host "paste failed: $($_.Exception.Message)"
        }
    }

    try {
        [OskarKeyboardHook]::Run($callback)
    } catch {
        Write-Log "daemon failed: $($_.Exception.Message)"
        throw
    } finally {
        $pidPath = Get-PidPath
        $pidText = $null
        if (Test-Path -LiteralPath $pidPath) {
            $pidText = Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($pidText -and $pidText.Trim() -eq ([string]$PID)) {
            Remove-Item -LiteralPath $pidPath -ErrorAction SilentlyContinue
        }
        Write-Log "daemon stopped; pid=$PID"
    }
}

function Show-EditConfigDialog($Owner) {
    $config = Read-Config

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Edit OSKAR Config"
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(420, 210)

    $labels = @("Key 1 / F13", "Key 2 / F14", "Key 3 / F15")
    $keys = @("key1_text", "key2_text", "key3_text")
    $boxes = @{}

    for ($i = 0; $i -lt 3; $i++) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $labels[$i]
        $label.Location = New-Object System.Drawing.Point(16, (22 + ($i * 42)))
        $label.Size = New-Object System.Drawing.Size(86, 22)
        $dialog.Controls.Add($label)

        $box = New-Object System.Windows.Forms.TextBox
        $box.Location = New-Object System.Drawing.Point(112, (19 + ($i * 42)))
        $box.Size = New-Object System.Drawing.Size(288, 24)
        $box.Text = $config[$keys[$i]]
        $dialog.Controls.Add($box)
        $boxes[$keys[$i]] = $box
    }

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(224, 162)
    $cancelButton.Size = New-Object System.Drawing.Size(82, 28)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = "Save"
    $saveButton.Location = New-Object System.Drawing.Point(318, 162)
    $saveButton.Size = New-Object System.Drawing.Size(82, 28)
    $saveButton.Add_Click({
        $newConfig = New-DefaultConfig
        foreach ($key in @("key1_text", "key2_text", "key3_text")) {
            $newConfig[$key] = $boxes[$key].Text
        }
        Save-Config $newConfig
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })
    $dialog.Controls.Add($saveButton)

    $dialog.AcceptButton = $saveButton
    $dialog.CancelButton = $cancelButton
    [void]$dialog.ShowDialog($Owner)
}

function Start-Ui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $config = Read-Config
    Save-Config $config

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "OSKAR Host Tools"
    $form.StartPosition = "CenterScreen"
    $form.MinimumSize = New-Object System.Drawing.Size(520, 410)
    $form.ClientSize = New-Object System.Drawing.Size(520, 470)

    $configGroup = New-Object System.Windows.Forms.GroupBox
    $configGroup.Text = "Current config"
    $configGroup.Location = New-Object System.Drawing.Point(16, 14)
    $configGroup.Size = New-Object System.Drawing.Size(488, 142)
    $form.Controls.Add($configGroup)

    $configPathLabel = New-Object System.Windows.Forms.Label
    $configPathLabel.Location = New-Object System.Drawing.Point(16, 24)
    $configPathLabel.Size = New-Object System.Drawing.Size(454, 18)
    $configPathLabel.Text = "Config: $(Get-ConfigPath)"
    $configGroup.Controls.Add($configPathLabel)

    $key1Label = New-Object System.Windows.Forms.Label
    $key1Label.Location = New-Object System.Drawing.Point(16, 52)
    $key1Label.Size = New-Object System.Drawing.Size(454, 18)
    $configGroup.Controls.Add($key1Label)

    $key2Label = New-Object System.Windows.Forms.Label
    $key2Label.Location = New-Object System.Drawing.Point(16, 76)
    $key2Label.Size = New-Object System.Drawing.Size(454, 18)
    $configGroup.Controls.Add($key2Label)

    $key3Label = New-Object System.Windows.Forms.Label
    $key3Label.Location = New-Object System.Drawing.Point(16, 100)
    $key3Label.Size = New-Object System.Drawing.Size(340, 18)
    $configGroup.Controls.Add($key3Label)

    $editButton = New-Object System.Windows.Forms.Button
    $editButton.Text = "Edit"
    $editButton.Location = New-Object System.Drawing.Point(392, 98)
    $editButton.Size = New-Object System.Drawing.Size(78, 28)
    $configGroup.Controls.Add($editButton)

    $daemonGroup = New-Object System.Windows.Forms.GroupBox
    $daemonGroup.Text = "Daemon status"
    $daemonGroup.Location = New-Object System.Drawing.Point(16, 170)
    $daemonGroup.Size = New-Object System.Drawing.Size(488, 142)
    $form.Controls.Add($daemonGroup)

    $statusBox = New-Object System.Windows.Forms.TextBox
    $statusBox.Location = New-Object System.Drawing.Point(16, 26)
    $statusBox.Size = New-Object System.Drawing.Size(360, 72)
    $statusBox.Multiline = $true
    $statusBox.ReadOnly = $true
    $daemonGroup.Controls.Add($statusBox)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = "Refresh"
    $refreshButton.Location = New-Object System.Drawing.Point(392, 26)
    $refreshButton.Size = New-Object System.Drawing.Size(78, 28)
    $daemonGroup.Controls.Add($refreshButton)

    $logsButton = New-Object System.Windows.Forms.Button
    $logsButton.Text = "Logs"
    $logsButton.Location = New-Object System.Drawing.Point(392, 62)
    $logsButton.Size = New-Object System.Drawing.Size(78, 28)
    $daemonGroup.Controls.Add($logsButton)

    $startButton = New-Object System.Windows.Forms.Button
    $startButton.Text = "Start Daemon"
    $startButton.Location = New-Object System.Drawing.Point(16, 104)
    $startButton.Size = New-Object System.Drawing.Size(112, 28)
    $daemonGroup.Controls.Add($startButton)

    $stopButton = New-Object System.Windows.Forms.Button
    $stopButton.Text = "Stop Daemon"
    $stopButton.Location = New-Object System.Drawing.Point(140, 104)
    $stopButton.Size = New-Object System.Drawing.Size(112, 28)
    $daemonGroup.Controls.Add($stopButton)

    $advancedToggle = New-Object System.Windows.Forms.Button
    $advancedToggle.Text = "Advanced >"
    $advancedToggle.Location = New-Object System.Drawing.Point(16, 330)
    $advancedToggle.Size = New-Object System.Drawing.Size(112, 28)
    $form.Controls.Add($advancedToggle)

    $advancedPanel = New-Object System.Windows.Forms.GroupBox
    $advancedPanel.Text = "Advanced"
    $advancedPanel.Location = New-Object System.Drawing.Point(16, 366)
    $advancedPanel.Size = New-Object System.Drawing.Size(488, 86)
    $advancedPanel.Visible = $false
    $form.Controls.Add($advancedPanel)

    $advancedText = New-Object System.Windows.Forms.Label
    $advancedText.Text = "Install registers OSKAR to start when you log in. Uninstall removes that logon registration."
    $advancedText.Location = New-Object System.Drawing.Point(16, 24)
    $advancedText.Size = New-Object System.Drawing.Size(454, 18)
    $advancedPanel.Controls.Add($advancedText)

    $installButton = New-Object System.Windows.Forms.Button
    $installButton.Text = "Install"
    $installButton.Location = New-Object System.Drawing.Point(16, 48)
    $installButton.Size = New-Object System.Drawing.Size(86, 28)
    $advancedPanel.Controls.Add($installButton)

    $uninstallButton = New-Object System.Windows.Forms.Button
    $uninstallButton.Text = "Uninstall"
    $uninstallButton.Location = New-Object System.Drawing.Point(114, 48)
    $uninstallButton.Size = New-Object System.Drawing.Size(86, 28)
    $advancedPanel.Controls.Add($uninstallButton)

    $refreshConfig = {
        $current = Read-Config
        Save-Config $current
        $key1Label.Text = "Key1 / F13: $($current["key1_text"])"
        $key2Label.Text = "Key2 / F14: $($current["key2_text"])"
        $key3Label.Text = "Key3 / F15: $($current["key3_text"])"
    }

    $refreshStatus = {
        $statusBox.Text = Get-DaemonStatusText
    }

    $runAction = {
        param($Action)
        try {
            & $Action
            & $refreshStatus
            return $true
        } catch {
            [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, "OSKAR Host Tools", "OK", "Error") | Out-Null
            return $false
        }
    }

    $editButton.Add_Click({
        Show-EditConfigDialog $form
        & $refreshConfig
    })
    $refreshButton.Add_Click({ & $refreshStatus })
    $logsButton.Add_Click({ & $runAction { Open-Log } })
    $startButton.Add_Click({ & $runAction { Start-DaemonProcess } })
    $stopButton.Add_Click({ & $runAction { Stop-DaemonProcess } })
    $installButton.Add_Click({
        if (& $runAction { Install-Startup }) {
            [System.Windows.Forms.MessageBox]::Show($form, "OSKAR is registered to start when you log in.", "OSKAR Host Tools", "OK", "Information") | Out-Null
        }
    })
    $uninstallButton.Add_Click({
        if (& $runAction { Uninstall-Startup }) {
            [System.Windows.Forms.MessageBox]::Show($form, "OSKAR logon registration was removed.", "OSKAR Host Tools", "OK", "Information") | Out-Null
        }
    })
    $advancedToggle.Add_Click({
        $advancedPanel.Visible = -not $advancedPanel.Visible
        if ($advancedPanel.Visible) {
            $advancedToggle.Text = "Advanced v"
            $form.ClientSize = New-Object System.Drawing.Size(520, 470)
        } else {
            $advancedToggle.Text = "Advanced >"
            $form.ClientSize = New-Object System.Drawing.Size(520, 374)
        }
    })

    & $refreshConfig
    & $refreshStatus
    $form.ClientSize = New-Object System.Drawing.Size(520, 374)
    [void][System.Windows.Forms.Application]::Run($form)
}

function Get-StartupCommand {
    $script = $PSCommandPath
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" daemon"
}

function Start-DaemonProcess {
    $existing = Get-DaemonProcess
    if ($existing) {
        Write-Host "daemon is already running"
        Write-Host "pid: $($existing.Id)"
        return
    }
    $commandLineProcesses = @(Get-DaemonProcessesFromCommandLine)
    if ($commandLineProcesses.Count -gt 0) {
        Write-Host "daemon is already running"
        foreach ($candidate in $commandLineProcesses) {
            Write-Host "pid: $($candidate.ProcessId)"
        }
        return
    }

    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" daemon"
    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        if (Get-DaemonProcess) {
            break
        }
    }
    Show-DaemonStatus
}

function Stop-DaemonProcess {
    $process = Get-DaemonProcess
    $commandLineProcesses = @(Get-DaemonProcessesFromCommandLine)
    if (-not $process -and $commandLineProcesses.Count -eq 0) {
        Write-Host "daemon is not running"
        return
    }

    if ($process) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Write-Host "stopped daemon: $($process.Id)"
    }
    foreach ($candidate in $commandLineProcesses) {
        if ($process -and $candidate.ProcessId -eq $process.Id) {
            continue
        }
        Stop-Process -Id $candidate.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "stopped daemon: $($candidate.ProcessId)"
    }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath (Get-PidPath) -ErrorAction SilentlyContinue
    Write-Log "daemon stopped by command"
}

function Show-Log {
    $logPath = Get-LogPath
    if (-not (Test-Path -LiteralPath $logPath)) {
        Write-Host "log file does not exist yet: $logPath"
        return
    }

    Get-Content -LiteralPath $logPath -Tail 80
}

function Open-Log {
    Ensure-StateDir
    $logPath = Get-LogPath
    if (-not (Test-Path -LiteralPath $logPath)) {
        Set-Content -LiteralPath $logPath -Encoding UTF8 -Value ""
    }
    Start-Process -FilePath "notepad.exe" -ArgumentList "`"$logPath`""
}

function Install-Startup {
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" daemon"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal `
        -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive `
        -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet

    try {
        Register-ScheduledTask `
            -TaskName $StartupName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "OSKAR F13/F14/F15 host daemon" `
            -Force | Out-Null
        if (Get-ItemProperty -Path $RunKeyPath -Name $StartupName -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $RunKeyPath -Name $StartupName
        }
        Write-Host "Registered user scheduled task: $StartupName"
        Start-DaemonProcess
        return
    } catch {
        Write-Host "Could not register a scheduled task: $($_.Exception.Message)"
        Write-Host "Falling back to the current user's Run registry key."
    }

    New-Item -Path $RunKeyPath -Force | Out-Null
    Set-ItemProperty -Path $RunKeyPath -Name $StartupName -Value (Get-StartupCommand)
    Write-Host "Registered user startup command: $StartupName"
    Start-DaemonProcess
}

function Uninstall-Startup {
    $removed = $false

    try {
        $task = Get-ScheduledTask -TaskName $StartupName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $StartupName -Confirm:$false
            Write-Host "Removed scheduled task: $StartupName"
            $removed = $true
        }
    } catch {
        Write-Host "Could not remove scheduled task: $($_.Exception.Message)"
    }

    if (Get-ItemProperty -Path $RunKeyPath -Name $StartupName -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $RunKeyPath -Name $StartupName
        Write-Host "Removed user startup command: $StartupName"
        $removed = $true
    }

    if (-not $removed) {
        Write-Host "No startup registration found for: $StartupName"
    }
}

switch ($Command) {
    "init-config" {
        $config = Read-Config
        Save-Config $config
        Show-Config $config
    }
    "print-config" {
        Show-Config (Read-Config)
    }
    "set" {
        if (-not $Button -or -not $Text) {
            throw "usage: .\oskar-host.ps1 set key1 `"text`""
        }
        $config = Read-Config
        $key = Resolve-Button $Button
        $config[$key] = $Text
        Save-Config $config
        Show-Config $config
    }
    "ui" {
        Start-Ui
    }
    "daemon" {
        Start-Daemon
    }
    "start-daemon" {
        Start-DaemonProcess
    }
    "stop-daemon" {
        Stop-DaemonProcess
    }
    "daemon-status" {
        Show-DaemonStatus
    }
    "show-log" {
        Show-Log
    }
    "install-startup" {
        Install-Startup
    }
    "uninstall-startup" {
        Uninstall-Startup
    }
}
