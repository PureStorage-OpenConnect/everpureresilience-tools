<#
.SYNOPSIS
    Pure Protect Configurator for Windows.

    This script reads network configuration from VMware guest info properties and applies
    static IP addresses, gateways, and DNS servers to network adapters.

    On first run, the script installs itself to a permanent location, creates a new
    scheduled task, and sets up scheduled execution to run on system startup. On normal
    startup, the script performs no network configuration. Network configuration is only
    applied after a recovery operation has been executed.

    After network configuration completes, the script can optionally execute a post-failover
    script. The script path is read from guest info property. If the script exists,
    it is executed in a separate PowerShell process with output captured to a log file. The exit
    code and any error messages are reported back via guest info properties.

    Run with `--uninstall` (or `-Uninstall`) to remove the installation. This requires
    Administrator privileges. It stops and removes the scheduled task and its task folder, and
    deletes the installed script and its log files. If a post-failover script is present in the
    install directory, the directory is kept and only the configurator files are removed.
    Note: the pureprotect.* guest-info properties are left in place. The VMware Tools RPC
    interface cannot delete or empty guestinfo keys from inside a guest. The properties are
    inert once the configurator is removed and are cleared automatically on the next VM power cycle.

.NOTES
    • IPv6 is left untouched.
    • Uses VMware Tools (rpctool.exe) to read/write guest info properties
    • Requires Administrator privileges
#>

param()
# Accept both PowerShell-style `-Uninstall` and CLI-style `--uninstall`.
$Uninstall = ($args -contains '--uninstall') -or ($args -contains '-Uninstall')
# ===========================================================================================
# Installation & Scheduling Configuration
# ===========================================================================================
$ErrorActionPreference = 'Stop'

# Capture full script content at top level (required for Invoke-Expression scenarios)
$script:ScriptContent = $MyInvocation.MyCommand.ScriptBlock.ToString()

$script:ScriptVersion = "2.25.0"
$script:InstallPath = "C:\PureProtect\Scripts\configurator.ps1"
$script:InstallDir = Split-Path -Parent $script:InstallPath
$script:LogTimestampSuffix = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
$script:LogPath = Join-Path $script:InstallDir "configurator-$($script:LogTimestampSuffix).log"
$script:TaskName = "PureProtectConfigurator"
$script:TaskPath = "\PureStorage\PureProtect"
$script:CustomerScriptPath = Join-Path $script:InstallDir "post-failover.ps1"
$script:UninstallInProgress = $false

# ===========================================================================================
# Transcript Logging
# ===========================================================================================

if (-not $Uninstall) {
    if (-not (Test-Path $script:InstallDir)) {
        New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
    }
    try {
        Start-Transcript -Path $script:LogPath -Append -Force | Out-Null
        Write-Host "Transcript started: $($script:LogPath)"
    } catch {
        Write-Warning "Failed to start transcript: $_"
    }
}

function Stop-TranscriptSafe {
    try {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    } catch { }
}

# ===========================================================================================
# Installation & Scheduling Functions
# ===========================================================================================

function Test-IsInstalledLocation {
    $currentScript = $PSCommandPath
    return $currentScript -eq $script:InstallPath
}

function Test-IsScheduleInstalled {
    $existingTask = Get-ScheduledTask -TaskName $script:TaskName -TaskPath "$($script:TaskPath)\" -ErrorAction SilentlyContinue
    return $null -ne $existingTask
}

function Install-Script {
    Write-Host "[Install] Installing Pure Protect Configurator..."

    if (-not (Test-Path $script:InstallDir)) {
        New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
        Write-Host "[Install] Created directory: $($script:InstallDir)"
    }

    Set-Content -Path $script:InstallPath -Value $script:ScriptContent -Force -Encoding UTF8
    Write-Host "[Install] Installed script to: $($script:InstallPath)"

    Set-GuestInfo "installed" "true"
}

