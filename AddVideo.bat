@echo off
rem Copies swing videos into the running emulator's photo library.
rem Double-click to pick videos, or drag video files onto this file.
rem Self-contained: the PowerShell below the marker line does the work.
setlocal
set "ADDVIDEO_SELF=%~f0"
set "ADDVIDEO_ARGS=%*"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s = Get-Content -LiteralPath $env:ADDVIDEO_SELF -Raw; iex $s.Substring($s.LastIndexOf('#' + 'POWERSHELL'))"
exit /b

#POWERSHELL
$ErrorActionPreference = 'Stop'
try {
    $sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
    $adb = "$sdk\platform-tools\adb.exe"
    if (-not (Test-Path $adb)) { throw 'The Android tools are missing. Run Setup.bat first.' }

    # Files dragged onto the .bat, else a file picker.
    $files = @([regex]::Matches("$env:ADDVIDEO_ARGS", '"([^"]+)"|(\S+)') |
               ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } })
    if ($files.Count -eq 0) {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Pick swing video(s) to add to the emulator'
        $dlg.Filter = 'Videos|*.mp4;*.mov;*.m4v;*.3gp;*.webm;*.mkv|All files|*.*'
        $dlg.Multiselect = $true
        $dlg.InitialDirectory = [Environment]::GetFolderPath('MyVideos')
        if ($dlg.ShowDialog() -ne 'OK') { Write-Host 'No video picked.'; return }
        $files = $dlg.FileNames
    }

    $devices = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' } |
                 ForEach-Object { ($_ -split "`t")[0] })
    if ($devices.Count -eq 0) { throw 'No emulator is running. Start it with Run.bat first, then try again.' }
    $target = @($devices | Where-Object { $_ -like 'emulator-*' }) + $devices | Select-Object -First 1

    & $adb -s $target shell mkdir -p /sdcard/Movies | Out-Null
    foreach ($f in $files) {
        $name = (Split-Path $f -Leaf) -replace '[^\w.\-]', '_'
        Write-Host "Adding $name..."
        & $adb -s $target push "$f" "/sdcard/Movies/$name" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Couldn't copy $f to the emulator." }
    }
    # Make the photo library notice the new files right away.
    & $adb -s $target shell content call --method scan_volume --uri content://media --arg external_primary | Out-Null

    Write-Host "`nDone! Added $($files.Count) video(s)." -ForegroundColor Green
    Write-Host 'In the app, tap "Upload from library" and pick it.'
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
}
Read-Host "`nPress Enter to close"
