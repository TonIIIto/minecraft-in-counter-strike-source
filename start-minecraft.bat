@echo off
rem Starts the Minecraft side: a Fabric developer client with an offline account, in its own game folder (mc\run).
rem Your normal Minecraft worlds and launcher are not touched. The first start downloads Minecraft's files and takes a few minutes.
setlocal
cd /d "%~dp0"
if exist local-config.cmd call local-config.cmd
if not defined JAVA_HOME (
	for /d %%D in ("%ProgramFiles%\Amazon Corretto\jdk25*" "%ProgramFiles%\Eclipse Adoptium\jdk-25*" "%ProgramFiles%\Java\jdk-25*" "%ProgramFiles%\Microsoft\jdk-25*") do set "JAVA_HOME=%%~D"
)
if not defined JAVA_HOME (
	echo Java 25 was not found. Run install.ps1 again, or install a JDK 25 and set JAVA_HOME.
	pause
	exit /b 1
)
cd /d "%~dp0mc"
call gradlew.bat runClient --no-daemon