function Install-ScheduledTask {
    Write-Host "[Scheduling] Setting up scheduled task..."

    try {
        $existingTask = Get-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Host "[Scheduling] Removing existing scheduled task..."
            Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath -Confirm:$false
        }

        $scheduler = New-Object -ComObject Schedule.Service
        $scheduler.Connect()
        $rootFolder = $scheduler.GetFolder("\")
        $taskPathTrimmed = $script:TaskPath.TrimStart("\")
        $pathParts = $taskPathTrimmed -split "\\"
        $currentPath = ""
        foreach ($part in $pathParts) {
            $currentPath = if ($currentPath) { "$currentPath\$part" } else { $part }
            try {
                $rootFolder.GetFolder($currentPath) | Out-Null
            } catch {
                Write-Host "[Scheduling] Creating task folder: \$currentPath"
                $rootFolder.CreateFolder($currentPath) | Out-Null
            }
        }

        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$($script:InstallPath)`""

        $startupTrigger = New-ScheduledTaskTrigger -AtStartup
        if (-not $startupTrigger) { throw "New-ScheduledTaskTrigger -AtStartup returned null" }

        $settings = New-ScheduledTaskSettingsSet `
            -StartWhenAvailable `
            -DontStopIfGoingOnBatteries `
            -AllowStartIfOnBatteries `
            -DontStopOnIdleEnd `
            -ExecutionTimeLimit (New-TimeSpan) `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 5)

        $principal = New-ScheduledTaskPrincipal `
            -UserId "NT AUTHORITY\SYSTEM" `
            -LogonType ServiceAccount `
            -RunLevel Highest

        $task = New-ScheduledTask `
            -Action $action `
            -Trigger $startupTrigger `
            -Settings $settings `
            -Principal $principal `
            -Description "Pure Protect Configurator - Configures network settings on startup"

        Register-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath -InputObject $task -Force | Out-Null

        Write-Host "[Scheduling] Scheduled task created successfully"
        Write-Host "[Scheduling]   Task: $($script:TaskPath)\$($script:TaskName)"
        Write-Host "[Scheduling]   Trigger: At startup"
        Write-Host "[Scheduling]   Run As: SYSTEM"
    }
    catch {
        Exit-WithError -ExitCode 25 -ErrorMessage "[Scheduling] Failed to create scheduled task: $($_.Exception.Message)"
    }
}

function Invoke-Installation {
    if (Test-IsInstalledLocation) {
        Write-Host "[Install] Already running from installed location"
        Set-GuestInfo "installed" "true"

        if (Test-IsScheduleInstalled) {
            Write-Host "[Install] Scheduled task already installed, skipping installation"
            return
        }

        Write-Host "[Install] Scheduled task not found, installing..."
    } else {
        Write-Host "[Install] First run detected, installing script..."
        Install-Script
    }

    Install-ScheduledTask
    Write-Host "[Install] Installation complete"
}

function Report-CustomerScriptExistence {
    if (Test-Path $script:CustomerScriptPath) {
        Write-Host "[Customer Script] Script exists at $($script:CustomerScriptPath)"
        Set-GuestInfo "customer.exists" "true"
    } else {
        Write-Host "[Customer Script] Script does not exist at $($script:CustomerScriptPath)"
        Set-GuestInfo "customer.exists" "false"
    }
}

# ===========================================================================================
# Uninstall Functions
# ===========================================================================================

function Invoke-Uninstall {
    Write-Host "[Uninstall] Starting uninstall"

    try {
        $existingTask = Get-ScheduledTask -TaskName $script:TaskName -TaskPath "$($script:TaskPath)\" -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Host "[Uninstall] Removing scheduled task: $($script:TaskPath)\$($script:TaskName)"
            Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath "$($script:TaskPath)\" -Confirm:$false
        }
    } catch {
        Write-Host "[Uninstall] Failed to remove scheduled task: $($_.Exception.Message)"
    }

    try {
        $scheduler = New-Object -ComObject Schedule.Service
        $scheduler.Connect()
        $rootFolder = $scheduler.GetFolder("\")
        $taskPathTrimmed = $script:TaskPath.TrimStart("\")
        $pathParts = $taskPathTrimmed -split "\\"
        for ($depth = $pathParts.Length; $depth -ge 1; $depth--) {
            $folderPath = ($pathParts[0..($depth - 1)] -join "\")
            try {
                $rootFolder.DeleteFolder($folderPath, 0)
                Write-Host "[Uninstall] Removed task folder: \$folderPath"
            } catch {
                break
            }
        }
    } catch {
        Write-Host "[Uninstall] Task folder cleanup skipped: $($_.Exception.Message)"
    }

    Stop-TranscriptSafe

    if (Test-Path $script:InstallDir) {
        if (Test-Path $script:CustomerScriptPath) {
            Write-Host "[Uninstall] Customer script present at $($script:CustomerScriptPath); preserving $($script:InstallDir)"
            if (Test-Path $script:InstallPath) {
                Write-Host "[Uninstall] Removing installed script: $($script:InstallPath)"
                Remove-Item -Path $script:InstallPath -Force
            }
            Write-Host "[Uninstall] Removing configurator log files from $($script:InstallDir)"
            Get-ChildItem -Path $script:InstallDir -File -Filter 'configurator-*.log' |
                Remove-Item -Force
        } else {
            Write-Host "[Uninstall] Removing install directory: $($script:InstallDir)"
            Remove-Item -Path $script:InstallDir -Recurse -Force
            $parentDir = Split-Path -Parent $script:InstallDir
            if ($parentDir -and (Test-Path $parentDir)) {
                $children = Get-ChildItem -Path $parentDir -Force
                if (-not $children) {
                    Write-Host "[Uninstall] Removing empty parent directory: $parentDir"
                    Remove-Item -Path $parentDir -Force
                }
            }
        }
    }

    Write-Host "[Uninstall] Complete"
}

$script:RpctoolPath = "C:\Program Files\VMware\VMware Tools\rpctool.exe"

function Remove-OldLogFiles {
    param([int]$KeepCount = 5)
    try {
        $logFiles = Get-ChildItem -Path $script:InstallDir -Filter "configurator-*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $KeepCount
        foreach ($file in $logFiles) {
            Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "[Cleanup] Removed old log file: $($file.Name)"
        }
    } catch {
        Write-Warning "Failed to cleanup old log files: $_"
    }
}

function Get-GuestInfo {
    param([string]$Key)
    Test-VmWareTools
    if ($Key.StartsWith("guestinfo.")) {
        $fullKey = $Key
    } else {
        $fullKey = "guestinfo.pureprotect.script.$Key"
    }
    # Avoids vmtoolsd RPC throttle that returns empty results or hangs ~2s on back-to-back calls.
    Start-Sleep -Milliseconds 100
    try {
        $result = & $script:RpctoolPath "info-get $fullKey"
    } catch {
        Write-Host "[Get-GuestInfo] VMware Tools error on '$fullKey': $($_.Exception.Message). Retrying once after tools check..."
        Test-VmWareTools
        Start-Sleep -Milliseconds 100
        $result = & $script:RpctoolPath "info-get $fullKey"
    }
    if ($LASTEXITCODE -eq 0) {
        return "$result".Trim()
    }
    return $null
}

function Initialize-ExecutionTracking {
    # Set execution start timestamp
    $startTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    Set-GuestInfo "exec.startTimestamp" $startTime

    # Set guestInfo installation version
    Set-GuestInfo "version" $script:ScriptVersion
}

function Set-GuestInfo {
    param(
        [string]$Key,
        [string]$Value
    )
    Test-VmWareTools
    $fullKey = "guestinfo.pureprotect.script.$Key"
    Start-Sleep -Milliseconds 100
    try {
        $result = & $script:RpctoolPath "info-set $fullKey $Value"
    } catch {
        Write-Host "[Set-GuestInfo] VMware Tools error on '$fullKey': $($_.Exception.Message). Retrying once after tools check..."
        Test-VmWareTools
        Start-Sleep -Milliseconds 100
        $result = & $script:RpctoolPath "info-set $fullKey $Value"
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[Set-GuestInfo] Failed to set $fullKey"
    }
}

function Write-LogToGuestInfo {
    # Read the log file and write it to guest info property (base64 encoded)
    if (Test-Path $script:LogPath) {
        try {
            # Read last ~48KB of log to stay under 64KB limit after base64 encoding
            $logLines = Get-Content -Path $script:LogPath -Tail 1000 -ErrorAction SilentlyContinue
            $logContent = $logLines -join "`r`n"
            if ($logContent) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($logContent)
                # Truncate to ~48KB if needed
                if ($bytes.Length -gt 48000) {
                    $bytes = $bytes[($bytes.Length - 48000)..($bytes.Length - 1)]
                }
                $encodedLog = [Convert]::ToBase64String($bytes)
                Set-GuestInfo "exec.log" $encodedLog
            }
        } catch {
            Write-Warning "Failed to write log to guest info: $_"
        }
    }
}

$script:NetworkConfigPresent = $false

function Exit-WithError {
    param(
        [int]$ExitCode,
        [string]$ErrorMessage
    )
    Write-Warning $ErrorMessage
    Set-GuestInfo "exec.exitCode" $ExitCode
    Set-GuestInfo "exec.errorMessage" $ErrorMessage
    Set-GuestInfo "exec.endTimestamp" ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))
    Stop-TranscriptSafe
    Write-LogToGuestInfo
    exit $ExitCode
}

function Report-NetworkResult {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$Message
    )
    if ($ExitCode -eq 0) {
        Write-Host $Message
    } else {
        Write-Warning $Message
        Set-GuestInfo "network.errorMessage" $Message
    }
    Set-GuestInfo "network.exitCode" $ExitCode
    Set-GuestInfo "network.endTimestamp" ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))
}

function Complete-Execution {
    Set-GuestInfo "exec.exitCode" "0"
    Set-GuestInfo "exec.endTimestamp" ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))
    Write-Host "[Completion] Script execution completed"
    Stop-TranscriptSafe
    Write-LogToGuestInfo
    exit 0
}

function Get-NicData {
    Write-Host "[Network configuration] Getting network configuration from guest info properties"
    $nicCountStr = Get-GuestInfo "network.nicCount"
    if (-not $nicCountStr) {
        $probe = Get-GuestInfo "guestinfo.vmtools.buildNumber"
        if (-not $probe) {
            Write-Host "[Network configuration] info-get visibility check failed"
        } else {
            Write-Host "[Network configuration] No network configuration will be performed in this run"
        }
        Report-NetworkResult -ExitCode 17 -Message "Network configuration was skipped because the script did not detect any network properties on this VM"
        $script:NetworkConfigPresent = $false
        return @()
    }

    $script:NetworkConfigPresent = $true

    # Set network configuration start timestamp (only when network config is present)
    Set-GuestInfo "network.startTimestamp" ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))

    $nicCount = [int]$nicCountStr
    Write-Host "Found $nicCount NIC(s) to configure from guest info properties"

    $nics = @()
    for ($i = 0; $i -lt $nicCount; $i++) {
        $mac = Get-GuestInfo "network.nic.$i.mac"
        $ip = Get-GuestInfo "network.nic.$i.ip"
        $gateway = Get-GuestInfo "network.nic.$i.gateway"
        $dns = Get-GuestInfo "network.nic.$i.dns"

        if ($mac -and $ip) {
            $nics += @{
                macAddress     = $mac
                ipAddress      = $ip
                defaultGateway = $gateway
                dnsServers     = $dns
            }
            Write-Host "NIC $i : MAC=$mac, IP=$ip, Gateway=$gateway, DNS=$dns"
        } else {
            Write-Warning "Incomplete configuration for NIC $i (MAC=$mac, IP=$ip)"
        }
    }

    return $nics
}

function Test-PowerShellVersion {
    $minVersion = [Version]'5.0'
    $currentVersion = $PSVersionTable.PSVersion

    if ($currentVersion -lt $minVersion) {
        Exit-WithError -ExitCode 24 -ErrorMessage "PowerShell $minVersion or higher is required. Current version: $currentVersion"
    }
}


function Test-VmWareTools {
    # Uninstall is best-effort: skip the blocking tools health gate (and the retry re-checks in
    # Get-/Set-GuestInfo) so missing or unhealthy VMware Tools cannot abort local cleanup.
    if ($script:UninstallInProgress) {
        return
    }
    $startTime = Get-Date
    while ($true) {
        # First check if rpctool.exe exists
        if (-not (Test-Path $script:RpctoolPath)) {
            Write-Host "[Tools Check] VMware Tools rpctool.exe not found at $script:RpctoolPath. VMware Tools must be installed and running."
        } else {
            # File exists - verify VMware Tools is functional by trying to get a dummy key
            # SUCCESS: empty string OR "No value found" = tools work, key just doesn't exist
            # FAILURE: error message (e.g. "VMware Tools is not installed") = tools not working, retry
            try {
                $previousErrorAction = $ErrorActionPreference
                $ErrorActionPreference = 'SilentlyContinue'
                $testOutput = & $script:RpctoolPath "info-get guestinfo.pureprotect.dummy" 2>&1
            } finally {
                $ErrorActionPreference = $previousErrorAction
            }
            $errorText = "$testOutput"

            # Check for success: empty or "No value found" means tools work, key just doesn't exist
            if ([string]::IsNullOrEmpty($errorText) -or $errorText -match "No value found") {
                return
            } else {
                # Any other output = tools not functional (not installed, service down, RPC unavailable, etc.)
                Write-Host "[Tools Check] VMware Tools not functional: $errorText"
            }
        }

        $elapsed = (Get-Date) - $startTime
        if ($elapsed.TotalSeconds -gt 300) {
            # If we are failing for 5 minutes, exit with error
            Write-Error "[Tools Check] VMware Tools not found or not functional after 5 minutes" -ErrorAction Continue
            Stop-TranscriptSafe
            exit 18
        } else {
            Write-Host "[Tools Check] Will retry to find VMware Tools (rpctool.exe) in 5 seconds"
            Start-Sleep -Seconds 5
        }
    }
}

function Test-AdminPrivileges {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $hasNetworkConfigurationOperatorGrp = $currentIdentity.Groups |
            Where-Object { $_.Value -eq 'S-1-5-32-556' -and -not $_.IsDenyOnly }

    $isAdministrator = $currentIdentity.Groups |
            Where-Object { $_.Value -eq 'S-1-5-32-544' -and -not $_.IsDenyOnly }

    if (-not ($hasNetworkConfigurationOperatorGrp -or $isAdministrator)) {
        Exit-WithError -ExitCode 21 -ErrorMessage "User is missing 'Network Configuration Operators' group"
    }
}

<#
.SYNOPSIS
    Returns $true when the given error is transient and worth retrying.
.DESCRIPTION
    A CimException carries the WBEM status in NativeErrorCode and in MessageId ("HRESULT 0x80041002");
    its HResult is the generic managed 0x80131500, so HResult is only a fallback for non-CIM errors.

    CDXML cmdlets (Get-NetIPAddress, Get-NetRoute, ...) throw CimJobException on a zero-match query
    instead - no NativeErrorCode/MessageId, generic HResult - so matched via FullyQualifiedErrorId
    "CmdletizationQuery_NotFound,<CmdletName>" (confirmed live).
#>
function Test-TransientCimError {
    param($ErrorRecord)

    if ($ErrorRecord.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound,*') {
        return $true
    }

    $exception = $ErrorRecord.Exception
    if (-not $exception) {
        return $false
    }

    # These are not inherently transient, but in this context the CIM object was just found
    # moments before - so "not found" means the device is mid-transition, not permanently gone.
    $transientNativeErrorCodes = @('NotFound', 'ServerIsShuttingDown')
    $transientCodes = @(
        [int64]2147943568   # 0x80070490 = HRESULT wrapping Win32 ERROR_NOT_FOUND (1168)
        [int64]2147749890   # 0x80041002 = WBEM_E_NOT_FOUND
        [int64]2147749897   # 0x80041009 = WBEM_E_NOT_AVAILABLE
        [int64]2147749939   # 0x80041033 = WBEM_E_SHUTTING_DOWN (e.g. VMware Tools upgrade)
        [int64]2147749993   # 0x80041069 = WBEM_E_TIMED_OUT
        [int64]2147750024   # 0x80041088 = WBEM_E_PROVIDER_TIMED_OUT
    )

    if ($exception.PSObject.Properties['NativeErrorCode'] -and
        ([string]$exception.NativeErrorCode) -in $transientNativeErrorCodes) {
        return $true
    }

    $code = $null
    if ($exception.PSObject.Properties['MessageId'] -and
        "$($exception.MessageId)" -match '0x([0-9A-Fa-f]{8})') {
        $code = [Convert]::ToInt64($matches[1], 16)
    }
    elseif ($null -ne $exception.HResult) {
        $code = [int64]$exception.HResult -band [int64]4294967295
    }

    return $code -in $transientCodes
}

<#
.SYNOPSIS
    Invokes a Win32_NetworkAdapterConfiguration CIM method with retry on transient errors.
.DESCRIPTION
    Retries up to 4 times with exponential backoff.
    Re-fetches the CIM object on every attempt to handle stale WMI references.
    Only retries on transient errors; non-transient errors fail immediately.
#>
function Invoke-CimMethodWithRetry {
    param(
        [int]$InterfaceIndex,
        [string]$MethodName,
        [hashtable]$Arguments
    )

    $retryDelays = @(5, 10, 20, 40)
    $maxAttempts = $retryDelays.Length + 1   # 1 initial + 4 retries
    $attempt     = 0

    while ($true) {
        $attempt++

        # Re-fetch CIM object every attempt, it may become stale during hardware transition.
        $nic = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration |
                Where-Object { $_.InterfaceIndex -eq $InterfaceIndex }

        if (-not $nic) {
            if ($attempt -lt $maxAttempts) {
                $delay = $retryDelays[$attempt - 1]
                Write-Host "[Network configuration] Win32_NetworkAdapterConfiguration not found for InterfaceIndex $InterfaceIndex. Retry $attempt/$($retryDelays.Length) in ${delay}s..."
                Start-Sleep -Seconds $delay
                continue
            }
            throw "[Network configuration] Could not find Win32_NetworkAdapterConfiguration for InterfaceIndex $InterfaceIndex"
        }

        $cimError = $null
        $result = $null
        try {
            $result = Invoke-CimMethod -InputObject $nic -MethodName $MethodName -ErrorAction Stop -Arguments $Arguments
        } catch {
            $cimError = $_
        }

        # ── Thrown exception, retry only if transient ──
        if ($cimError) {
            if ((Test-TransientCimError $cimError) -and ($attempt -lt $maxAttempts)) {
                $delay = $retryDelays[$attempt - 1]
                Write-Host "[Network configuration] $MethodName threw a transient exception ($($cimError.Exception.NativeErrorCode)/$($cimError.Exception.MessageId)): $($cimError.Exception.Message). Retry $attempt/$($retryDelays.Length) in ${delay}s..."
                Start-Sleep -Seconds $delay
                continue
            }
            throw $cimError
        }

        # ── Success ──
        if ($result.ReturnValue -in @(0, 1)) {
            if ($attempt -gt 1) {
                Write-Host "[Network configuration] $MethodName succeeded on attempt $attempt"
            }
            return $result
        }

        # ── Transient return value, retry ──
        # 97 means TCP/IP is not bound on the adapter yet, which stops once it is bound.
        # Both callers have a fallback for a 97 that is still returned after the retries.
        if (($result.ReturnValue -eq 97) -and ($attempt -lt $maxAttempts)) {
            $delay = $retryDelays[$attempt - 1]
            Write-Host "[Network configuration] $MethodName returned transient error $($result.ReturnValue). Retry $attempt/$($retryDelays.Length) in ${delay}s..."
            Start-Sleep -Seconds $delay
            continue
        }

        # ── Non-transient or retries exhausted ──
        return $result
    }
}

<#
.SYNOPSIS
    Disables DHCP and sets a static IPv4 address via EnableStatic().
    Falls back to New-NetIPAddress on return code 97 (DHCP already disabled, no existing IP).
#>
function Set-StaticIPViaCim {
    param(
        [int]$InterfaceIndex,
        [string]$IPAddress,
        [int]$PrefixLength
    )

    # Convert prefix length to dotted subnet mask (e.g. 24 -> "255.255.255.0")
    $maskInt = [uint32]0
    if ($PrefixLength -gt 0) {
        $maskInt = [uint32](([int64]1 -shl 32) - ([int64]1 -shl (32 - $PrefixLength)))
    }
    $SubnetMask = "{0}.{1}.{2}.{3}" -f (($maskInt -shr 24) -band 0xFF),
                                        (($maskInt -shr 16) -band 0xFF),
                                        (($maskInt -shr 8)  -band 0xFF),
                                        ($maskInt           -band 0xFF)

    $result = Invoke-CimMethodWithRetry -InterfaceIndex $InterfaceIndex -MethodName 'EnableStatic' -Arguments @{
        IPAddress  = @($IPAddress)
        SubnetMask = @($SubnetMask)
    }

    if ($result.ReturnValue -in @(0, 1)) {
        if ($result.ReturnValue -eq 1) {
            Write-Host "[Network configuration] EnableStatic succeeded but reports that a reboot is required"
        }
        return
    }

    if ($result.ReturnValue -eq 97) {
        Write-Host "[Network configuration] EnableStatic returned 97, falling back to New-NetIPAddress"
        # New-NetIPAddress adds an address, so drop the source ones to match EnableStatic's replace.
        # Both calls log a failure and carry on, the IP check at the end of Configure-Network decides.
        Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction Continue
        New-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -AddressFamily IPv4 -ErrorAction Continue
        return
    }

    throw "[Network configuration] EnableStatic failed with return code $($result.ReturnValue)"
}

<#
.SYNOPSIS
    Gets the IPv4 addresses on an interface, retrying on transient CIM errors.
.DESCRIPTION
    Get-NetIPAddress throws a terminating "no matching objects found" error when its CIM query
    matches nothing, regardless of $ErrorActionPreference. Right after DHCP/gateway/DNS changes
    the MSFT_NetIPAddress instance can briefly be unqueryable, so this retries like the other
    CIM calls in this file instead of letting a transient miss fail the whole NIC configuration.
    Retries up to 4 times with exponential backoff, mirroring Invoke-CimMethodWithRetry.
#>
function Get-NetIPAddressWithRetry {
    param(
        [string]$InterfaceAlias
    )

    $retryDelays = @(5, 10, 20, 40)
    $maxAttempts = $retryDelays.Length + 1
    $attempt     = 0

    while ($true) {
        $attempt++
        try {
            return @((Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction Stop).IPAddress)
        } catch {
            if ((Test-TransientCimError $_) -and ($attempt -lt $maxAttempts)) {
                $delay = $retryDelays[$attempt - 1]
                Write-Host "[Network configuration] Get-NetIPAddress threw a transient exception ($($_.FullyQualifiedErrorId)): $($_.Exception.Message). Retry $attempt/$($retryDelays.Length) in ${delay}s..."
                Start-Sleep -Seconds $delay
                continue
            }
            throw
        }
    }
}

<#
.SYNOPSIS
    Removes any IPv4 default route on the given interface from both the active and persistent stores.
.DESCRIPTION
    SetGateways() with an empty DefaultIPGateway array does not reliably remove the live
    0.0.0.0/0 route left by a previous run, so the route is deleted explicitly via Remove-NetRoute.
    Retries up to 4 times with exponential backoff on transient hardware-transition errors,
    mirroring Invoke-CimMethodWithRetry.
#>
function Remove-GatewayWithRetry {
    param(
        [int]$InterfaceIndex
    )

    $retryDelays = @(5, 10, 20, 40)
    $maxAttempts = $retryDelays.Length + 1
    $attempt     = 0

    while ($true) {
        $attempt++
        try {
            foreach ($store in @('ActiveStore', 'PersistentStore')) {
                # No matching route is not an error - SilentlyContinue on Get-NetRoute swallows ObjectNotFound.
                Get-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -PolicyStore $store -ErrorAction SilentlyContinue |
                    Remove-NetRoute -Confirm:$false -ErrorAction Stop
            }
            if ($attempt -gt 1) {
                Write-Host "[Network configuration] Remove-NetRoute succeeded on attempt $attempt"
            }
            return
        } catch {
            if ((Test-TransientCimError $_) -and ($attempt -lt $maxAttempts)) {
                $delay = $retryDelays[$attempt - 1]
                Write-Host "[Network configuration] Remove-NetRoute threw a transient exception ($($_.Exception.NativeErrorCode)/$($_.Exception.MessageId)): $($_.Exception.Message). Retry $attempt/$($retryDelays.Length) in ${delay}s..."
                Start-Sleep -Seconds $delay
                continue
            }
            throw
        }
    }
}

<#
.SYNOPSIS
    Sets the default gateway via Win32_NetworkAdapterConfiguration.SetGateways().
    Falls back to New-NetRoute on return code 97.
#>
function Set-GatewayViaCim {
    param(
        [int]$InterfaceIndex,
        [string]$DefaultGateway
    )

    $gwArgs = @{ DefaultIPGateway = [string[]]@($DefaultGateway); GatewayCostMetric = [uint16[]]@(1) }
    $result = Invoke-CimMethodWithRetry -InterfaceIndex $InterfaceIndex -MethodName 'SetGateways' -Arguments $gwArgs
    if ($result.ReturnValue -in @(0, 1)) {
        return
    }

    if ($result.ReturnValue -eq 97) {
        Write-Host "[Network configuration] SetGateways returned 97, falling back to New-NetRoute"
        # New-NetRoute fails when the route exists, so drop any leftover default route first.
        Remove-GatewayWithRetry -InterfaceIndex $InterfaceIndex
        New-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix '0.0.0.0/0' -NextHop $DefaultGateway -RouteMetric 1 -ErrorAction Stop | Out-Null
        return
    }

    throw "[Network configuration] SetGateways failed with return code $($result.ReturnValue)"
}

<#
.SYNOPSIS
    Waits for a network adapter to become accessible.
.DESCRIPTION
    Polls adapter every 200ms for up to 10 seconds (configurable).
#>
function Wait-AdapterAccessible {
    param(
        [string]$InterfaceAlias,
        [int]$MaxWaitSeconds = 10
    )
    $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $adapter = Get-NetAdapter -Name $InterfaceAlias -ErrorAction SilentlyContinue
        if ($adapter) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    throw "[Network configuration] Adapter $InterfaceAlias is not accessible after waiting $MaxWaitSeconds seconds"
}

function Configure-Network {
    param(
        [array]$Nics
    )

    if (-not $script:NetworkConfigPresent) {
        return
    }

    Write-Host "[Network configuration] Current network configuration:"
    ipconfig /all

    $adapterDisconnected = $false
    foreach ($nic in $Nics) {
        $TargetMac     = $nic.macAddress
        $CIDR          = $nic.ipAddress
        $NewGateway    = $nic.defaultGateway
        $NewDNSServers = $nic.dnsServers -split ','

        if ($CIDR -match '^(.+)/(\d+)$') {
            $NewIPv4     = $matches[1]
            $NewMaskBits = [int]$matches[2]
        }
        else {
            Report-NetworkResult -ExitCode 20 -Message "[Network configuration] Invalid CIDR format for NIC with MAC ${TargetMac}: $CIDR"
            return
        }

        try {
            # ─── Locate adapter by MAC address ────────────────────────────────────
            $macClean  = ($TargetMac -replace '[:-]', '').ToUpper()
            $adapter   = Get-NetAdapter -Physical | Where-Object {
                            (($_.MacAddress -replace '[:-]', '').ToUpper()) -eq $macClean
                         } | Select-Object -First 1

            if (-not $adapter) {
                Write-Warning "[Network configuration] No adapter with MAC $TargetMac found."
                continue
            }

            $alias = $adapter.Name
            Write-Host "[Network configuration] Configuring adapter: $alias (MAC $TargetMac)"

            # ─── Atomically disable DHCP and set static IPv4 ────────────────────
            Set-StaticIPViaCim -InterfaceIndex $adapter.InterfaceIndex `
                               -IPAddress      $NewIPv4 `
                               -PrefixLength   $NewMaskBits
            Write-Host "[Network configuration] Set static IP $NewIPv4/$NewMaskBits for $alias"

            # ─── Set or clear default gateway ───────────────────────────────────
            if ($NewGateway -and $NewGateway -ne '') {
                Set-GatewayViaCim -InterfaceIndex  $adapter.InterfaceIndex `
                                  -DefaultGateway  $NewGateway
                Write-Host "[Network configuration] Set gateway $NewGateway for $alias"
            } else {
                Remove-GatewayWithRetry -InterfaceIndex $adapter.InterfaceIndex
                Write-Host "[Network configuration] Cleared default gateway for $alias"
            }

            Wait-AdapterAccessible -InterfaceAlias $alias | Out-Null

            # ─── Configure DNS servers ─────────────────────────────────────────
            Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $NewDNSServers
            Write-Host "[Network configuration] Set DNS servers $NewDNSServers for $alias"

            Wait-AdapterAccessible -InterfaceAlias $alias | Out-Null

            # ─── Verify IP configuration ─────────────────────────────────────────
            # Any address other than the new one means a source address is still assigned.
            $ipAddresses = Get-NetIPAddressWithRetry -InterfaceAlias $alias
            Write-Host "[Network configuration] Verified IP configuration for $alias"
            if ($ipAddresses -ne $NewIPv4) {
                throw "[Network configuration] Setting of a new IP failed - $($ipAddresses -join ', ') vs $NewIPv4"
            }
            
            $adapter = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
            if (-not $adapter -or $adapter.Status -eq "Disconnected") {
                Write-Warning "[Network configuration] Adapter with MAC ${TargetMac} is disconnected"
                $adapterDisconnected = $true
                continue
            }

            Write-Host "[Network configuration] Finished configuring adapter: $alias"
        }
        catch {
            Report-NetworkResult -ExitCode 22 -Message "[Network configuration] Error configuring NIC with MAC ${TargetMac}: $($_.Exception.Message)"
            return
        }
    }

    # Flush freshly-applied settings to disk so they survive an immediate snapshot / re-protection.
    Invoke-NetworkRegistryFlush

    if ($adapterDisconnected) {
        Report-NetworkResult -ExitCode 23 -Message "[Network configuration] At least one adapter is disconnected"
        return
    }

    Report-NetworkResult -ExitCode 0 -Message "[Network configuration] Network configuration completed successfully"
}

