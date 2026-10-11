@echo off
rem Updates Golf Swing Analyzer to the latest version on GitHub.
rem Everything is on one line so cmd never re-reads this file after the update replaces it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\windows\update.ps1" & exit /b
