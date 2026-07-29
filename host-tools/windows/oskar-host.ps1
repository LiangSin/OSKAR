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
$HostKeyDebounceMs = 150
$LastHostKeyPress = @{}
$AppWindowCache = @{}

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
        key1_action = "paste"
        key1_text = "OSKAR key 1"
        key1_url = "https://www.arm.com/"
        key1_app = ""
        key2_action = "url"
        key2_text = "OSKAR key 2"
        key2_url = "https://www.arm.com/"
        key2_app = ""
        key3_action = "app"
        key3_text = "OSKAR key 3"
        key3_url = "https://www.arm.com/"
        key3_app = ""
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
    foreach ($number in 1..3) {
        $actionKey = "key${number}_action"
        if ($config[$actionKey] -notin @("paste", "url", "app")) {
            $config[$actionKey] = (New-DefaultConfig)[$actionKey]
        }
    }
    return $config
}

function Save-Config($Config) {
    $path = Get-ConfigPath
    $parent = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $lines = @("# OSKAR host configuration")
    foreach ($number in 1..3) {
        foreach ($field in @("action", "text", "url", "app")) {
            $key = "key${number}_$field"
            $value = ConvertTo-EscapedValue ($Config[$key])
            $lines += "$key=$value"
        }
    }
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
}

function Show-Config($Config) {
    Write-Host "config: $(Get-ConfigPath)"
    foreach ($number in 1..3) {
        $button = "key$number"
        $action = $Config["${button}_action"]
        $valueKey = Get-ActionConfigKey $button $action
        Write-Host "$button action = $action"
        Write-Host "$button value = $($Config[$valueKey])"
    }
}

function Resolve-Button([string]$Value) {
    switch ($Value.ToLowerInvariant()) {
        { $_ -in @("1", "key1", "f13") } { return "key1" }
        { $_ -in @("2", "key2", "f14") } { return "key2" }
        { $_ -in @("3", "key3", "f15") } { return "key3" }
        default { throw "button must be key1, key2, or key3" }
    }
}

function Get-ActionConfigKey([string]$ButtonName, [string]$Action) {
    switch ($Action) {
        "paste" { return "${ButtonName}_text" }
        "url" { return "${ButtonName}_url" }
        "app" { return "${ButtonName}_app" }
        default { throw "unsupported action for ${ButtonName}: $Action" }
    }
}

function Get-ActionDisplayName([string]$Action) {
    $names = @{
        paste = "Paste text"
        url = "Open URL"
        app = "Open app"
    }
    return $names[$Action]
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

function Open-Url([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Key2 URL is empty"
    }
    if ($DryRun) {
        Write-Host "open URL: $Value"
        return
    }
    Start-Process $Value
}

function Ensure-WindowActivatorType {
    if (-not ("OskarWindowActivator" -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class OskarWindowActivator {
    private delegate bool EnumWindowsCallback(IntPtr hWnd, IntPtr lParam);
    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_SHOWWINDOW = 0x0040;

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr processId);

    [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")]
    private static extern uint GetWindowThreadProcessIdForWindow(IntPtr hWnd, out uint processId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);

    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("shell32.dll")]
    private static extern int SHGetKnownFolderPath(
        ref Guid rfid, uint flags, IntPtr token, out IntPtr path);

    public static string GetKnownFolderPath(Guid folderId) {
        IntPtr path = IntPtr.Zero;
        try {
            int result = SHGetKnownFolderPath(ref folderId, 0, IntPtr.Zero, out path);
            return result == 0 && path != IntPtr.Zero ? Marshal.PtrToStringUni(path) : null;
        } finally {
            if (path != IntPtr.Zero) Marshal.FreeCoTaskMem(path);
        }
    }

    public static IntPtr FindVisibleTopLevelWindow(uint processId) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            uint ownerProcessId;
            GetWindowThreadProcessIdForWindow(hWnd, out ownerProcessId);
            if (ownerProcessId == processId && IsWindowVisible(hWnd) && GetWindowTextLength(hWnd) > 0) {
                found = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool IsUsableWindow(IntPtr hWnd, uint expectedProcessId) {
        if (hWnd == IntPtr.Zero || !IsWindow(hWnd) || !IsWindowVisible(hWnd)) return false;
        uint actualProcessId;
        GetWindowThreadProcessIdForWindow(hWnd, out actualProcessId);
        return actualProcessId == expectedProcessId;
    }

    public static bool Activate(IntPtr hWnd) {
        if (hWnd == IntPtr.Zero) return false;

        // SW_RESTORE changes a maximized window back to its normal size when
        // called unconditionally. Only restore windows which are minimized.
        if (IsIconic(hWnd)) ShowWindowAsync(hWnd, 9);

        IntPtr foreground = GetForegroundWindow();
        uint currentThread = GetCurrentThreadId();
        uint targetThread = GetWindowThreadProcessId(hWnd, IntPtr.Zero);
        uint foregroundThread = foreground == IntPtr.Zero
            ? 0
            : GetWindowThreadProcessId(foreground, IntPtr.Zero);
        bool attachedTarget = false;
        bool attachedForeground = false;

        try {
            if (targetThread != 0 && targetThread != currentThread)
                attachedTarget = AttachThreadInput(currentThread, targetThread, true);
            if (foregroundThread != 0 && foregroundThread != currentThread && foregroundThread != targetThread)
                attachedForeground = AttachThreadInput(currentThread, foregroundThread, true);

            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);

            // A brief topmost toggle reliably raises the window without moving,
            // resizing, maximizing, or restoring it to its normal dimensions.
            SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
            SetWindowPos(hWnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
            SetForegroundWindow(hWnd);
            return GetForegroundWindow() == hWnd;
        } finally {
            if (attachedForeground) AttachThreadInput(currentThread, foregroundThread, false);
            if (attachedTarget) AttachThreadInput(currentThread, targetThread, false);
        }
    }
}
"@
    }
}

function Get-ShortcutTargetPath([string]$ShortcutPath) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        if (-not $shortcut.TargetPath) { return $null }
        return [Environment]::ExpandEnvironmentVariables($shortcut.TargetPath)
    } catch {
        return $null
    }
}