<#
.SYNOPSIS
    Forces the kernel registry manager to flush dirty TCP/IP interface hive pages to disk so the
    freshly-applied network configuration survives an immediate snapshot / re-protection of the VM.
.DESCRIPTION
    Saving the Tcpip\Parameters\Interfaces key with `reg save` triggers a hive flush as a side
    effect; the temporary output file is discarded. Best-effort - failures are logged, not fatal.
#>
function Invoke-NetworkRegistryFlush {
    $tmpHive = Join-Path $env:TEMP "tcpip_flush_$(Get-Random).hiv"
    try {
        & reg save "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" $tmpHive /y 2>&1 | Out-Null
        Remove-Item $tmpHive -Force -ErrorAction SilentlyContinue
        Write-Host "[Network configuration] Registry hive flushed successfully"
    }
    catch {
        Write-Warning "[Network configuration] Registry hive flush failed: $($_.Exception.Message)"
    }
}

function Invoke-Reboot {
    param([string]$Reason = "Rebooting machine...")
    Write-Host $Reason
    shutdown.exe /r /t 5 /f
    Stop-Transcript | Out-Null
    exit 0
}

<#
.SYNOPSIS
    Returns $true when every target MAC already resolves to a physical adapter.
    This mirrors the lookup used by the NIC-configuration loop, so a $false result
    means that loop is about to fail with "No adapter with MAC ... found".
