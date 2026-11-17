<#
.SYNOPSIS
  Builds the SourceMod extension, the ReShade add-on, the SourcePawn plugin (and the Minecraft mod jar) from source into .\bin

.DESCRIPTION
  Needs: Visual Studio 2022 or newer with "Desktop development with C++", Git, and (for the mod) a JDK 25.
  It downloads the small header collections it compiles against into .\deps (SourceMod/SourcePawn/AMTL headers, ReShade add-on headers)
  and the pinned SourceMod release (for its plugin compiler). Nothing outside this folder is changed.
#>
[CmdletBinding()]
param([switch]$SkipMod)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Deps = Join-Path $Root 'deps'
$Bin = Join-Path $Root 'bin'
New-Item -ItemType Directory -Force $Deps, $Bin | Out-Null

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Need-Cmd($name, $help) { if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "$name was not found. $help" } }

# ---------------------------------------------------------------- tools
Need-Cmd git 'Install Git for Windows (winget install Git.Git).'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'Visual Studio was not found. Install Visual Studio Community with the "Desktop development with C++" workload.' }
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw 'Visual Studio is installed but without "Desktop development with C++". Open the Visual Studio Installer -> Modify -> tick that workload.' }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
Say "Visual Studio C++ tools: $vsPath" Green

# ---------------------------------------------------------------- dependencies (headers only)
# git writes its progress to stderr, which must not count as a failure: only the exit code does
function Git-Run {
	$old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
	try { & git @args 2>&1 | Out-Null; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
	if ($code -ne 0) { throw "git $($args -join ' ') failed (exit $code). Check your internet connection." }
}
function Clone-Once($url, $dir, [string[]]$extra = @()) {
	if (-not (Test-Path (Join-Path $dir '.git'))) { Git-Run clone --depth 1 @extra $url $dir }
}
$smSrc = Join-Path $Deps 'sourcemod-src'
if (-not (Test-Path (Join-Path $smSrc '.git'))) {
	Say 'Fetching SourceMod headers ...'
	Git-Run clone --depth 1 --filter=blob:none --sparse --branch 1.13.0.7477 https://github.com/alliedmodders/sourcemod $smSrc
	Git-Run -C $smSrc sparse-checkout set public
}
Say 'Fetching SourcePawn and AMTL headers ...'
Clone-Once 'https://github.com/alliedmodders/sourcepawn' (Join-Path $Deps 'sourcepawn')
Clone-Once 'https://github.com/alliedmodders/amtl' (Join-Path $Deps 'amtl')

$rsHeaders = Join-Path $Deps 'reshade-headers'
New-Item -ItemType Directory -Force $rsHeaders | Out-Null
foreach ($f in 'reshade.hpp', 'reshade_api.hpp', 'reshade_api_device.hpp', 'reshade_api_pipeline.hpp', 'reshade_api_resource.hpp', 'reshade_api_format.hpp', 'reshade_events.hpp', 'reshade_overlay.hpp') {
	$p = Join-Path $rsHeaders $f
	if (-not (Test-Path $p)) { Invoke-WebRequest "https://raw.githubusercontent.com/crosire/reshade/v6.8.0/include/$f" -OutFile $p -UseBasicParsing }
}

# the pinned SourceMod release: we need its plugin compiler (spcomp64.exe) and standard includes
$smZip = Join-Path $Deps 'sourcemod-1.13.0-git7477-windows.zip'
$smRel = Join-Path $Deps 'sourcemod-release'
if (-not (Test-Path (Join-Path $smRel 'addons\sourcemod\scripting\spcomp64.exe'))) {
	$cache = Join-Path $Root 'downloads\sourcemod-1.13.0-git7477-windows.zip'
	if (Test-Path $cache) { Copy-Item $cache $smZip -Force }
	elseif (-not (Test-Path $smZip)) {
		Say 'Downloading SourceMod 1.13.0.7477 (for its plugin compiler) ...'
		Invoke-WebRequest 'https://github.com/alliedmodders/sourcemod/releases/download/1.13.0.7477/sourcemod-1.13.0-git7477-windows.zip' -OutFile $smZip -UseBasicParsing
	}
	if ((Get-FileHash $smZip -Algorithm SHA256).Hash -ne '73B025A8183F5A38CEFF6E63574CD59984828CF2ACA533CFDD097C377BADEB02') { throw 'SourceMod download has the wrong checksum.' }
	Expand-Archive $smZip $smRel -Force
}

# ---------------------------------------------------------------- compile (C++)
function Run-Vc([string]$WorkDir, [string]$CmdLine) {
	$bat = Join-Path $env:TEMP "css-mc-build-$(Get-Random).bat"
	"@echo off`r`ncall `"$vcvars`" >nul`r`ncd /d `"$WorkDir`"`r`n$CmdLine`r`n" | Set-Content $bat -Encoding ascii
	try { & cmd.exe /c $bat; if ($LASTEXITCODE -ne 0) { throw "Build failed in $WorkDir" } } finally { Remove-Item $bat -Force -ErrorAction SilentlyContinue }
}

Say 'Building the SourceMod extension (mcbridge.ext.dll) ...' Cyan
$inc = "/I. /I`"$smSrc\public`" /I`"$smSrc\public\extensions`" /I`"$smSrc\public\amtl`" /I`"$Deps\sourcepawn\include`" /I`"$Deps\amtl`" /I`"$Deps\amtl\amtl`""
Run-Vc (Join-Path $Root 'ext') "cl /nologo /std:c++17 /EHsc /O2 /MT /LD /utf-8 /DWIN32 /D_WINDOWS /DWIN64 /DSOURCEMOD_BUILD /DMETA_NO_HL2SDK /D_CRT_SECURE_NO_WARNINGS /DNOMINMAX $inc extension.cpp `"$smSrc\public\smsdk_ext.cpp`" /Fe:mcbridge.ext.dll /link /DLL winhttp.lib user32.lib"
Copy-Item (Join-Path $Root 'ext\mcbridge.ext.dll') $Bin -Force

Say 'Building the ReShade add-on (MCCss.addon64) ...' Cyan
Run-Vc (Join-Path $Root 'addon') "cl /nologo /std:c++17 /EHsc /O2 /MT /LD /I `"$rsHeaders`" mccss_addon.cpp /Fe:MCCss.addon64 /link /DLL"
Copy-Item (Join-Path $Root 'addon\MCCss.addon64') $Bin -Force
Copy-Item (Join-Path $Root 'addon\MCCss.fx') $Bin -Force
Get-ChildItem (Join-Path $Root 'ext'), (Join-Path $Root 'addon') -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.obj', '.exp', '.lib', '.dll', '.addon64' } | Remove-Item -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- compile (SourcePawn plugin)
Say 'Compiling the SourcePawn plugin (mcbridge.smx) ...' Cyan
$spcomp = Join-Path $smRel 'addons\sourcemod\scripting\spcomp64.exe'
$smInc = Join-Path $smRel 'addons\sourcemod\scripting\include'
& $spcomp (Join-Path $Root 'plugin\scripting\mcbridge.sp') "-i$smInc" "-i$(Join-Path $Root 'plugin\scripting\include')" "-o$(Join-Path $Bin 'mcbridge.smx')" | Out-Host
if (-not (Test-Path (Join-Path $Bin 'mcbridge.smx'))) { throw 'The plugin did not compile.' }

# ---------------------------------------------------------------- the Minecraft mod
if (-not $SkipMod) {
	Say 'Building the Minecraft mod (needs JDK 25; downloads Gradle and Minecraft tooling the first time) ...' Cyan
	if (-not $env:JAVA_HOME -and (Test-Path (Join-Path $Root 'local-config.cmd'))) {
		$line = Select-String -Path (Join-Path $Root 'local-config.cmd') -Pattern 'set "JAVA_HOME=(.*)"' | Select-Object -First 1
		if ($line) { $env:JAVA_HOME = $line.Matches[0].Groups[1].Value }
	}
	Push-Location (Join-Path $Root 'mc')
	try { & .\gradlew.bat build --no-daemon; if ($LASTEXITCODE -ne 0) { throw 'Gradle build failed.' } } finally { Pop-Location }
	Get-ChildItem (Join-Path $Root 'mc\build\libs') -Filter 'passthrough-*.jar' | Where-Object { $_.Name -notmatch 'sources|dev' } | Select-Object -First 1 | Copy-Item -Destination (Join-Path $Bin 'passthrough-mod.jar') -Force
}

Say ''
Say 'Built:' Green
Get-ChildItem $Bin | ForEach-Object { Say ("  bin\{0}  ({1:N0} bytes)" -f $_.Name, $_.Length) }
Say 'Next: run install.ps1'
