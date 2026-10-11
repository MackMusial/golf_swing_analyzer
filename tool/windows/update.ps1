# Updates this copy of Golf Swing Analyzer to the latest version on GitHub.
# Works whether the folder came from "Download ZIP" or `git clone`.
# Launched by Update.bat in the project root.

# Not 'Stop': Windows PowerShell 5.1 treats harmless stderr from git/flutter as
# fatal under 'Stop'. Real failures are thrown explicitly.
$ErrorActionPreference = 'Continue'

$Repo = 'MackMusial/golf_swing_analyzer'
$Branch = 'main'
$ProjectDir = (Resolve-Path "$PSScriptRoot\..\..").Path
$VersionFile = "$ProjectDir\.installed_version"
$Headers = @{ 'User-Agent' = 'GolfSwingAnalyzer-Updater' }

function Info($t) { Write-Host $t -ForegroundColor Cyan }
function Ok($t) { Write-Host $t -ForegroundColor Green }

function Show-Changes($sinceSha) {
    # Lists commits since the installed version (or the latest few).
    try {
        $commits = Invoke-RestMethod "https://api.github.com/repos/$Repo/commits?sha=$Branch&per_page=15" -Headers $Headers
        Write-Host "`nWhat's new:" -ForegroundColor Yellow
        $shown = 0
        foreach ($c in $commits) {
            if ($sinceSha -and $c.sha -eq $sinceSha) { break }
            $date = ([datetime]$c.commit.author.date).ToString('MMM d')
            Write-Host ("  - {0}  ({1})" -f ($c.commit.message -split "`n")[0], $date)
            $shown++
            if (-not $sinceSha -and $shown -ge 5) { break }
        }
    } catch { }
}

try {
    Write-Host '========================================================' -ForegroundColor Yellow
    Write-Host ' Golf Swing Analyzer - update' -ForegroundColor Yellow
    Write-Host '========================================================' -ForegroundColor Yellow

    Info 'Checking GitHub for the latest version...'
    try {
        $latest = Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$Branch" -Headers $Headers
    } catch {
        throw "Couldn't reach GitHub. Check your internet connection and try again."
    }
    $latestSha = $latest.sha

    $isGit = Test-Path "$ProjectDir\.git"
    $installed = if ($isGit) {
        (& git -C $ProjectDir rev-parse HEAD 2>$null)
    } elseif (Test-Path $VersionFile) {
        (Get-Content $VersionFile -Raw).Trim()
    } else { $null }

    if ($installed -eq $latestSha) {
        Ok "`nYou already have the latest version. Nothing to do."
        return
    }

    if ($isGit) {
        Info 'This folder is a git clone, so pulling the latest changes...'
        $dirty = & git -C $ProjectDir status --porcelain --untracked-files=no
        if ($dirty) {
            throw ("You have local edits in this folder, so I won't overwrite them:`n$dirty`n" +
                   'Commit or undo them (git stash), then run Update.bat again.')
        }
        & git -C $ProjectDir pull --ff-only origin $Branch
        if ($LASTEXITCODE -ne 0) { throw 'git pull failed (see above).' }
    }
    else {
        $tmp = Join-Path $env:TEMP "golf_update_$(Get-Random)"
        New-Item -ItemType Directory -Force $tmp | Out-Null
        try {
            $zip = "$tmp\latest.zip"
            Info 'Downloading the latest version...'
            Add-Type -AssemblyName System.Net.Http
            $client = New-Object System.Net.Http.HttpClient
            $client.DefaultRequestHeaders.Add('User-Agent', 'GolfSwingAnalyzer-Updater')
            $resp = $client.GetAsync("https://github.com/$Repo/archive/refs/heads/$Branch.zip",
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
            if (-not $resp.IsSuccessStatusCode) { throw "Download failed ($($resp.StatusCode))." }
            $in = $resp.Content.ReadAsStreamAsync().Result
            $out = [IO.File]::Create($zip)
            $buf = New-Object byte[] (256KB); $done = 0L
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $done += $n
                Write-Progress -Activity 'Downloading update' -Status ('{0:N1} MB' -f ($done / 1MB))
            }
            $out.Dispose(); $in.Dispose(); $client.Dispose()
            Write-Progress -Activity 'Downloading update' -Completed

            Info 'Unpacking...'
            Expand-Archive $zip "$tmp\x" -Force
            $src = Get-ChildItem "$tmp\x" -Directory | Select-Object -First 1
            if (-not $src -or -not (Test-Path "$($src.FullName)\pubspec.yaml")) {
                throw "The download didn't look like the app. Try again later."
            }

            Info 'Copying the new files in (your build files are kept)...'
            # /E copies subfolders; build caches are left alone so the next build is quick.
            & robocopy $src.FullName $ProjectDir /E /XD build .dart_tool .git /NFL /NDL /NJH /NJS /NP /R:2 /W:1 | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "Copying files failed (robocopy code $LASTEXITCODE). Close any open files in this folder and try again." }
            Set-Content -Path $VersionFile -Value $latestSha -Encoding ascii
        }
        finally {
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        }
    }

    $flutter = 'C:\dev\flutter\bin\flutter.bat'
    if (-not (Test-Path $flutter)) { $flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source }
    if ($flutter) {
        Info 'Updating the app''s packages...'
        Push-Location $ProjectDir
        & $flutter pub get | Out-Null
        Pop-Location
    }

    Ok "`nUpdated to the latest version!"
    Show-Changes $installed

    $answer = Read-Host "`nStart the app now? (Y/n)"
    if ($answer -notmatch '^[nN]') {
        Start-Process -FilePath "$ProjectDir\Run.bat" -WorkingDirectory $ProjectDir
        return
    }
    Write-Host 'Double-click Run.bat whenever you want to start it. The first start after an update rebuilds the app (a few minutes).'
}
catch {
    Write-Host "`nUPDATE FAILED: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Read-Host "`nPress Enter to close"
}
