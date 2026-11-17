@echo off
rem One click: starts Minecraft, waits until its link is ready, then starts Counter-Strike: Source (insecure mode).
setlocal
cd /d "%~dp0"
echo Starting Minecraft (the first time takes several minutes while it downloads its files)...
start "Minecraft passthrough" /min cmd /c "%~dp0start-minecraft.bat"
powershell -NoProfile -Command "$t=0; while(-not (Get-NetTCPConnection -LocalPort 25599 -State Listen -ErrorAction SilentlyContinue)){ Start-Sleep 2; $t+=2; if($t -gt 900){ Write-Host 'Minecraft did not start - run start-minecraft.bat to see why'; exit 1 } }; Start-Sleep 15"
if errorlevel 1 (
	pause
	exit /b 1
)
echo Minecraft is ready. Starting Counter-Strike: Source...
call "%~dp0start-css.bat"
echo.
echo In Counter-Strike: Source open the console with the ~ key and type:   map de_dust2
echo Wait about 10 seconds for the map scan. Then:  F7 = Minecraft mode,  F10 = fly,  bot_add = add bots.
echo.
pause
