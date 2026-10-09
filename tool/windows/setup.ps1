# One-shot Windows setup for Golf Swing Analyzer.
# Installs Git, a JDK, Flutter, the Android SDK and an emulator, then fetches
# the project's packages. Safe to re-run: anything already installed is skipped.
# Launched by Setup.bat in the project root.

$ErrorActionPreference = 'Stop'

$FlutterVersion = '3.47.7'
$CmdlineToolsZip = 'commandlinetools-win-13114758_latest.zip'
$AndroidApi = '36'
$BuildTools = '36.0.0'
$SystemImage = "system-images;android-$AndroidApi;google_apis;x86_64"
$AvdName = 'GolfPhone'

$ProjectDir = (Resolve-Path "$PSScriptRoot\..\..").Path
$DevDir = 'C:\dev'
$FlutterDir = "$DevDir\flutter"
$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk"
$LogFile = "$ProjectDir\setup.log"

# --- Re-launch as administrator (needed for Developer Mode and Windows features) ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Asking for administrator permission...'
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    exit
}

Start-Transcript -Path $LogFile -Append | Out-Null
$needsReboot = $false

function Step($n, $text) {
    Write-Host "`n[$n/9] $text" -ForegroundColor Cyan
    Write-Progress -Id 0 -Activity 'Golf Swing Analyzer setup' -Status "Step $n of 9: $text" `
        -PercentComplete ([int](($n - 1) / 9 * 100))
}
function Ok($text) { Write-Host "      $text" -ForegroundColor Green }

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Add-UserPath($dir) {
    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $p) { $p = '' }
    if (($p -split ';') -notcontains $dir) {
        [Environment]::SetEnvironmentVariable('Path', ($p.TrimEnd(';') + ";$dir").TrimStart(';'), 'User')
    }
}

# Streams a download to disk with a progress bar (MB done, speed, time left).
# Invoke-WebRequest's own bar is very slow and shows no speed, so we do it by hand.
function Download($url, $dest) {
    $name = Split-Path $url -Leaf
    Write-Host "      Downloading $name..."
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromHours(3)
    $in = $null; $out = $null
    try {
        $resp = $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
        $resp.EnsureSuccessStatusCode() | Out-Null
        $total = $resp.Content.Headers.ContentLength
        $in = $resp.Content.ReadAsStreamAsync().Result
        $out = [IO.File]::Create($dest)
        $buf = New-Object byte[] (1MB)
        $done = 0L
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $lastUpdate = -1000
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $done += $n
            if ($sw.ElapsedMilliseconds - $lastUpdate -ge 500) {
                $lastUpdate = $sw.ElapsedMilliseconds
                $mbps = ($done / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.1)
                $status = '{0:N0} MB' -f ($done / 1MB)
                if ($total) {
                    $pct = [int]($done * 100 / $total)
                    $left = [int](($total - $done) / 1MB / [Math]::Max($mbps, 0.01))
                    $status = '{0:N0} of {1:N0} MB  ({2:N1} MB/s)' -f ($done / 1MB), ($total / 1MB), $mbps
                    Write-Progress -Id 1 -ParentId 0 -Activity "Downloading $name" -Status $status `
                        -PercentComplete $pct -SecondsRemaining $left
                } else {
                    Write-Progress -Id 1 -ParentId 0 -Activity "Downloading $name" -Status $status
                }
            }
        }
        Write-Host ('      Downloaded {0:N0} MB in {1:N0}s' -f ($done / 1MB), $sw.Elapsed.TotalSeconds)
    }
    finally {
        if ($out) { $out.Dispose() }
        if ($in) { $in.Dispose() }
        $client.Dispose()
        Write-Progress -Id 1 -Activity "Downloading $name" -Completed
    }
}

