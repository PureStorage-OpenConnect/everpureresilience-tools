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

$script:ScriptVersion = "2.8.0"
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
    Returns $true when the given return code or HRESULT is a transient error worth retrying.
#>
function Test-TransientCimError {
    param([int64]$Code)
    $normalized = $Code -band [int64]0xFFFFFFFF

    # These are not inherently transient, but in this context the CIM object was just found
    # moments before - so "not found" means the device is mid-transition, not permanently gone.
    $transientCodes = @(
        [int64]2147943568   # 0x80070490 = HRESULT wrapping Win32 ERROR_NOT_FOUND (1168)
        [int64]2147749890   # 0x80041002 = WBEM_E_NOT_FOUND
        [int64]2147749897   # 0x80041009 = WBEM_E_NOT_AVAILABLE
        [int64]2147749939   # 0x80041033 = WBEM_E_SHUTTING_DOWN (e.g. VMware Tools upgrade)
        [int64]2147749993   # 0x80041069 = WBEM_E_TIMED_OUT
        [int64]2147750024   # 0x80041088 = WBEM_E_PROVIDER_TIMED_OUT
    )
    return $normalized -in $transientCodes
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
            $hr = $cimError.Exception.HResult
            if ((Test-TransientCimError $hr) -and ($attempt -lt $maxAttempts)) {
                $delay = $retryDelays[$attempt - 1]
                Write-Host "[Network configuration] $MethodName threw a transient exception ($hr): $($cimError.Exception.Message). Retry $attempt/$($retryDelays.Length) in ${delay}s..."
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
        if ((Test-TransientCimError $result.ReturnValue) -and ($attempt -lt $maxAttempts)) {
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
        return
    }

    if ($result.ReturnValue -eq 97) {
        # DHCP already disabled, no existing IP
        Write-Host "[Network configuration] EnableStatic returned 97, falling back to New-NetIPAddress"
        New-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -AddressFamily IPv4 -ErrorAction Stop
        return
    }

    throw "[Network configuration] EnableStatic failed with return code $($result.ReturnValue)"
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
            $hr = $_.Exception.HResult
            if ((Test-TransientCimError $hr) -and ($attempt -lt $maxAttempts)) {
                $delay = $retryDelays[$attempt - 1]
                Write-Host "[Network configuration] Remove-NetRoute threw a transient exception ($hr): $($_.Exception.Message). Retry $attempt/$($retryDelays.Length) in ${delay}s..."
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
#>
function Set-GatewayViaCim {
    param(
        [int]$InterfaceIndex,
        [string]$DefaultGateway
    )

    $gwArgs = @{ DefaultIPGateway = [string[]]@($DefaultGateway); GatewayCostMetric = [uint16[]]@(1) }
    $result = Invoke-CimMethodWithRetry -InterfaceIndex $InterfaceIndex -MethodName 'SetGateways' -Arguments $gwArgs
    if ($result.ReturnValue -notin @(0, 1)) {
        throw "[Network configuration] SetGateways failed with return code $($result.ReturnValue)"
    }
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
    $nics = @(Get-NicData)

    if (-not $script:NetworkConfigPresent) {
        return
    }

    Write-Host "[Network configuration] Current network configuration:"
    ipconfig /all

    $adapterDisconnected = $false
    foreach ($nic in $nics) {
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
            $ipAddress = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4
            Write-Host "[Network configuration] Verified IP configuration for $alias"
            if ($ipAddress.IPAddress -ne $NewIPv4) {
                throw "[Network configuration] Setting of a new IP failed - " + $ipAddress.IPAddress + " vs $NewIPv4"
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

    if ($adapterDisconnected) {
        Report-NetworkResult -ExitCode 23 -Message "[Network configuration] At least one adapter is disconnected"
        return
    }

    Report-NetworkResult -ExitCode 0 -Message "[Network configuration] Network configuration completed successfully"
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
Configure-Network
Invoke-CustomerScript
Complete-Execution

# SIG # Begin signature block
# MIIobQYJKoZIhvcNAQcCoIIoXjCCKFoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCpgN5kafPFlsVq
# uIhJETUuNgGTrcotTdWnYfgXN4m+rKCCDaIwggawMIIEmKADAgECAhAIrUCyYNKc
# TJ9ezam9k67ZMA0GCSqGSIb3DQEBDAUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNV
# BAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAeFw0yMTA0MjkwMDAwMDBaFw0z
# NjA0MjgyMzU5NTlaMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcg
# UlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQDVtC9C0CiteLdd1TlZG7GIQvUzjOs9gZdwxbvEhSYwn6SOaNhc9es0
# JAfhS0/TeEP0F9ce2vnS1WcaUk8OoVf8iJnBkcyBAz5NcCRks43iCH00fUyAVxJr
# Q5qZ8sU7H/Lvy0daE6ZMswEgJfMQ04uy+wjwiuCdCcBlp/qYgEk1hz1RGeiQIXhF
# LqGfLOEYwhrMxe6TSXBCMo/7xuoc82VokaJNTIIRSFJo3hC9FFdd6BgTZcV/sk+F
# LEikVoQ11vkunKoAFdE3/hoGlMJ8yOobMubKwvSnowMOdKWvObarYBLj6Na59zHh
# 3K3kGKDYwSNHR7OhD26jq22YBoMbt2pnLdK9RBqSEIGPsDsJ18ebMlrC/2pgVItJ
# wZPt4bRc4G/rJvmM1bL5OBDm6s6R9b7T+2+TYTRcvJNFKIM2KmYoX7BzzosmJQay
# g9Rc9hUZTO1i4F4z8ujo7AqnsAMrkbI2eb73rQgedaZlzLvjSFDzd5Ea/ttQokbI
# YViY9XwCFjyDKK05huzUtw1T0PhH5nUwjewwk3YUpltLXXRhTT8SkXbev1jLchAp
# QfDVxW0mdmgRQRNYmtwmKwH0iU1Z23jPgUo+QEdfyYFQc4UQIyFZYIpkVMHMIRro
# OBl8ZhzNeDhFMJlP/2NPTLuqDQhTQXxYPUez+rbsjDIJAsxsPAxWEQIDAQABo4IB
# WTCCAVUwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUaDfg67Y7+F8Rhvv+
# YXsIiGX0TkIwHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0P
# AQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMHcGCCsGAQUFBwEBBGswaTAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAC
# hjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9v
# dEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAcBgNVHSAEFTATMAcGBWeBDAED
# MAgGBmeBDAEEATANBgkqhkiG9w0BAQwFAAOCAgEAOiNEPY0Idu6PvDqZ01bgAhql
# +Eg08yy25nRm95RysQDKr2wwJxMSnpBEn0v9nqN8JtU3vDpdSG2V1T9J9Ce7FoFF
# UP2cvbaF4HZ+N3HLIvdaqpDP9ZNq4+sg0dVQeYiaiorBtr2hSBh+3NiAGhEZGM1h
# mYFW9snjdufE5BtfQ/g+lP92OT2e1JnPSt0o618moZVYSNUa/tcnP/2Q0XaG3Ryw
# YFzzDaju4ImhvTnhOE7abrs2nfvlIVNaw8rpavGiPttDuDPITzgUkpn13c5Ubdld
# AhQfQDN8A+KVssIhdXNSy0bYxDQcoqVLjc1vdjcshT8azibpGL6QB7BDf5WIIIJw
# 8MzK7/0pNVwfiThV9zeKiwmhywvpMRr/LhlcOXHhvpynCgbWJme3kuZOX956rEnP
# LqR0kq3bPKSchh/jwVYbKyP/j7XqiHtwa+aguv06P0WmxOgWkVKLQcBIhEuWTatE
# QOON8BUozu3xGFYHKi8QxAwIZDwzj64ojDzLj4gLDb879M4ee47vtevLt/B3E+bn
# KD+sEq6lLyJsQfmCXBVmzGwOysWGw/YmMwwHS6DTBwJqakAwSEs0qFEgu60bhQji
# WQ1tygVQK+pKHJ6l/aCnHwZ05/LWUpD9r4VIIflXO7ScA+2GRfS0YW6/aOImYIbq
# yK+p/pQd52MbOoZWeE4wggbqMIIE0qADAgECAhAIPjRpjH9bCQy1JthFZIh9MA0G
# CSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcg
# UlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwHhcNMjYwMjI0MDAwMDAwWhcNMjcwNTI4
# MjM1OTU5WjByMQswCQYDVQQGEwJVUzETMBEGA1UECBMKQ2FsaWZvcm5pYTEUMBIG
# A1UEBxMLU2FudGEgQ2xhcmExGzAZBgNVBAoTElB1cmUgU3RvcmFnZSwgSW5jLjEb
# MBkGA1UEAxMSUHVyZSBTdG9yYWdlLCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOC
# AY8AMIIBigKCAYEA4xwJviabs6uQveruozp6wXyuolQ+jg0OA/gqVxRob6Byypq8
# 2b2Y0QQXqm4qJoGCqDP16pYi7qrhwxNvF8+I+CWZbZFzvphuZ/CuV/y3hnETuoNE
# xqwoIxfQZWyGO0+asQ2s0SjnZrLCRYrilKdpBFbyq5N9MFGFRw/Tzs4uM8qKqPYZ
# i9PfpFRGVqE+L0FfOLHDpAN2YdxfvyP4rgUBxJK+m7LWFq+Nafxk/gSLV0fQTmLK
# eTuEpm3tIrQQWArY0aw7/fRpar3Qtyhzbt8AR6EVI9h1orvNyHXMWmGZlhWY9XNt
# n1bWn7jwiqaxsBPBCvlZ9yt5LQMpxdtEhSV1fJNmtJJTn3h+kbRopfAfw5+kNwM1
# 7HRnYXOUKgaxCxcH03/9oU6WSoX06BN0Ooei5WmVBVz3V6Nv/pM9B7X5j+x99uFq
# JIXogYuYM2jtP3zRFcqDjvSqBUYn6SgsXF7C84QTRaVESX+HegJD78OWzQFZ9Yov
# WynDzBsXgT0e9mnFAgMBAAGjggIDMIIB/zAfBgNVHSMEGDAWgBRoN+Drtjv4XxGG
# +/5hewiIZfROQjAdBgNVHQ4EFgQULw/ffZ/EI7AYJp4t2dycLBH36L0wPgYDVR0g
# BDcwNTAzBgZngQwBBAEwKTAnBggrBgEFBQcCARYbaHR0cDovL3d3dy5kaWdpY2Vy
# dC5jb20vQ1BTMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAzCB
# tQYDVR0fBIGtMIGqMFOgUaBPhk1odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGln
# aUNlcnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNy
# bDBToFGgT4ZNaHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3Rl
# ZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcmwwgZQGCCsGAQUF
# BwEBBIGHMIGEMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20w
# XAYIKwYBBQUHMAKGUGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2Vy
# dFRydXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEuY3J0MAkG
# A1UdEwQCMAAwDQYJKoZIhvcNAQELBQADggIBAJcvpRhA3k1gD5cjmgLzlZd+kPHH
# AraHt5SgGYjvM5LctB4vkKmhJow+44+WL4t2jACc1Ht4kbvELlNO0NQvjylzoUEe
# sdDt008pPBuNx3EhEkclgsn4uoRAYQ3mHi/ypM/0hJYalzwBAR9eebdNrofVZlbt
# OjYKWJGKq3aoQTIKXKZUGHxxFR1LNSKcgLjCYqDaWrh3Fav2Aft0+wwViOUJb45N
# r2sGA7af6EqKw2RklVoouSVEikhi9mXZRnusIVcJJmwK6Oq0WlsPtwoPsl8xqElp
# 7Xy7hXs7XkPPHcwdGP3j8fM+qkwmTUvqcMXdG8aCToCFdBlRKt4/Fl7TvaSZBCym
# CoKBdqZXpKCSLvjbmo3FPq6JO+i5YZoYhZQZt8C7uI/COEZqFDpRUBTNvWVicAId
# LUtgR7426LAM3eM9m6uI6vnCVTYyy9n203ygArw7wGU86pwQQ4CaB1vXknhZTEjY
# SPMn2daiJtdq8vhEUXjF69NkQM/M+b6sOKKtBlKq7mWqCqQ0nevv0hp53XTbm572
# GI9RMVkNAvmBWvCN23pLaLRcwUR7JEJ8lK98Q3wJJxmaYFz/DkNWAqcYapy5Ggk2
# AHScSoz6hzh3svILb1y2h+S34oY9pRuTCa0vvLvdy5o6lxcMn+g/i1n504t3H3DR
# TPtRuWlIfaW6PtqHMYIaITCCGh0CAQEwfTBpMQswCQYDVQQGEwJVUzEXMBUGA1UE
# ChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQg
# Q29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExAhAIPjRpjH9bCQy1
# JthFZIh9MA0GCWCGSAFlAwQCAQUAoHwwEAYKKwYBBAGCNwIBDDECMAAwGQYJKoZI
# hvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcC
# ARUwLwYJKoZIhvcNAQkEMSIEIM9mV+bYGrDJl1djiM1BsqnNRjM/MxScUQFUZ9/u
# qv8ZMA0GCSqGSIb3DQEBAQUABIIBgHljLK+5Dk5VDjFyh+OQnK8HuQbfn62bQWbE
# h+MR/9tqc22Er0X+ABW6SP4EgFMminJreioOS9O/nLIwGyDSVey417ZXYz1/cfeY
# pDnIAwpH93EcP3B77w0FBlSvE/Q+CLvCMZZaGZ3Ab5VbaK4thGGsOCZVsoJerQ3u
# atYu4mEFawfTyYYVhrHDB8NlRfX7WESHVsAyiqg9aL3lGYaBlvZqhvIE89p69Tps
# QIMsf3PxxQpYLnxxOIWmLFYG0jvT8SdjNJOBeO5ivGmhvuet0FxvpgBh9F3nmju+
# LnLcxoB8yYXKojGeqMZ4xQSJyDX7aMPPrbXCwGXrZTn6BQF7Y9bQZXt3xMNOXpF3
# EG+5Hu89gtLfLkdJIzx1n+pJLx9pJRvN7ht7rI80XXSQBbTEYOZbEtExScDmqqEn
# x7M5ueWMtzSHAOwAQVYwawZninEvIoYJ9uDzZ/oEQHCnWu2n20/XveBG5kS3MOSd
# 9eiZMq8/4RRNh5Qc+Js+KL/bD6+m5KGCF3cwghdzBgorBgEEAYI3AwMBMYIXYzCC
# F18GCSqGSIb3DQEHAqCCF1AwghdMAgEDMQ8wDQYJYIZIAWUDBAIBBQAweAYLKoZI
# hvcNAQkQAQSgaQRnMGUCAQEGCWCGSAGG/WwHATAxMA0GCWCGSAFlAwQCAQUABCBR
# /lhGoitsAeHelLeTwW7omJxRyYjbvo36azfdiDS03wIRAPa8S3CkwzrHOqpzehW2
# EZ4YDzIwMjYwNzE0MDcyNjQ0WqCCEzowggbtMIIE1aADAgECAhAKgO8YS43xBYLR
# xHanlXRoMA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwHhcNMjUwNjA0MDAwMDAw
# WhcNMzYwOTAzMjM1OTU5WjBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNl
# cnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFNIQTI1NiBSU0E0MDk2IFRpbWVz
# dGFtcCBSZXNwb25kZXIgMjAyNSAxMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEA0EasLRLGntDqrmBWsytXum9R/4ZwCgHfyjfMGUIwYzKomd8U1nH7C8Dr
# 0cVMF3BsfAFI54um8+dnxk36+jx0Tb+k+87H9WPxNyFPJIDZHhAqlUPt281mHrBb
# ZHqRK71Em3/hCGC5KyyneqiZ7syvFXJ9A72wzHpkBaMUNg7MOLxI6E9RaUueHTQK
# WXymOtRwJXcrcTTPPT2V1D/+cFllESviH8YjoPFvZSjKs3SKO1QNUdFd2adw44wD
# cKgH+JRJE5Qg0NP3yiSyi5MxgU6cehGHr7zou1znOM8odbkqoK+lJ25LCHBSai25
# CFyD23DZgPfDrJJJK77epTwMP6eKA0kWa3osAe8fcpK40uhktzUd/Yk0xUvhDU6l
# vJukx7jphx40DQt82yepyekl4i0r8OEps/FNO4ahfvAk12hE5FVs9HVVWcO5J4dV
# mVzix4A77p3awLbr89A90/nWGjXMGn7FQhmSlIUDy9Z2hSgctaepZTd0ILIUbWuh
# KuAeNIeWrzHKYueMJtItnj2Q+aTyLLKLM0MheP/9w6CtjuuVHJOVoIJ/DtpJRE7C
# e7vMRHoRon4CWIvuiNN1Lk9Y+xZ66lazs2kKFSTnnkrT3pXWETTJkhd76CIDBbTR
# ofOsNyEhzZtCGmnQigpFHti58CSmvEyJcAlDVcKacJ+A9/z7eacCAwEAAaOCAZUw
# ggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFOQ7/PIx7f391/ORcWMZUEPPYYzo
# MB8GA1UdIwQYMBaAFO9vU0rp5AZ8esrikFb2L9RJ7MtOMA4GA1UdDwEB/wQEAwIH
# gDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCBlQYIKwYBBQUHAQEEgYgwgYUwJAYI
# KwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBdBggrBgEFBQcwAoZR
# aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0VGlt
# ZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3J0MF8GA1UdHwRYMFYwVKBS
# oFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRp
# bWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNybDAgBgNVHSAEGTAXMAgG
# BmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQADggIBAGUqrfEcJwS5
# rmBB7NEIRJ5jQHIh+OT2Ik/bNYulCrVvhREafBYF0RkP2AGr181o2YWPoSHz9iZE
# N/FPsLSTwVQWo2H62yGBvg7ouCODwrx6ULj6hYKqdT8wv2UV+Kbz/3ImZlJ7YXwB
# D9R0oU62PtgxOao872bOySCILdBghQ/ZLcdC8cbUUO75ZSpbh1oipOhcUT8lD8QA
# GB9lctZTTOJM3pHfKBAEcxQFoHlt2s9sXoxFizTeHihsQyfFg5fxUFEp7W42fNBV
# N4ueLaceRf9Cq9ec1v5iQMWTFQa0xNqItH3CPFTG7aEQJmmrJTV3Qhtfparz+BW6
# 0OiMEgV5GWoBy4RVPRwqxv7Mk0Sy4QHs7v9y69NBqycz0BZwhB9WOfOu/CIJnzkQ
# TwtSSpGGhLdjnQ4eBpjtP+XB3pQCtv4E5UCSDag6+iX8MmB10nfldPF9SVD7weCC
# 3yXZi/uuhqdwkgVxuiMFzGVFwYbQsiGnoa9F5AaAyBjFBtXVLcKtapnMG3VH3EmA
# p/jsJ3FVF3+d1SVDTmjFjLbNFZUWMXuZyvgLfgyPehwJVxwC+UpX2MSey2ueIu9T
# HFVkT+um1vshETaWyQo8gmBto/m3acaP9QsuLj3FNwFlTxq25+T4QwX9xa6ILs84
# ZPvmpovq90K8eWyG2N01c4IhSOxqt81nMIIGtDCCBJygAwIBAgIQDcesVwX/IZku
# QEMiDDpJhjANBgkqhkiG9w0BAQsFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMM
# RGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQD
# ExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcNMjUwNTA3MDAwMDAwWhcNMzgw
# MTE0MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIElu
# Yy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJT
# QTQwOTYgU0hBMjU2IDIwMjUgQ0ExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAtHgx0wqYQXK+PEbAHKx126NGaHS0URedTa2NDZS1mZaDLFTtQ2oRjzUX
# MmxCqvkbsDpz4aH+qbxeLho8I6jY3xL1IusLopuW2qftJYJaDNs1+JH7Z+QdSKWM
# 06qchUP+AbdJgMQB3h2DZ0Mal5kYp77jYMVQXSZH++0trj6Ao+xh/AS7sQRuQL37
# QXbDhAktVJMQbzIBHYJBYgzWIjk8eDrYhXDEpKk7RdoX0M980EpLtlrNyHw0Xm+n
# t5pnYJU3Gmq6bNMI1I7Gb5IBZK4ivbVCiZv7PNBYqHEpNVWC2ZQ8BbfnFRQVESYO
# szFI2Wv82wnJRfN20VRS3hpLgIR4hjzL0hpoYGk81coWJ+KdPvMvaB0WkE/2qHxJ
# 0ucS638ZxqU14lDnki7CcoKCz6eum5A19WZQHkqUJfdkDjHkccpL6uoG8pbF0LJA
# QQZxst7VvwDDjAmSFTUms+wV/FbWBqi7fTJnjq3hj0XbQcd8hjj/q8d6ylgxCZSK
# i17yVp2NL+cnT6Toy+rN+nM8M7LnLqCrO2JP3oW//1sfuZDKiDEb1AQ8es9Xr/u6
# bDTnYCTKIsDq1BtmXUqEG1NqzJKS4kOmxkYp2WyODi7vQTCBZtVFJfVZ3j7OgWmn
# hFr4yUozZtqgPrHRVHhGNKlYzyjlroPxul+bgIspzOwbtmsgY1MCAwEAAaOCAV0w
# ggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFO9vU0rp5AZ8esrikFb2
# L9RJ7MtOMB8GA1UdIwQYMBaAFOzX44LScV1kTN8uZz/nupiuHA9PMA4GA1UdDwEB
# /wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3BggrBgEFBQcBAQRrMGkwJAYI
# KwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcwAoY1
# aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RH
# NC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybDMuZGlnaWNlcnQuY29t
# L0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIw
# CwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQAXzvsWgBz+Bz0RdnEwvb4L
# yLU0pn/N0IfFiBowf0/Dm1wGc/Do7oVMY2mhXZXjDNJQa8j00DNqhCT3t+s8G0iP
# 5kvN2n7Jd2E4/iEIUBO41P5F448rSYJ59Ib61eoalhnd6ywFLerycvZTAz40y8S4
# F3/a+Z1jEMK/DMm/axFSgoR8n6c3nuZB9BfBwAQYK9FHaoq2e26MHvVY9gCDA/JY
# sq7pGdogP8HRtrYfctSLANEBfHU16r3J05qX3kId+ZOczgj5kjatVB+NdADVZKON
# /gnZruMvNYY2o1f4MXRJDMdTSlOLh0HCn2cQLwQCqjFbqrXuvTPSegOOzr4EWj7P
# tspIHBldNE2K9i697cvaiIo2p61Ed2p8xMJb82Yosn0z4y25xUbI7GIN/TpVfHIq
# Q6Ku/qjTY6hc3hsXMrS+U0yy+GWqAXam4ToWd2UQ1KYT70kZjE4YtL8Pbzg0c1ug
# MZyZZd/BdHLiRu7hAWE6bTEm4XYRkA6Tl4KSFLFk43esaUeqGkH/wyW4N7Oigizw
# JWeukcyIPbAvjSabnf7+Pu0VrFgoiovRDiyx3zEdmcif/sYQsfch28bZeUz2rtY/
# 9TCA6TD8dC3JE3rYkrhLULy7Dc90G6e8BlqmyIjlgp2+VqsS9/wQD7yFylIz0scm
# bKvFoW2jNrbM1pD2T7m3XDCCBY0wggR1oAMCAQICEA6bGI750C3n79tQ4ghAGFow
# DQYJKoZIhvcNAQEMBQAwZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0
# IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNl
# cnQgQXNzdXJlZCBJRCBSb290IENBMB4XDTIyMDgwMTAwMDAwMFoXDTMxMTEwOTIz
# NTk1OVowYjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcG
# A1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3Rl
# ZCBSb290IEc0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv+aQc2je
# u+RdSjwwIjBpM+zCpyUuySE98orYWcLhKac9WKt2ms2uexuEDcQwH/MbpDgW61bG
# l20dq7J58soR0uRf1gU8Ug9SH8aeFaV+vp+pVxZZVXKvaJNwwrK6dZlqczKU0RBE
# EC7fgvMHhOZ0O21x4i0MG+4g1ckgHWMpLc7sXk7Ik/ghYZs06wXGXuxbGrzryc/N
# rDRAX7F6Zu53yEioZldXn1RYjgwrt0+nMNlW7sp7XeOtyU9e5TXnMcvak17cjo+A
# 2raRmECQecN4x7axxLVqGDgDEI3Y1DekLgV9iPWCPhCRcKtVgkEy19sEcypukQF8
# IUzUvK4bA3VdeGbZOjFEmjNAvwjXWkmkwuapoGfdpCe8oU85tRFYF/ckXEaPZPfB
# aYh2mHY9WV1CdoeJl2l6SPDgohIbZpp0yt5LHucOY67m1O+SkjqePdwA5EUlibaa
# RBkrfsCUtNJhbesz2cXfSwQAzH0clcOP9yGyshG3u3/y1YxwLEFgqrFjGESVGnZi
# fvaAsPvoZKYz0YkH4b235kOkGLimdwHhD5QMIR2yVCkliWzlDlJRR3S+Jqy2QXXe
# eqxfjT/JvNNBERJb5RBQ6zHFynIWIgnffEx1P2PsIV/EIFFrb7GrhotPwtZFX50g
# /KEexcCPorF+CiaZ9eRpL5gdLfXZqbId5RsCAwEAAaOCATowggE2MA8GA1UdEwEB
# /wQFMAMBAf8wHQYDVR0OBBYEFOzX44LScV1kTN8uZz/nupiuHA9PMB8GA1UdIwQY
# MBaAFEXroq/0ksuCMS1Ri6enIZ3zbcgPMA4GA1UdDwEB/wQEAwIBhjB5BggrBgEF
# BQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBD
# BggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# QXNzdXJlZElEUm9vdENBLmNydDBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMBEGA1Ud
# IAQKMAgwBgYEVR0gADANBgkqhkiG9w0BAQwFAAOCAQEAcKC/Q1xV5zhfoKN0Gz22
# Ftf3v1cHvZqsoYcs7IVeqRq7IviHGmlUIu2kiHdtvRoU9BNKei8ttzjv9P+Aufih
# 9/Jy3iS8UgPITtAq3votVs/59PesMHqai7Je1M/RQ0SbQyHrlnKhSLSZy51PpwYD
# E3cnRNTnf+hZqPC/Lwum6fI0POz3A8eHqNJMQBk1RmppVLC4oVaO7KTVPeix3P0c
# 2PR3WlxUjG/voVA9/HYJaISfb8rbII01YBwCA8sgsKxYoA5AY8WYIsGyWfVVa88n
# q2x2zm8jLfR+cWojayL/ErhULSd+2DrZ8LaHlv1b0VysGMNNn3O3AamfV6peKOK5
# lDGCA3wwggN4AgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKCB0TAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwHAYJKoZI
# hvcNAQkFMQ8XDTI2MDcxNDA3MjY0NFowKwYLKoZIhvcNAQkQAgwxHDAaMBgwFgQU
# 3WIwrIYKLTBr2jixaHlSMAf7QX4wLwYJKoZIhvcNAQkEMSIEIKu/abfT6h/j3GIi
# MRXOLNLnQcQzCIefeDrbm5CqiCK1MDcGCyqGSIb3DQEJEAIvMSgwJjAkMCIEIEqg
# P6Is11yExVyTj4KOZ2ucrsqzP+NtJpqjNPFGEQozMA0GCSqGSIb3DQEBAQUABIIC
# ACYFE62Q24ifDRbLHZw/cxlT0fTJHj85ToWfpKzuIsaJMSjgzMHICb1XYT4GT4v4
# SQsqAy0Zu+xNOwrWJtHpSw8hVNgt2aTvpgqI4jRBvQ6jlRo1p62tU+sDBI3TjuNn
# DkIkdk0i/vBWptMTWbSOIyEty6uOByTBqbx9il3FA59y7tD4KwqpSq9a8lAgoa1J
# kYwQF8DUdlXmEQdqx1NLMQXXJFZnnw9J43cVJtHhRY2UYY9kx8uUju0uld5ouLTH
# 7UkCxiXdFNM9G7Ikl0+Uj/pl3nJV1TN4wuqrcl4R59zbSysNRi/JE82KORJuh9NB
# pUX25b6w4KVaQFOJydeztz6a85TG9vSecQfwsrgqRw6XrETDZhTDc+ZuDhNX++RN
# 1o9xBbQ8gZnuKdy3Npdkfi7zRLi/Jbu9NgQa2UWNRptromf7opddZ2ffXM9BlJoZ
# TnuxZBZPSPu7K85wVKVtZg1f1uXEEDjeiIQedIGQGp+6qoQ/u7yPux22u+XvWM0r
# kE3GKJwN18Kshrj+h/WFMr6w4d+1OTG76x7sE9Uw5JBCw8iJo06+hd3dNHJF6cxh
# mhwZdMsXkmtI8ogRtTq+zVYHtzYB60xn2C8UZogCsMCRR/iWSmHvtYurfa5tvApX
# xxoQjVeF3/XEIY9sTl4TaB5QM9yum3yLyEEhx5mzoxFN
# SIG # End signature block