#>
function Test-TargetAdaptersHealthy {
    param(
        [array]$NicsParam
    )

    foreach ($nic in $NicsParam) {
        $macClean = ($nic.macAddress -replace '[:-]', '').ToUpper()
        $adapter  = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
                        (($_.MacAddress -replace '[:-]', '').ToUpper()) -eq $macClean
                    } | Select-Object -First 1
        if (-not $adapter) {
            Write-Host "No usable adapter found yet for MAC $($nic.macAddress)."
            return $false
        }
    }
    return $true
}


<#
.SYNOPSIS
    Returns $true only when there is positive evidence this guest was recently running on AWS
    (i.e. a V2AWS failback). This is the attribution gate that keeps the invasive netcfg -d
    remediation from ever firing on a VM that was never on AWS just because an adapter is faulted.
.DESCRIPTION
    Looks for durable AWS-provenance markers the AWS leg leaves behind on the disk:
      • an Amazon Elastic Network Adapter / ENA net device (Amazon PCI vendor id VEN_1D0F),
        present or phantom
      • AWS PV / EC2 guest agents and drivers (AWSLiteAgent, AmazonSSMAgent, Ec2Config, xennet, xenvbd)
      • AWS install directories under Program Files / ProgramData
    Teredo/ISATAP tunnel adapters are deliberately NOT used - they exist on stock Windows and carry
    no AWS provenance.