# Runs a long, quiet command while showing a "still working" bar with elapsed time.
function Run-WithTimer($activity, $exe, $arguments) {
    $p = Start-Process $exe -ArgumentList $arguments -NoNewWindow -PassThru
    $null = $p.Handle   # without touching Handle, ExitCode comes back empty
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited) {
        Write-Progress -Id 1 -ParentId 0 -Activity $activity `
            -Status ('Still working... {0:mm\:ss} elapsed' -f $sw.Elapsed)
        Start-Sleep -Milliseconds 500
    }
    $p.WaitForExit()
    Write-Progress -Id 1 -Activity $activity -Completed
    if ($p.ExitCode -ne 0) { throw "$activity failed (exit code $($p.ExitCode))." }
}

# Pipes a stream of "y" answers into a command that asks to accept licenses.
function Accept-All($scriptBlock) {
    (1..100 | ForEach-Object { 'y' }) | & $scriptBlock | Out-Null
}

try {
    Write-Host '========================================================' -ForegroundColor Yellow
    Write-Host ' Golf Swing Analyzer - Windows setup' -ForegroundColor Yellow
    Write-Host ' This downloads about 5 GB and can take 20-60 minutes.' -ForegroundColor Yellow
    Write-Host '========================================================' -ForegroundColor Yellow

    # 1. winget
    Step 1 'Checking for winget (Windows package installer)'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget is missing. Open the Microsoft Store, install/update "App Installer", then run Setup.bat again.'
    }
    Ok 'winget found'

    # 2. Git (Flutter needs it)
    Step 2 'Installing Git'
    Refresh-Path
    if (Get-Command git -ErrorAction SilentlyContinue) { Ok 'already installed' }
    else {
        winget install --id Git.Git -e --silent --accept-source-agreements --accept-package-agreements
        Refresh-Path
        Ok 'installed'
    }

    # 3. Java (Android build tools need it)
    Step 3 'Installing Java (OpenJDK 21)'
    $jdk = Get-ChildItem 'C:\Program Files\Microsoft' -Directory -Filter 'jdk-*' -ErrorAction SilentlyContinue |
           Sort-Object Name -Descending | Select-Object -First 1
    if ($jdk) { Ok "already installed ($($jdk.Name))" }
    else {
        winget install --id Microsoft.OpenJDK.21 -e --silent --accept-source-agreements --accept-package-agreements
        $jdk = Get-ChildItem 'C:\Program Files\Microsoft' -Directory -Filter 'jdk-*' |
               Sort-Object Name -Descending | Select-Object -First 1
        if (-not $jdk) { throw 'Java install finished but no JDK folder was found in C:\Program Files\Microsoft.' }
        Ok "installed ($($jdk.Name))"
    }
    $env:JAVA_HOME = $jdk.FullName
    [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdk.FullName, 'User')

    # 4. Flutter
    Step 4 "Installing Flutter $FlutterVersion"
    if (Test-Path "$FlutterDir\bin\flutter.bat") { Ok "already installed at $FlutterDir" }
    else {
        New-Item -ItemType Directory -Force $DevDir | Out-Null
        $releases = Invoke-RestMethod 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json'
        $rel = $releases.releases | Where-Object { $_.version -eq $FlutterVersion -and $_.channel -eq 'stable' } | Select-Object -First 1
        if (-not $rel) {
            Write-Host "      Flutter $FlutterVersion not listed; using the current stable release instead."
            $rel = $releases.releases | Where-Object { $_.hash -eq $releases.current_release.stable } | Select-Object -First 1
        }
        $zip = "$env:TEMP\flutter.zip"
        Download "$($releases.base_url)/$($rel.archive)" $zip
        Write-Host '      Unzipping (a few minutes)...'
        Run-WithTimer 'Unzipping Flutter' 'tar.exe' @('-xf', "`"$zip`"", '-C', "`"$DevDir`"")
        Remove-Item $zip
        Ok "installed to $FlutterDir"
    }
    Add-UserPath "$FlutterDir\bin"
    $env:Path += ";$FlutterDir\bin"
    # Fresh installs fail Git's "dubious ownership" check when run elevated.
    try { git config --global --add safe.directory '*' 2>$null } catch { }

    # 5. Android SDK command-line tools
    Step 5 'Installing Android SDK tools'
    $sdkmanager = "$AndroidSdk\cmdline-tools\latest\bin\sdkmanager.bat"
    $avdmanager = "$AndroidSdk\cmdline-tools\latest\bin\avdmanager.bat"
    if (Test-Path $sdkmanager) { Ok 'already installed' }
    else {
        New-Item -ItemType Directory -Force "$AndroidSdk\cmdline-tools" | Out-Null
        $zip = "$env:TEMP\android-cmdline-tools.zip"
        Download "https://dl.google.com/android/repository/$CmdlineToolsZip" $zip
        $tmp = "$env:TEMP\android-cmdline-tools"
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
        Expand-Archive $zip $tmp
        Move-Item "$tmp\cmdline-tools" "$AndroidSdk\cmdline-tools\latest"
        Remove-Item $zip; Remove-Item -Recurse -Force $tmp
        Ok 'installed'
    }
    $env:ANDROID_HOME = $AndroidSdk
    [Environment]::SetEnvironmentVariable('ANDROID_HOME', $AndroidSdk, 'User')
    Add-UserPath "$AndroidSdk\platform-tools"
    Add-UserPath "$AndroidSdk\emulator"

    # 6. Android SDK packages + emulator image
    Step 6 'Installing Android SDK packages and emulator (the big download)'
    Accept-All { & $sdkmanager --licenses }
    # Not piped, so sdkmanager's own [=====   ] 40% progress bar shows.
    & $sdkmanager --install 'platform-tools' 'emulator' "platforms;android-$AndroidApi" "build-tools;$BuildTools" $SystemImage
    Ok 'done'

    # 7. Emulator (virtual phone)
    Step 7 "Creating the emulator '$AvdName'"
    if (Test-Path "$env:USERPROFILE\.android\avd\$AvdName.avd") { Ok 'already exists' }
    else {
        'no' | & $avdmanager create avd -n $AvdName -k $SystemImage -d pixel_6 | Out-Null
        # Let the PC keyboard type into the emulator.
        Add-Content "$env:USERPROFILE\.android\avd\$AvdName.avd\config.ini" 'hw.keyboard=yes'
        Ok 'created'
    }

    # 8. Windows settings: Developer Mode + hypervisor for the emulator
    Step 8 'Turning on Developer Mode and emulator acceleration'
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
        -Name AllowDevelopmentWithoutDevLicense -Value 1 -Type DWord
    Ok 'Developer Mode on'
    $whpx = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
    if ($whpx.State -eq 'Enabled') { Ok 'Windows Hypervisor Platform already on' }
    else {
        Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart | Out-Null
        $needsReboot = $true
        Ok 'Windows Hypervisor Platform turned on (restart needed)'
    }

    # 9. Flutter config + project packages
    Step 9 'Setting up Flutter and the project'
    Write-Host '      First Flutter run downloads its Dart tools (a few minutes)...'
    & "$FlutterDir\bin\flutter.bat" --version
    & "$FlutterDir\bin\flutter.bat" config --android-sdk $AndroidSdk --no-analytics | Out-Null
    Accept-All { & "$FlutterDir\bin\flutter.bat" doctor --android-licenses }
    Push-Location $ProjectDir
    & "$FlutterDir\bin\flutter.bat" pub get
    Pop-Location
    & "$FlutterDir\bin\flutter.bat" doctor
    Write-Progress -Id 0 -Activity 'Golf Swing Analyzer setup' -Completed

    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host ' Setup finished!' -ForegroundColor Green
    if ($needsReboot) {
        Write-Host ' RESTART YOUR PC now, then double-click Run.bat.' -ForegroundColor Yellow
    } else {
        Write-Host ' Double-click Run.bat to start the app.' -ForegroundColor Green
    }
    Write-Host ' (Red X next to "Visual Studio" above is fine to ignore.)'
    Write-Host '========================================================' -ForegroundColor Green
}
catch {
    Write-Host "`nSETUP FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Full log: $LogFile" -ForegroundColor Red
    Write-Host 'Fix the problem above and run Setup.bat again; finished steps are skipped.'
}
finally {
    Stop-Transcript | Out-Null
    Read-Host "`nPress Enter to close"
}
