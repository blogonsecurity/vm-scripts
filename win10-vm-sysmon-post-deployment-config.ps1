#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$sysinternalsDir = 'C:\Tools\Sysinternals'
$sysmonDir = 'C:\ProgramData\Sysmon'
$sysmonPath = Join-Path $sysinternalsDir 'Sysmon.exe'
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
        New-Item -ItemType Directory -Path $sysinternalsDir, $sysmonDir -Force | Out-Null
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

        Write-Host 'Downloading Sysmon from Microsoft Sysinternals.'
        Invoke-WebRequest -Uri 'https://live.sysinternals.com/Sysmon.exe' -OutFile $sysmonPath -UseBasicParsing -TimeoutSec 60

        Write-Host 'Installing Sysmon.'
        $installerArguments = @('-accepteula', '-i', ('"{0}"' -f $stagedConfigPath))
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