#>
function Test-AwsProvenance {
    $evidence = @()

    # AWS network devices (present or phantom). The ENA uses Amazon's PCI vendor id 1D0F.
    try {
        $awsNet = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object {
                      $_.FriendlyName -match 'Amazon|Elastic Network Adapter|AWS PV' -or
                      $_.InstanceId  -match 'VEN_1D0F'
                  }
        if ($awsNet) {
            $evidence += "net device(s): $((@($awsNet.FriendlyName) | Select-Object -Unique) -join ', ')"
        }
    }
    catch {
        Write-Warning "Get-PnpDevice query failed: $($_.Exception.Message)"
    }

    # AWS guest agents / PV drivers installed during the AWS leg.
    try {
        $awsSvc = Get-Service -ErrorAction SilentlyContinue | Where-Object {
                      $_.Name -in @('AWSLiteAgent', 'AmazonSSMAgent', 'Ec2Config', 'xennet', 'xenvbd')
                  }
        if ($awsSvc) {
            $evidence += "service(s): $((@($awsSvc.Name)) -join ', ')"
        }
    }
    catch { }

    # AWS install footprint on disk.
    foreach ($path in @("$env:ProgramFiles\Amazon", "$env:ProgramData\Amazon")) {
        if (Test-Path $path) {
            $evidence += "path: $path"
        }
    }

    if ($evidence.Count -gt 0) {
        Write-Host "AWS provenance detected -> $($evidence -join '; ')"
        return $true
    }

    Write-Host "No AWS provenance markers found."
    return $false
}


