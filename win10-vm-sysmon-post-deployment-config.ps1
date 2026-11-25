#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$sysinternalsDir = 'C:\Tools\Sysinternals'
$sysmonDir = 'C:\ProgramData\Sysmon'
$standaloneSysmonPath = Join-Path $sysinternalsDir 'Sysmon.exe'
$sysmonConfigPath = Join-Path $sysmonDir 'sysmonConfig.xml'
$channelName = 'Microsoft-Windows-Sysmon/Operational'
$serviceFilter = "Name = 'Sysmon' OR Name = 'Sysmon64'"

# Balanced Sysmon Modular configuration and its published SHA-256.
$configUri = 'https://github.com/olafhartong/sysmon-modular/releases/download/configs-a45dedb13a43/sysmonconfig.xml'
$configSha256 = '64bec37ba849c5f2934a55d2a29e7ddfae46a30d56f7f2908d1f8a454898797e'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$stagedConfigPath = $null
try {
    $services = @(Get-CimInstance -ClassName Win32_Service -Filter $serviceFilter)
    if ($services.Count -eq 0) {
        $nativeFeature = Get-WindowsOptionalFeature -Online | Where-Object FeatureName -eq 'Sysmon'
        if ($nativeFeature) {
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
        }

        New-Item -ItemType Directory -Path $sysmonDir -Force | Out-Null
        $stagedConfigPath = Join-Path $sysmonDir ([Guid]::NewGuid().ToString('N') + '.xml')

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

        $installerArguments = @('-i', ('"{0}"' -f $stagedConfigPath))
        if ($nativeFeature) {
            if ($nativeFeature.State -ne 'Enabled') {
                Write-Host 'Enabling the built-in Windows Sysmon feature.'
                $featureChange = Enable-WindowsOptionalFeature -Online -FeatureName Sysmon -NoRestart
                if ($featureChange.RestartNeeded) {
                    throw 'Built-in Sysmon requires a Windows restart to complete feature enablement. Restart Windows and rerun the extension.'
                }
                $nativeFeature = Get-WindowsOptionalFeature -Online -FeatureName Sysmon
                if ($nativeFeature.State -ne 'Enabled') {
                    throw "Built-in Sysmon feature state is '$($nativeFeature.State)' after enablement. Check Windows servicing status before rerunning."
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
        } else {
            New-Item -ItemType Directory -Path $sysinternalsDir -Force | Out-Null
            $sysmonPath = $standaloneSysmonPath
            Write-Host 'Downloading standalone Sysmon from Microsoft Sysinternals.'
            Invoke-WebRequest -Uri 'https://live.sysinternals.com/Sysmon.exe' -OutFile $sysmonPath -UseBasicParsing -TimeoutSec 60
            $installerArguments = @('-accepteula') + $installerArguments
            Write-Host 'Installing standalone Sysmon with the verified configuration.'
        }

        $installer = Start-Process -FilePath $sysmonPath -ArgumentList $installerArguments -NoNewWindow -Wait -PassThru
        if ($installer.ExitCode -ne 0) {
            throw "Sysmon installer exited with code $($installer.ExitCode). Check its output for details."
        }
        $services = @(Get-CimInstance -ClassName Win32_Service -Filter $serviceFilter)
    }

    if ($services.Count -ne 1 -or $services[0].State -ne 'Running') {
        $serviceStates = ($services | ForEach-Object { "$($_.Name) ($($_.State))" }) -join ', '
        throw "Expected one running Sysmon service. Found $($services.Count). $serviceStates"
    }

    $channel = Get-WinEvent -ListLog $channelName
    if (-not $channel.IsEnabled) {
        throw "The Sysmon event channel '$channelName' is disabled."
    }

    if ($stagedConfigPath) {
        Move-Item -LiteralPath $stagedConfigPath -Destination $sysmonConfigPath -Force
        Write-Host "Sysmon installation verified. Configuration saved to $sysmonConfigPath."
    } else {
        Write-Host 'Existing Sysmon installation verified. Preserved its configuration.'
    }
} finally {
    if ($stagedConfigPath) {
        Remove-Item -LiteralPath $stagedConfigPath -ErrorAction SilentlyContinue
    }
}

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
    Write-Warning "Sysmon is operational. The optional Autoruns tool could not be provisioned: $($_.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $stagedAutorunsPath -ErrorAction SilentlyContinue
}
