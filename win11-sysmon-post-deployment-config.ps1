#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$sysmonDir = 'C:\ProgramData\Sysmon'
$sysmonConfigPath = Join-Path $sysmonDir 'sysmonConfig.xml'
$pendingRestartPath = Join-Path $sysmonDir 'pending-restart.txt'
$sysinternalsDir = 'C:\Tools\Sysinternals'
$serviceFilter = "Name = 'Sysmon' OR Name = 'Sysmon64'"

# Balanced Sysmon Modular configuration and its published SHA-256.
$configUri = 'https://github.com/olafhartong/sysmon-modular/releases/download/configs-a45dedb13a43/sysmonconfig.xml'
$configSha256 = '64bec37ba849c5f2934a55d2a29e7ddfae46a30d56f7f2908d1f8a454898797e'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$bootStamp = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks
$services = @(Get-CimInstance -ClassName Win32_Service -Filter $serviceFilter)
if ($services.Count -eq 0) {
    $nativeFeature = Get-WindowsOptionalFeature -Online | Where-Object FeatureName -eq 'Sysmon'
    if (-not $nativeFeature) {
        throw 'This Windows image does not offer the built-in Sysmon feature.'
    }
    if ($nativeFeature.State -in 'EnablePending', 'DisablePending') {
        throw "Built-in Sysmon is in state '$($nativeFeature.State)'. Restart Windows and rerun the extension."
    }

    # Standalone Sysmon extracts its service binary to the Windows installation directory.
    $standaloneRemnants = @('Sysmon.exe', 'Sysmon64.exe', 'Sysmon64a.exe' | ForEach-Object {
        $path = Join-Path $env:SystemRoot $_
        if (Test-Path -LiteralPath $path -PathType Leaf) { $path }
    })
    if ($standaloneRemnants.Count -gt 0) {
        throw "Standalone Sysmon files remain at $($standaloneRemnants -join ', '). Complete the supported standalone uninstall before enabling built-in Sysmon."
    }

    New-Item -ItemType Directory -Path $sysmonDir -Force | Out-Null
    $stagedConfigPath = Join-Path $sysmonDir ([Guid]::NewGuid().ToString('N') + '.xml')

    try {
        Write-Host 'Downloading the pinned Sysmon configuration.'
        Invoke-WebRequest -Uri $configUri -OutFile $stagedConfigPath -UseBasicParsing -TimeoutSec 60
        $actualHash = (Get-FileHash -LiteralPath $stagedConfigPath -Algorithm SHA256).Hash
        if ($actualHash -ne $configSha256) {
            throw "Sysmon configuration SHA-256 mismatch. Expected $configSha256, got $actualHash."
        }
        $config = [System.Xml.XmlDocument]::new()
        $config.XmlResolver = $null
        $config.Load($stagedConfigPath)
        if ($config.DocumentElement.Name -cne 'Sysmon') {
            throw 'The configuration XML must have a Sysmon root element.'
        }

        if ($nativeFeature.State -ne 'Enabled') {
            Write-Host 'Enabling the built-in Windows Sysmon feature.'
            $featureChange = Enable-WindowsOptionalFeature -Online -FeatureName Sysmon -NoRestart
            $nativeFeature = Get-WindowsOptionalFeature -Online -FeatureName Sysmon
            if ($featureChange.RestartNeeded -or $nativeFeature.State -in 'EnablePending', 'DisablePending') {
                throw 'Built-in Sysmon requires a Windows restart before installation can continue. Restart Windows and rerun the extension.'
            }
            if ($nativeFeature.State -ne 'Enabled') {
                throw "Built-in Sysmon feature state is '$($nativeFeature.State)' after enablement."
            }
        }

        $systemDirectory = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            'Sysnative'
        } else {
            'System32'
        }
        $sysmonPath = Join-Path (Join-Path $env:SystemRoot $systemDirectory) 'Sysmon.exe'
        if (-not (Test-Path -LiteralPath $sysmonPath -PathType Leaf)) {
            throw "Built-in Sysmon is enabled, but its Windows executable is missing at $sysmonPath."
        }

        Write-Host 'Installing built-in Sysmon with the verified configuration.'
        $installerArguments = @('-i', ('"{0}"' -f $stagedConfigPath))
        $installer = Start-Process -FilePath $sysmonPath -ArgumentList $installerArguments -NoNewWindow -Wait -PassThru
        if ($installer.ExitCode -ne 0) {
            throw "Sysmon installer exited with code $($installer.ExitCode). Check its output for details."
        }

        # Keep the pending restart across extension retries, including a failed task registration.
        Set-Content -LiteralPath $pendingRestartPath -Value $bootStamp -Encoding Ascii
        Move-Item -LiteralPath $stagedConfigPath -Destination $sysmonConfigPath -Force
        $services = @(Get-CimInstance -ClassName Win32_Service -Filter $serviceFilter)
    } finally {
        Remove-Item -LiteralPath $stagedConfigPath -ErrorAction SilentlyContinue
    }
}