<#
.SYNOPSIS
    Returns $true when a VMware NIC (vmxnet3; VMware PCI vendor id VEN_15AD) is stuck in a
    device-manager error state such as CM_PROB_REGISTRY / Code 19 - the exact symptom this
    remediation repairs. Scoped to VMware devices so an unrelated VPN, filter, or virtual adapter
    in error does not qualify as the failback ghost-NIC situation.
#>
function Test-VmwareAdapterInError {
    try {
        $bad = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
                   $_.PNPClass -eq 'Net' -and
                   $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 -and
                   ($_.DeviceID -match 'VEN_15AD' -or $_.Name -match 'vmxnet|VMware')
               }
        if ($bad) {
            foreach ($d in $bad) {
                Write-Host "VMware net device in error state: $($d.Name) (ConfigManagerErrorCode $($d.ConfigManagerErrorCode))"
            }
            return $true
        }
    }
    catch {
        Write-Warning "Win32_PnPEntity query failed: $($_.Exception.Message)"
    }
    return $false
}


<#
.SYNOPSIS
    Runs the confirmed manual remediation for the AWS ghost-NIC failure: a device-console
    cleanup (netcfg -d) that removes ghost NICs and stale network bindings so the current
    vmxnet3 adapter can leave CM_PROB_REGISTRY and re-enumerate cleanly on the next boot.
    Non-present AWS/ghost devices are additionally removed via pnputil where supported
    (pnputil /remove-device is unavailable on Windows Server 2016, so it is skipped there
    and netcfg -d does the real work).
