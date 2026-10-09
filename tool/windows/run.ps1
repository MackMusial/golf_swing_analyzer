# Starts the app: on a plugged-in Android phone if there is one, otherwise on
# the emulator that setup.ps1 created. Launched by Run.bat in the project root.

$ErrorActionPreference = 'Stop'

$AvdName = 'GolfPhone'
$ProjectDir = (Resolve-Path "$PSScriptRoot\..\..").Path
$AndroidSdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$adb = "$AndroidSdk\platform-tools\adb.exe"
$emulator = "$AndroidSdk\emulator\emulator.exe"
$flutter = 'C:\dev\flutter\bin\flutter.bat'
if (-not (Test-Path $flutter)) { $flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source }

try {
    if (-not $flutter -or -not (Test-Path $adb)) { throw 'Flutter or the Android SDK is missing. Run Setup.bat first.' }

    function Get-Devices {
        & $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' } |
            ForEach-Object { ($_ -split "`t")[0] }
    }

    & $adb start-server 2>$null | Out-Null
    $devices = @(Get-Devices)
    $phone = $devices | Where-Object { $_ -notlike 'emulator-*' } | Select-Object -First 1
    $emu = $devices | Where-Object { $_ -like 'emulator-*' } | Select-Object -First 1

    if ($phone) {
        Write-Host "Using your plugged-in phone ($phone)." -ForegroundColor Green
        $target = $phone
    }
    elseif ($emu) {
        Write-Host 'Emulator is already running.' -ForegroundColor Green
        $target = $emu
    }
    else {
        & $emulator -accel-check 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw ("The emulator can't use hardware acceleration. Restart the PC if you haven't since setup. " +
                   'If it still fails, turn on virtualization (Intel VT-x / AMD-V / SVM) in your BIOS settings.')
        }
        Write-Host 'Starting the emulator (a phone window will open)...' -ForegroundColor Cyan
        Start-Process $emulator -ArgumentList '-avd', $AvdName
        & $adb wait-for-device
        Write-Host 'Waiting for the emulator to finish booting (1-3 minutes the first time)...'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ((& $adb shell getprop sys.boot_completed 2>$null) -ne '1') {
            if ($sw.Elapsed.TotalMinutes -gt 6) { throw 'The emulator took too long to boot. Close it and run Run.bat again.' }
            # Typical first boot is ~2 minutes; cap the bar at 95% until it's actually done.
            $pct = [Math]::Min(95, [int]($sw.Elapsed.TotalSeconds / 120 * 100))
            Write-Progress -Activity 'Booting the emulator' -PercentComplete $pct `
                -Status ('Still booting... {0:mm\:ss} elapsed' -f $sw.Elapsed)
            Start-Sleep -Seconds 2
        }
        Write-Progress -Activity 'Booting the emulator' -Completed
        $target = @(Get-Devices | Where-Object { $_ -like 'emulator-*' })[0]
        Write-Host 'Emulator ready.' -ForegroundColor Green
    }

    Write-Host "`nBuilding and installing the app. The first time takes 3-10 minutes." -ForegroundColor Cyan
    Write-Host 'When it says "Flutter run key commands", the app is running. Press q here to stop.'
    Push-Location $ProjectDir
    & $flutter run --release -d $target
    Pop-Location
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Read-Host "`nPress Enter to close"
}