if ($services.Count -ne 1 -or $services[0].State -ne 'Running') {
    $serviceStates = ($services | ForEach-Object { "$($_.Name) ($($_.State))" }) -join ', '
    throw "Expected one running Sysmon service. Found $($services.Count). $serviceStates"
}
Write-Host 'Verified the running Sysmon service.'

$autorunsPath = Join-Path $sysinternalsDir 'Autoruns64.exe'
$stagedAutorunsPath = "$autorunsPath.$([Guid]::NewGuid().ToString('N')).tmp"
try {
    if (-not (Test-Path -LiteralPath $autorunsPath -PathType Leaf)) {
        New-Item -ItemType Directory -Path $sysinternalsDir -Force | Out-Null
        Write-Host 'Downloading Autoruns from Microsoft Sysinternals.'
        Invoke-WebRequest -Uri 'https://live.sysinternals.com/Autoruns64.exe' -OutFile $stagedAutorunsPath -UseBasicParsing -TimeoutSec 60
        Move-Item -LiteralPath $stagedAutorunsPath -Destination $autorunsPath -Force
    }
} catch {
    Write-Warning "The optional Autoruns tool could not be provisioned: $($_.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $stagedAutorunsPath -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $pendingRestartPath -PathType Leaf) {
    $pendingBootStamp = (Get-Content -LiteralPath $pendingRestartPath -Raw).Trim()
    if ($pendingBootStamp -eq $bootStamp.ToString()) {
        $scriptStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
        $restartCommand = @'
$ErrorActionPreference = 'Stop'
$installerProcess = Get-Process -Id __INSTALLER_PID__ -ErrorAction SilentlyContinue
if ($installerProcess) {
    $sameProcess = $false
    try {
        $sameProcess = $installerProcess.StartTime.ToUniversalTime().Ticks -eq __INSTALLER_START__
    } catch {
        if (-not $installerProcess.HasExited) { throw }
    }
    if ($sameProcess -and -not $installerProcess.WaitForExit(120000)) {
        throw 'The Sysmon extension script did not exit within two minutes.'
    }
}
if ((Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks -eq __BOOT_STAMP__) {
    Restart-Computer -Force
}
'@
        $restartCommand = $restartCommand.Replace('__INSTALLER_PID__', [string]$PID)
        $restartCommand = $restartCommand.Replace('__INSTALLER_START__', [string]$scriptStart)
        $restartCommand = $restartCommand.Replace('__BOOT_STAMP__', [string]$bootStamp)
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($restartCommand))
        $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument "-NoProfile -NonInteractive -EncodedCommand $encodedCommand"
        $restartAt = (Get-Date).AddMinutes(2)
        $trigger = New-ScheduledTaskTrigger -Once -At $restartAt
        $trigger.EndBoundary = $restartAt.AddHours(1).ToString('s')
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName 'Restart after Sysmon setup' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "The one-time Sysmon restart is scheduled for $($restartAt.ToString('s'))."
    }
}