function Get-ShortcutProcessName([string]$ShortcutPath) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        if ($shortcut.Arguments -match '(?i)--processStart\s+"?([^"\s]+)') {
            return [IO.Path]::GetFileNameWithoutExtension($Matches[1])
        }
    } catch {
        return $null
    }
    return $null
}

function Resolve-AppsFolderExecutablePath([string]$Value) {
    $prefix = "shell:AppsFolder\"
    if (-not $Value.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $itemPath = $Value.Substring($prefix.Length)
    if ([IO.File]::Exists($itemPath) -and [IO.Path]::GetExtension($itemPath) -ieq ".exe") {
        return [IO.Path]::GetFullPath($itemPath)
    }
    if ($itemPath -notmatch '^\{([0-9A-Fa-f-]{36})\}\\(.+)$') {
        return $null
    }
    $folderId = [Guid]$Matches[1]
    $relativePath = $Matches[2]

    try {
        Ensure-WindowActivatorType
        $root = [OskarWindowActivator]::GetKnownFolderPath($folderId)
        if (-not $root) { return $null }
        $root = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
        $candidate = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
        if (-not $candidate.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        if ([IO.File]::Exists($candidate) -and [IO.Path]::GetExtension($candidate) -ieq ".exe") {
            return $candidate
        }
    } catch {
        return $null
    }
    return $null
}

function Get-RelatedAppProcessIds([string]$ExecutablePath) {
    try {
        $snapshot = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        $candidateIds = New-Object 'System.Collections.Generic.HashSet[int]'
        $appDirectory = [IO.Path]::GetDirectoryName($ExecutablePath)

        foreach ($item in $snapshot) {
            if ($item.ExecutablePath -and $item.ExecutablePath -eq $ExecutablePath) {
                [void]$candidateIds.Add([int]$item.ProcessId)
            }
        }

        # Eclipse-style launchers may host their window in a Java child process.
        # Its command line normally contains the launcher's installation folder,
        # even when the original launcher process has already exited.
        if ($appDirectory) {
            foreach ($item in $snapshot) {
                $isJavaRuntime = $item.Name -in @("java.exe", "javaw.exe")
                $referencesExecutable = $item.CommandLine -and
                    $item.CommandLine.IndexOf($ExecutablePath, [StringComparison]::OrdinalIgnoreCase) -ge 0
                if ($item.CommandLine -and ($isJavaRuntime -or $referencesExecutable) -and
                    $item.CommandLine.IndexOf($appDirectory, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    [void]$candidateIds.Add([int]$item.ProcessId)
                }
            }
        }

        do {
            $addedDescendant = $false
            foreach ($item in $snapshot) {
                if ($candidateIds.Contains([int]$item.ParentProcessId) -and
                    $candidateIds.Add([int]$item.ProcessId)) {
                    $addedDescendant = $true
                }
            }
        } while ($addedDescendant)

        return @($candidateIds | Sort-Object)
    } catch {
        Write-Log "could not inspect Key3 process tree: $($_.Exception.Message)"
        return @()
    }
}

function Save-AppWindowCache([string]$CacheKey, [int]$ProcessId, [IntPtr]$WindowHandle) {
    $script:AppWindowCache[$CacheKey] = [PSCustomObject]@{
        ProcessId = $ProcessId
        WindowHandle = $WindowHandle.ToInt64()
    }
}

function Focus-CachedAppWindow([string]$CacheKey) {
    if (-not $script:AppWindowCache.ContainsKey($CacheKey)) { return $false }

    $entry = $script:AppWindowCache[$CacheKey]
    try {
        $windowHandle = [IntPtr]$entry.WindowHandle
        if ([OskarWindowActivator]::IsUsableWindow($windowHandle, [uint32]$entry.ProcessId)) {
            [void][OskarWindowActivator]::Activate($windowHandle)
            return $true
        }
    } catch {
        # A closed/restarted app invalidates the cached PID or window handle.
    }

    [void]$script:AppWindowCache.Remove($CacheKey)
    return $false
}

function Open-App([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($DryRun) { Write-Host "open app: not configured" }
        return
    }

    $isAppsFolderEntry = $Value.StartsWith("shell:AppsFolder\", [StringComparison]::OrdinalIgnoreCase)
    if (-not $isAppsFolderEntry -and -not (Test-Path -LiteralPath $Value -PathType Leaf)) {
        throw "Key3 app does not exist: $Value"
    }
    $resolvedAppsFolderPath = if ($isAppsFolderEntry) {
        Resolve-AppsFolderExecutablePath $Value
    } else {
        $null
    }
    if ($resolvedAppsFolderPath) { $isAppsFolderEntry = $false }
    $path = if ($resolvedAppsFolderPath) {
        $resolvedAppsFolderPath
    } elseif ($isAppsFolderEntry) {
        $Value
    } else {
        (Resolve-Path -LiteralPath $Value).Path
    }
    if ($DryRun) {
        Write-Host "open app: $path"
        return
    }

    if ($isAppsFolderEntry) {
        Start-Process -FilePath "explorer.exe" -ArgumentList $path
        return
    }

    $matchPath = $path
    $matchProcessName = $null
    if ([IO.Path]::GetExtension($path) -ieq ".lnk") {
        $matchPath = Get-ShortcutTargetPath $path
        $matchProcessName = Get-ShortcutProcessName $path
    }

    Ensure-WindowActivatorType
    $cacheKey = $path.ToLowerInvariant()
    if (Focus-CachedAppWindow $cacheKey) { return }

    $processNames = @()
    if ($matchPath -and [IO.Path]::GetExtension($matchPath) -ieq ".exe") {
        $processNames += [IO.Path]::GetFileNameWithoutExtension($matchPath)
    }
    if ($matchProcessName) { $processNames += $matchProcessName }

    $matchingProcesses = @{}
    foreach ($processName in @($processNames | Select-Object -Unique)) {
        foreach ($candidate in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            $matchingProcesses[$candidate.Id] = $candidate
        }
    }
    foreach ($process in $matchingProcesses.Values) {
        try {
            $pathMatches = $matchPath -and $process.Path -and $process.Path -eq $matchPath
            $nameMatches = $matchProcessName -and $process.ProcessName -eq $matchProcessName
            if (-not $pathMatches -and -not $nameMatches) { continue }
            $process.Refresh()
            $windowHandle = $process.MainWindowHandle
            if ($windowHandle -eq [IntPtr]::Zero) {
                $windowHandle = [OskarWindowActivator]::FindVisibleTopLevelWindow([uint32]$process.Id)
            }
            if ($windowHandle -ne [IntPtr]::Zero) {
                Write-Log "key3 focusing existing window; pid=$($process.Id); match=executable"
                Save-AppWindowCache $cacheKey $process.Id $windowHandle
                [void][OskarWindowActivator]::Activate($windowHandle)
                return
            }
        } catch {
            continue
        }
    }

    $relatedExecutablePath = if ($matchPath -and [IO.Path]::GetExtension($matchPath) -ieq ".exe") {
        $matchPath
    } else {
        $null
    }
    if ($relatedExecutablePath) {
        $relatedProcessIds = @(Get-RelatedAppProcessIds $relatedExecutablePath)
        foreach ($processId in $relatedProcessIds) {
            try {
                $windowHandle = [OskarWindowActivator]::FindVisibleTopLevelWindow([uint32]$processId)
                if ($windowHandle -ne [IntPtr]::Zero) {
                    Write-Log "key3 focusing existing window; pid=$processId; match=related-process"
                    Save-AppWindowCache $cacheKey $processId $windowHandle
                    [void][OskarWindowActivator]::Activate($windowHandle)
                    return
                }
            } catch {
                continue
            }
        }
        if ($relatedProcessIds.Count -gt 0) {
            Write-Log "key3 related processes have no visible window; pids=$($relatedProcessIds -join ',')"
        }
    }

    # Launching again is also the correct activation request for apps which own
    # their single-instance behavior and do not expose the window on this process.
    Write-Log "key3 found no existing window; launching: $path"
    Start-Process -FilePath $path
}

function Invoke-KeyAction([string]$ButtonName, $Config) {
    $action = $Config["${ButtonName}_action"]
    $value = $Config[(Get-ActionConfigKey $ButtonName $action)]
    switch ($action) {
        "paste" { Paste-Text $value }
        "url" { Open-Url $value }
        "app" { Open-App $value }
        default { throw "unsupported action for ${ButtonName}: $action" }
    }
}

function Get-InstalledApplications {
    $applications = @{}
    $programFolders = @(
        [Environment]::GetFolderPath([System.Environment+SpecialFolder]::Programs),
        [Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonPrograms)
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }

    foreach ($folder in $programFolders) {
        foreach ($shortcut in Get-ChildItem -LiteralPath $folder -Filter "*.lnk" -File -Recurse -ErrorAction SilentlyContinue) {
            $target = Get-ShortcutTargetPath $shortcut.FullName
            if (-not $target -or [IO.Path]::GetExtension($target) -ine ".exe") { continue }
            $key = $shortcut.BaseName.ToLowerInvariant()
            if ($applications.ContainsKey($key)) { continue }
            $applications[$key] = [PSCustomObject]@{
                Name = $shortcut.BaseName
                LaunchPath = $shortcut.FullName
                Detail = $target
            }
        }
    }

    # AppsFolder also includes Microsoft Store and other registered apps which
    # may not expose a normal executable in Program Files.
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace("shell:AppsFolder")
        foreach ($item in $folder.Items()) {
            $name = [string]$item.Name
            $itemPath = [string]$item.Path
            if (-not $name -or -not $itemPath) { continue }
            $key = $name.ToLowerInvariant()
            if ($applications.ContainsKey($key)) { continue }
            $virtualPath = "shell:AppsFolder\$itemPath"
            $resolvedPath = Resolve-AppsFolderExecutablePath $virtualPath
            $launchPath = if ([IO.File]::Exists($itemPath)) {
                $itemPath
            } elseif ($resolvedPath) {
                $resolvedPath
            } else {
                $virtualPath
            }
            $applications[$key] = [PSCustomObject]@{
                Name = $name
                LaunchPath = $launchPath
                Detail = $itemPath
            }
        }
    } catch {
        Write-Log "could not enumerate AppsFolder: $($_.Exception.Message)"
    }

    return @($applications.Values | Sort-Object Name)
}

function Show-AppPickerDialog($Owner, [string]$CurrentPath) {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Choose an installed application"
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(620, 470)

    $searchLabel = New-Object System.Windows.Forms.Label
    $searchLabel.Text = "Search installed apps"
    $searchLabel.Location = New-Object System.Drawing.Point(16, 16)
    $searchLabel.Size = New-Object System.Drawing.Size(180, 20)
    $dialog.Controls.Add($searchLabel)

    $searchBox = New-Object System.Windows.Forms.TextBox
    $searchBox.Location = New-Object System.Drawing.Point(16, 39)
    $searchBox.Size = New-Object System.Drawing.Size(588, 25)
    $dialog.Controls.Add($searchBox)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(16, 76)
    $list.Size = New-Object System.Drawing.Size(588, 310)
    $list.DisplayMember = "Name"
    $dialog.Controls.Add($list)

    $detailLabel = New-Object System.Windows.Forms.Label
    $detailLabel.Location = New-Object System.Drawing.Point(16, 394)
    $detailLabel.Size = New-Object System.Drawing.Size(588, 36)
    $detailLabel.AutoEllipsis = $true
    $dialog.Controls.Add($detailLabel)

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = "Browse EXE..."
    $browseButton.Location = New-Object System.Drawing.Point(16, 434)
    $browseButton.Size = New-Object System.Drawing.Size(110, 28)
    $dialog.Controls.Add($browseButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(428, 434)
    $cancelButton.Size = New-Object System.Drawing.Size(82, 28)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)

    $selectButton = New-Object System.Windows.Forms.Button
    $selectButton.Text = "Select"
    $selectButton.Location = New-Object System.Drawing.Point(522, 434)
    $selectButton.Size = New-Object System.Drawing.Size(82, 28)
    $selectButton.Enabled = $false
    $dialog.Controls.Add($selectButton)

    $result = [PSCustomObject]@{ Path = $null }
    $allApps = @(Get-InstalledApplications)
    $refreshList = {
        $query = $searchBox.Text.Trim()
        $list.BeginUpdate()
        $list.Items.Clear()
        foreach ($app in $allApps) {
            if (-not $query -or $app.Name.IndexOf($query, [StringComparison]::CurrentCultureIgnoreCase) -ge 0) {
                [void]$list.Items.Add($app)
            }
        }
        $list.EndUpdate()
    }

    $searchBox.Add_TextChanged({ & $refreshList })
    $list.Add_SelectedIndexChanged({
        $selected = $list.SelectedItem
        $selectButton.Enabled = $null -ne $selected
        $detailLabel.Text = if ($selected) { $selected.Detail } else { "" }
    })
    $selectButton.Add_Click({
        if ($list.SelectedItem) {
            $result.Path = $list.SelectedItem.LaunchPath
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
    })
    $list.Add_DoubleClick({ if ($list.SelectedItem) { $selectButton.PerformClick() } })
    $browseButton.Add_Click({
        $picker = New-Object System.Windows.Forms.OpenFileDialog
        $picker.Title = "Choose an application executable"
        $picker.Filter = "Applications (*.exe)|*.exe|All files (*.*)|*.*"
        $picker.CheckFileExists = $true
        if ($CurrentPath -and [IO.File]::Exists($CurrentPath)) {
            $picker.InitialDirectory = Split-Path -Parent $CurrentPath
        }
        if ($picker.ShowDialog($dialog) -eq [System.Windows.Forms.DialogResult]::OK) {
            $result.Path = $picker.FileName
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
        $picker.Dispose()
    })

    $dialog.AcceptButton = $selectButton
    $dialog.CancelButton = $cancelButton
    & $refreshList
    if ($CurrentPath) {
        foreach ($app in $allApps) {
            if ($app.LaunchPath -eq $CurrentPath) {
                $list.SelectedItem = $app
                $list.TopIndex = [Math]::Max(0, $list.SelectedIndex - 4)
                break
            }
        }
    }
    [void]$searchBox.Focus()
    [void]$dialog.ShowDialog($Owner)
    $dialog.Dispose()
    return $result.Path
}

function Should-HandleHostKey([string]$Key) {
    $now = [DateTime]::UtcNow
    if ($LastHostKeyPress.ContainsKey($Key)) {
        $elapsed = ($now - $LastHostKeyPress[$Key]).TotalMilliseconds
        if ($elapsed -lt $HostKeyDebounceMs) {
            return $false
        }
    }

    $LastHostKeyPress[$Key] = $now
    return $true
}

function Get-RawInputSourcePath {
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

    $rawInputSource = Get-RawInputSourcePath
    if (-not (Test-Path -LiteralPath $rawInputSource)) {
        throw "missing Raw Input HID source: $rawInputSource"
    }

    Add-Type -Path $rawInputSource -ReferencedAssemblies System.Windows.Forms

    $callback = [System.Action[int]]{
        param([int]$buttonId)
        try {
            $config = Read-Config
            switch ($buttonId) {
                1 {
                    if (-not (Should-HandleHostKey "key1")) { return }
                    Write-Log "key1 pressed"
                    Invoke-KeyAction "key1" $config
                }
                2 {
                    if (-not (Should-HandleHostKey "key2")) { return }
                    Write-Log "key2 pressed"
                    Invoke-KeyAction "key2" $config
                }
                3 {
                    if (-not (Should-HandleHostKey "key3")) { return }
                    Write-Log "key3 pressed"
                    Invoke-KeyAction "key3" $config
                }
            }
        } catch {
            Write-Log "key action failed: $($_.Exception.Message)"
            Write-Host "key action failed: $($_.Exception.Message)"
        }
    }

    try {
        Write-Log "waiting for OSKAR custom HID reports"
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
    $dialog.ClientSize = New-Object System.Drawing.Size(620, 440)
    $dialog.KeyPreview = $true

    $actionDisplay = [ordered]@{
        paste = "Paste text"
        url = "Open URL"
        app = "Open app"
    }
    $displayToAction = @{}
    $valueLabelDisplay = @{
        paste = "Text"
        url = "URL"
        app = "Application"
    }
    foreach ($action in $actionDisplay.Keys) {
        $displayToAction[$actionDisplay[$action]] = $action
    }
    $actionBoxes = @{}
    $valueBoxes = @{}
    $pasteBoxes = @{}
    $valueLabels = @{}
    $chooseButtons = @{}
    $selectedActions = @{}
    $savedValues = @{}

    $refreshRow = {
        param([string]$ButtonName)
        $previousAction = $selectedActions[$ButtonName]
        if ($previousAction) {
            if ($previousAction -eq "paste") {
                $savedValues[$ButtonName][$previousAction] = $pasteBoxes[$ButtonName].Text
            } else {
                $savedValues[$ButtonName][$previousAction] = $valueBoxes[$ButtonName].Text
            }
        }
        $action = $displayToAction[[string]$actionBoxes[$ButtonName].SelectedItem]
        $selectedActions[$ButtonName] = $action
        $valueLabels[$ButtonName].Text = $valueLabelDisplay[$action]
        if ($action -eq "paste") {
            $pasteBoxes[$ButtonName].Text = $savedValues[$ButtonName][$action]
            $pasteBoxes[$ButtonName].Visible = $true
            $valueBoxes[$ButtonName].Visible = $false
        } else {
            $valueBoxes[$ButtonName].Text = $savedValues[$ButtonName][$action]
            $valueBoxes[$ButtonName].Visible = $true
            $pasteBoxes[$ButtonName].Visible = $false
        }
        $chooseButtons[$ButtonName].Visible = $action -eq "app"
    }

    foreach ($number in 1..3) {
        $buttonName = "key$number"
        $group = New-Object System.Windows.Forms.GroupBox
        $group.Text = "Key $number"
        $group.Location = New-Object System.Drawing.Point(16, (12 + (($number - 1) * 118)))
        $group.Size = New-Object System.Drawing.Size(588, 110)
        $dialog.Controls.Add($group)

        $actionLabel = New-Object System.Windows.Forms.Label
        $actionLabel.Text = "Action"
        $actionLabel.Location = New-Object System.Drawing.Point(14, 24)
        $actionLabel.Size = New-Object System.Drawing.Size(58, 20)
        $group.Controls.Add($actionLabel)

        $actionBox = New-Object System.Windows.Forms.ComboBox
        $actionBox.Location = New-Object System.Drawing.Point(82, 20)
        $actionBox.Size = New-Object System.Drawing.Size(170, 24)
        $actionBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        foreach ($displayName in $actionDisplay.Values) {
            [void]$actionBox.Items.Add([string]$displayName)
        }
        $actionBox.SelectedItem = $actionDisplay[$config["${buttonName}_action"]]
        $actionBox.Tag = $buttonName
        $group.Controls.Add($actionBox)
        $actionBoxes[$buttonName] = $actionBox

        $valueLabel = New-Object System.Windows.Forms.Label
        $valueLabel.Location = New-Object System.Drawing.Point(14, 56)
        $valueLabel.Size = New-Object System.Drawing.Size(62, 20)
        $group.Controls.Add($valueLabel)
        $valueLabels[$buttonName] = $valueLabel

        $valueBox = New-Object System.Windows.Forms.TextBox
        $valueBox.Location = New-Object System.Drawing.Point(82, 53)
        $valueBox.Size = New-Object System.Drawing.Size(390, 24)
        $group.Controls.Add($valueBox)
        $valueBoxes[$buttonName] = $valueBox

        $pasteBox = New-Object System.Windows.Forms.TextBox
        $pasteBox.Location = New-Object System.Drawing.Point(82, 53)
        $pasteBox.Size = New-Object System.Drawing.Size(390, 48)
        $pasteBox.Multiline = $true
        $pasteBox.AcceptsReturn = $true
        $pasteBox.WordWrap = $true
        $pasteBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $group.Controls.Add($pasteBox)
        $pasteBoxes[$buttonName] = $pasteBox

        $chooseButton = New-Object System.Windows.Forms.Button
        $chooseButton.Text = "Choose..."
        $chooseButton.Location = New-Object System.Drawing.Point(482, 51)
        $chooseButton.Size = New-Object System.Drawing.Size(88, 26)
        $chooseButton.Tag = $buttonName
        $chooseButton.Add_Click({
            param($sender, $_eventArgs)
            $name = [string]$sender.Tag
            $selected = Show-AppPickerDialog $dialog $valueBoxes[$name].Text
            if ($selected) {
                $savedValues[$name]["app"] = $selected
                $valueBoxes[$name].Text = $selected
            }
        })
        $group.Controls.Add($chooseButton)
        $chooseButtons[$buttonName] = $chooseButton

        $savedValues[$buttonName] = @{
            paste = $config["${buttonName}_text"]
            url = $config["${buttonName}_url"]
            app = $config["${buttonName}_app"]
        }
        $selectedActions[$buttonName] = $null
        $actionBox.Add_SelectedIndexChanged({
            param($sender, $_eventArgs)
            & $refreshRow ([string]$sender.Tag)
        })
        & $refreshRow $buttonName
    }

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(428, 400)
    $cancelButton.Size = New-Object System.Drawing.Size(82, 28)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = "Save"
    $saveButton.Location = New-Object System.Drawing.Point(522, 400)
    $saveButton.Size = New-Object System.Drawing.Size(82, 28)
    $saveButton.Add_Click({
        $newConfig = New-DefaultConfig
        foreach ($number in 1..3) {
            $buttonName = "key$number"
            $action = $selectedActions[$buttonName]
            if ($action -eq "paste") {
                $savedValues[$buttonName][$action] = $pasteBoxes[$buttonName].Text
            } else {
                $savedValues[$buttonName][$action] = $valueBoxes[$buttonName].Text
            }
            $newConfig["${buttonName}_action"] = $action
            $newConfig["${buttonName}_text"] = $savedValues[$buttonName]["paste"]
            $newConfig["${buttonName}_url"] = $savedValues[$buttonName]["url"]
            $newConfig["${buttonName}_app"] = $savedValues[$buttonName]["app"]
        }
        Save-Config $newConfig
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })
    $dialog.Controls.Add($saveButton)

    $dialog.CancelButton = $cancelButton
    $dialog.Add_KeyDown({
        param($_sender, $eventArgs)
        if ($eventArgs.Control -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $saveButton.PerformClick()
            $eventArgs.SuppressKeyPress = $true
        }
    })
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
    $form.AutoScroll = $true

    $configGroup = New-Object System.Windows.Forms.GroupBox
    $configGroup.Text = "Current config"
    $configGroup.Location = New-Object System.Drawing.Point(16, 14)
    $configGroup.Size = New-Object System.Drawing.Size(488, 142)
    $form.Controls.Add($configGroup)

    $configPathLabel = New-Object System.Windows.Forms.Label
    $configPathLabel.Location = New-Object System.Drawing.Point(16, 24)
    $configPathLabel.Size = New-Object System.Drawing.Size(360, 18)
    $configPathLabel.Text = "Config: $(Get-ConfigPath)"
    $configGroup.Controls.Add($configPathLabel)

    $editButton = New-Object System.Windows.Forms.Button
    $editButton.Text = "Edit"
    $editButton.Location = New-Object System.Drawing.Point(392, 20)
    $editButton.Size = New-Object System.Drawing.Size(78, 28)
    $configGroup.Controls.Add($editButton)

    $keyPreviewGroups = @()
    $keyActionLabels = @()
    $keyValueBoxes = @()
    $previewCaptionFont = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
    foreach ($number in 1..3) {
        $keyGroup = New-Object System.Windows.Forms.GroupBox
        $keyGroup.Text = "Key $number"
        $keyGroup.Location = New-Object System.Drawing.Point(16, (52 + (($number - 1) * 82)))
        $keyGroup.Size = New-Object System.Drawing.Size(454, 74)
        $configGroup.Controls.Add($keyGroup)
        $keyPreviewGroups += $keyGroup

        $actionCaption = New-Object System.Windows.Forms.Label
        $actionCaption.Text = "Action"
        $actionCaption.Font = $previewCaptionFont
        $actionCaption.Location = New-Object System.Drawing.Point(12, 22)
        $actionCaption.Size = New-Object System.Drawing.Size(62, 18)
        $keyGroup.Controls.Add($actionCaption)

        $actionValue = New-Object System.Windows.Forms.Label
        $actionValue.Location = New-Object System.Drawing.Point(84, 22)
        $actionValue.Size = New-Object System.Drawing.Size(352, 18)
        $keyGroup.Controls.Add($actionValue)
        $keyActionLabels += $actionValue

        $configCaption = New-Object System.Windows.Forms.Label
        $configCaption.Text = "Config"
        $configCaption.Font = $previewCaptionFont
        $configCaption.Location = New-Object System.Drawing.Point(12, 49)
        $configCaption.Size = New-Object System.Drawing.Size(62, 18)
        $keyGroup.Controls.Add($configCaption)

        $configValue = New-Object System.Windows.Forms.TextBox
        $configValue.Location = New-Object System.Drawing.Point(84, 46)
        $configValue.Size = New-Object System.Drawing.Size(352, 44)
        $configValue.Multiline = $true
        $configValue.ReadOnly = $true
        $configValue.WordWrap = $true
        $configValue.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $configValue.BackColor = [System.Drawing.SystemColors]::Window
        $keyGroup.Controls.Add($configValue)
        $keyValueBoxes += $configValue
    }

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

    $measureConfigLabel = {
        param($Label, [int]$Width)
        $flags = ([System.Windows.Forms.TextFormatFlags]::WordBreak) -bor ([System.Windows.Forms.TextFormatFlags]::NoPrefix)
        $measured = [System.Windows.Forms.TextRenderer]::MeasureText(
            $Label.Text,
            $Label.Font,
            (New-Object System.Drawing.Size($Width, 0)),
            $flags
        )
        return [Math]::Max(18, $measured.Height)
    }

    $updateWindowLayout = {
        $pathHeight = & $measureConfigLabel $configPathLabel 360
        $configPathLabel.Location = New-Object System.Drawing.Point(16, 24)
        $configPathLabel.Size = New-Object System.Drawing.Size(360, $pathHeight)
        $editButton.Location = New-Object System.Drawing.Point(392, 20)

        $y = [Math]::Max($configPathLabel.Bottom, $editButton.Bottom) + 10
        for ($index = 0; $index -lt 3; $index++) {
            $group = $keyPreviewGroups[$index]
            $group.Location = New-Object System.Drawing.Point(16, $y)
            $group.Size = New-Object System.Drawing.Size(454, 102)
            $y = $group.Bottom + 8
        }
        $configGroup.Height = $y + 4

        $daemonGroup.Location = New-Object System.Drawing.Point(16, ($configGroup.Bottom + 14))
        $advancedToggle.Location = New-Object System.Drawing.Point(16, ($daemonGroup.Bottom + 18))
        $advancedPanel.Location = New-Object System.Drawing.Point(16, ($advancedToggle.Bottom + 8))

        $contentHeight = if ($advancedPanel.Visible) {
            $advancedPanel.Bottom + 18
        } else {
            $advancedToggle.Bottom + 16
        }
        $maximumHeight = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea.Height - 80
        $form.ClientSize = New-Object System.Drawing.Size(520, ([Math]::Min($contentHeight, $maximumHeight)))
    }

    $refreshConfig = {
        $current = Read-Config
        Save-Config $current
        foreach ($number in 1..3) {
            $buttonName = "key$number"
            $action = $current["${buttonName}_action"]
            $value = $current[(Get-ActionConfigKey $buttonName $action)]
            if (-not $value) { $value = "(not configured)" }
            $keyActionLabels[$number - 1].Text = Get-ActionDisplayName $action
            $keyValueBoxes[$number - 1].Text = $value
            $keyValueBoxes[$number - 1].SelectionStart = 0
            $keyValueBoxes[$number - 1].SelectionLength = 0
            $keyValueBoxes[$number - 1].ScrollToCaret()
        }
        & $updateWindowLayout
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
        } else {
            $advancedToggle.Text = "Advanced >"
        }
        & $updateWindowLayout
    })

    & $refreshConfig
    & $refreshStatus
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
            -Description "OSKAR custom HID host daemon" `
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
        $buttonName = Resolve-Button $Button
        $key = Get-ActionConfigKey $buttonName $config["${buttonName}_action"]
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