#>
function Repair-AwsGhostNetwork {
    Write-Host "Starting AWS ghost-network remediation..."

    # Best-effort targeted removal of ghost/AWS net devices (newer OS only).
    try {
        $pnputilHelp = & pnputil.exe /? 2>&1 | Out-String
        if ($pnputilHelp -match '/remove-device') {
            # Only AWS ghosts and the faulted VMware NIC - never an unrelated error-state adapter.
            $ghosts = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object {
                          $_.FriendlyName -match 'Amazon|Elastic Network Adapter|AWS PV' -or
                          $_.InstanceId  -match 'VEN_1D0F' -or
                          (($_.Status -eq 'Error') -and (($_.InstanceId -match 'VEN_15AD') -or ($_.FriendlyName -match 'vmxnet|VMware')))
                      }
            foreach ($g in $ghosts) {
                Write-Host "Removing net device: $($g.FriendlyName) [$($g.InstanceId)]"
                & pnputil.exe /remove-device "$($g.InstanceId)" 2>&1 | Out-Null
            }
        } else {
            Write-Host "pnputil /remove-device is not supported on this OS; relying on netcfg -d."
        }
    }
    catch {
        Write-Warning "pnputil device removal step failed (non-fatal): $($_.Exception.Message)"
    }

    # Core remediation: device-console cleanup of all network components.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = & netcfg.exe -d 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Host "netcfg -d succeeded:`n$out"
        } else {
            Write-Warning "netcfg -d returned exit code $($LASTEXITCODE):`n$out"
        }
    }
    catch {
        Write-Warning "netcfg -d failed to launch: $($_.Exception.Message)"
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}


<#
.SYNOPSIS
    Reads the number of remediation attempts recorded in the marker file (0 if absent).
#>
function Get-AwsCleanupAttempts {
    param(
        [String]$MarkerParam
    )

    if (Test-Path $MarkerParam) {
        $raw = (Get-Content $MarkerParam -ErrorAction SilentlyContinue | Select-Object -First 1)
        $n = 0
        if ([int]::TryParse($raw, [ref]$n)) { return $n }
    }
    return 0
}


<#
.SYNOPSIS
    Persists the remediation attempt count so a reboot loop cannot occur.
#>
function Set-AwsCleanupAttempts {
    param(
        [String]$MarkerParam,
        [int]$CountParam
    )

    Set-Content -Path $MarkerParam -Value $CountParam -Force
    # Flush to disk so the count survives the imminent reboot.
    try { & fsutil volume flush $env:SystemDrive 2>&1 | Out-Null } catch { }
}


<#
.SYNOPSIS
    Removes the remediation attempt marker so a future AWS failback on the same (possibly
    persistent) install path is not permanently skipped after the attempt budget was spent once.
#>
function Clear-AwsCleanupAttempts {
    param(
        [String]$MarkerParam
    )

    if (Test-Path $MarkerParam) {
        Remove-Item -Path $MarkerParam -Force -ErrorAction SilentlyContinue
        Write-Host "Cleared AWS remediation attempt marker."
    }
}


<#
.SYNOPSIS
    Detect-and-remediate orchestrator for the V2AWS-failback ghost-NIC failure. When no target MAC
    resolves to a usable adapter and AWS ghost devices are present, runs netcfg -d and reboots so
    the vmxnet3 adapter re-enumerates cleanly. Bounded by a marker file to prevent a boot loop.

    Requires the caller to have already registered an AtStartup task so this script re-runs after
    the reboot; it does not return when it reboots. Does nothing when the adapters are already
    healthy or the attempt cap has been reached.

    The remediation is gated on TWO conditions so it cannot fire on a non-AWS failure: there must be
    positive AWS provenance (Test-AwsProvenance) AND the faulted device must be the VMware NIC itself
    (Test-VmwareAdapterInError). An unrelated VPN/filter/virtual adapter in error, or a VM that was
    never on AWS, therefore never reaches netcfg -d.
