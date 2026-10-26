$ErrorActionPreference = "SilentlyContinue"
$BotDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BotScript = Join-Path $BotDir "bot.ps1"
$PidFile = Join-Path $BotDir "bot.pid"
$WatcherPidFile = Join-Path $BotDir "watcher.pid"

if (Test-Path $WatcherPidFile) {
    try {
        $oldW = [int](Get-Content $WatcherPidFile -Raw).Trim()
        if ($oldW -ne $PID) {
            $p = Get-Process -Id $oldW -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -match "powershell|pwsh") {
                exit 0
            }
        }
    } catch {}
}
$PID | Set-Content $WatcherPidFile -Encoding ASCII

while ($true) {
    $agRunning = Get-Process -Name "Antigravity", "language_server" -ErrorAction SilentlyContinue
    if ($agRunning) {
        $botRunning = $false
        if (Test-Path $PidFile) {
            try {
                $bPid = [int](Get-Content $PidFile -Raw).Trim()
                $bProc = Get-Process -Id $bPid -ErrorAction SilentlyContinue
                if ($bProc -and $bProc.ProcessName -match "powershell|pwsh") {
                    $botRunning = $true
                }
            } catch {}
        }
        if (-not $botRunning) {
            Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$BotScript`"" -WindowStyle Hidden
            Start-Sleep -Seconds 5
        }
    }
    Start-Sleep -Seconds 5
}
