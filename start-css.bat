@echo off
rem Starts Counter-Strike: Source through Steam in INSECURE mode (VAC off) as a local server.
rem NEVER join public / VAC-secured servers with the mod installed. Only your own server and friends you invite.
rem -condebug writes the game console to cstrike\console.log (useful for bug reports).
setlocal
set "STEAM="
for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Valve\Steam" /v SteamExe 2^>nul') do set "STEAM=%%B"
if not defined STEAM set "STEAM=%ProgramFiles(x86)%\Steam\steam.exe"
start "" "%STEAM%" -applaunch 240 -insecure -condebug -console -windowed -novid +sv_lan 0 +maxplayers 16