#>
function Invoke-AwsGhostRemediationIfNeeded {
    param(
        [array]$Nics,
        [string]$MarkerPath,
        [int]$MaxAttempts = 1
    )

    if (Test-TargetAdaptersHealthy -NicsParam $Nics) {
        # Adapters are healthy - remediation either worked or was never needed. Clear any prior
        # attempt marker so a later, independent AWS failback on this persistent install path gets
        # a fresh remediation budget instead of being permanently skipped.
        Clear-AwsCleanupAttempts -MarkerParam $MarkerPath
        return
    }

    $attempts = Get-AwsCleanupAttempts -MarkerParam $MarkerPath
    if (($attempts -lt $MaxAttempts) -and (Test-AwsProvenance) -and (Test-VmwareAdapterInError)) {
        Write-Host "Target VMware NIC faulted and AWS provenance confirmed; remediating (attempt $($attempts + 1)/$MaxAttempts)."
        Set-AwsCleanupAttempts -MarkerParam $MarkerPath -CountParam ($attempts + 1)

        Repair-AwsGhostNetwork

        Invoke-Reboot -Reason "Rebooting so vmxnet3 can re-enumerate; the startup task will resume network configuration."
    }
    elseif ($attempts -ge $MaxAttempts) {
        Write-Warning "Target adapter(s) still not healthy after $attempts remediation attempt(s); not retrying to avoid a boot loop. Network configuration will proceed and likely fail."
    }
}

# ===========================================================================================
# Customer Script Execution
# ===========================================================================================
$script:CustomerScriptLogPath = Join-Path $script:InstallDir "post-failover-$($script:LogTimestampSuffix).log"

function Invoke-CustomerScript {
    Write-Host "[Customer Script] Checking if customer script should run"
    $shouldRun = Get-GuestInfo "customer.shouldRun"

    if ($shouldRun -ne "true") {
        Write-Host "[Customer Script] No customer script will be executed in this run (shouldRun=$shouldRun)"
        return
    }

    Write-Host "[Customer Script] Execution requested, checking for script at $($script:CustomerScriptPath)"

    if (-not (Test-Path -Path $script:CustomerScriptPath -PathType Leaf)) {
        Write-Host "[Customer Script] Script not found at $($script:CustomerScriptPath)"
        Set-GuestInfo "customer.exitCode" "19"
        Set-GuestInfo "customer.errorMessage" "Customer script not found at $($script:CustomerScriptPath)"
        Set-GuestInfo "customer.endTimestamp" ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))
        return
    }

    Write-Host "[Customer Script] Script found, starting execution"
    Write-Host "[Customer Script] Output will be logged to $script:CustomerScriptLogPath"

    # Record start timestamp
    Set-GuestInfo "customer.startTimestamp" ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))

    # Execute customer script in a separate process
    $process = Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($script:CustomerScriptPath)`"" `
        -RedirectStandardOutput $script:CustomerScriptLogPath `
        -RedirectStandardError "$($script:CustomerScriptLogPath).err" `
        -NoNewWindow -PassThru -Wait

    $scriptExitCode = $process.ExitCode
    Write-Host "[Customer Script] Process exited with code $scriptExitCode"

    # Capture stderr content if present
    $stderrPath = "$($script:CustomerScriptLogPath).err"
    $stderrContent = $null
    if ((Test-Path $stderrPath) -and ((Get-Item $stderrPath).Length -gt 0)) {
        Write-Host "[Customer Script] Stderr output detected, appending to log"
        $stderrContent = Get-Content $stderrPath -Raw
        Add-Content -Path $script:CustomerScriptLogPath -Value "`n--- STDERR ---"
        Add-Content -Path $script:CustomerScriptLogPath -Value $stderrContent
    }
    Remove-Item $stderrPath -Force -ErrorAction SilentlyContinue

    # Record end timestamp
    Set-GuestInfo "customer.endTimestamp" ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))

    # Report results
    if ($scriptExitCode -eq 0) {
        Write-Host "[Customer Script] Execution completed successfully"
        Set-GuestInfo "customer.exitCode" "0"
        # Report stderr as error message even on success
        if ($stderrContent) {
            Write-Host "[Customer Script] Warning: stderr output detected despite successful exit code"
            Set-GuestInfo "customer.errorMessage" $stderrContent
        }
    }
    else {
        Write-Host "[Customer Script] Execution failed with exit code $scriptExitCode. Check log at $script:CustomerScriptLogPath"
        Set-GuestInfo "customer.exitCode" "$scriptExitCode"
        if ($stderrContent) {
            Set-GuestInfo "customer.errorMessage" $stderrContent
        } else {
            Set-GuestInfo "customer.errorMessage" "Customer script failed with exit code $scriptExitCode. Check log at $script:CustomerScriptLogPath"
        }
    }

}


# Entry point
Write-Host "Script version: $script:ScriptVersion"
Remove-OldLogFiles
Test-PowerShellVersion
# `--uninstall` (or `-Uninstall`) reverses installation: removes the scheduled task and its task
# folder, clears all guest-info properties, and deletes the installed script and logs (the install
# directory is preserved if it holds a customer script). Best-effort and Administrator-only; it
# proceeds even when VMware Tools is missing.
if ($Uninstall) {
    # Silence VMware Tools health checks and guest-info RPC errors so missing/unhealthy tools
    # cannot abort local cleanup.
    $script:UninstallInProgress = $true
    Test-AdminPrivileges
    Invoke-Uninstall
    exit 0
}
Initialize-ExecutionTracking
Test-AdminPrivileges
Invoke-Installation
Report-CustomerScriptExistence
$nics = @(Get-NicData)
# On a V2AWS failback, older Windows can come back with the vmxnet3 adapter stuck in
# CM_PROB_REGISTRY behind AWS ghost devices. When network config is present but no target
# adapter is healthy, clean up (netcfg -d) and reboot; the scheduled task resumes afterwards.
if ($script:NetworkConfigPresent) {
    Invoke-AwsGhostRemediationIfNeeded -Nics $nics -MarkerPath (Join-Path $script:InstallDir 'aws-network-cleanup.attempts') -MaxAttempts 1
}
Configure-Network -Nics $nics
Invoke-CustomerScript
Complete-Execution
