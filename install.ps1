<#
.SYNOPSIS
  Installs the Minecraft x Counter-Strike: Source passthrough into your CS:S folder (own/local servers only).

.DESCRIPTION
  - finds Counter-Strike: Source (the 64-bit Steam version) in your Steam libraries
  - backs up every file it would overwrite (into <CS:S>\mc-passthrough-backup)
  - downloads Metamod:Source, SourceMod and ReShade from their official pages and checks their SHA-256
  - installs our extension, plugin and ReShade add-on (from the bin\ folder of the release zip)
  - writes a list of everything it added, so uninstall.ps1 can undo it

  Run it by right-clicking install.ps1 -> "Run with PowerShell", or:  powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param(
	[string]$GameDir,          # the "Counter-Strike Source" folder (the one with cstrike_win64.exe); found automatically if omitted
	[switch]$Yes,              # don't ask questions
	[switch]$Force,            # replace a d3d9.dll that is not ReShade
	[string]$DownloadCache     # reuse already downloaded files from here (default: .\downloads)
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $DownloadCache) { $DownloadCache = Join-Path $Root 'downloads' }

# Exact versions this was built and tested with (the newest Metamod 2.0 does NOT work with the 64-bit SourceMod: see docs/HOW-IT-WORKS.md)
$Downloads = @(
	@{ Name = 'Metamod:Source 1.12.0.1227'; File = 'mmsource-1.12.0-git1227-windows.zip'
	   Url = 'https://github.com/alliedmodders/metamod-source/releases/download/1.12.0.1227/mmsource-1.12.0-git1227-windows.zip'
	   Sha256 = '01A684249AD093DDEE1C144FE7CDD25A7BF004466122CD32FDC722BF6F7D332A' },
	@{ Name = 'SourceMod 1.13.0.7477'; File = 'sourcemod-1.13.0-git7477-windows.zip'
	   Url = 'https://github.com/alliedmodders/sourcemod/releases/download/1.13.0.7477/sourcemod-1.13.0-git7477-windows.zip'
	   Sha256 = '73B025A8183F5A38CEFF6E63574CD59984828CF2ACA533CFDD097C377BADEB02' },
	@{ Name = 'ReShade 6.8.0 (with add-on support)'; File = 'ReShade_Setup_6.8.0_Addon.exe'
	   Url = 'https://reshade.me/downloads/ReShade_Setup_6.8.0_Addon.exe'
	   Sha256 = 'AFE4C8F13048306307983B8B3D41D5BF00A86820440B0E57DEA10950E1176445' }
)
$ShaderFiles = @(
	@{ File = 'ReShade.fxh';   Url = 'https://raw.githubusercontent.com/crosire/reshade-shaders/slim/Shaders/ReShade.fxh' },
	@{ File = 'ReShadeUI.fxh'; Url = 'https://raw.githubusercontent.com/crosire/reshade-shaders/slim/Shaders/ReShadeUI.fxh' }
)

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Fail($text) { Write-Host ""; Write-Host "STOP: $text" -ForegroundColor Red; Write-Host ""; Read-Host "Press Enter to close"; exit 1 }

Say ""
Say "=== Minecraft x Counter-Strike: Source - installer ===" Cyan
Say "This installs a modification for YOUR OWN local CS:S server."
Say "It must only ever be played with -insecure (the start scripts do that), never on public/VAC servers."
Say ""
if (-not $Yes) {
	$a = Read-Host "Continue? (y/n)"
	if ($a -notmatch '^(y|Y)') { Say "Cancelled."; exit 0 }
}

# ---------------------------------------------------------------- 1. find CS:S
function Find-CssFolder {
	$libs = @()
	$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
	foreach ($s in @($steam, "${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam")) {
		if ($s -and (Test-Path $s)) {
			$libs += $s
			$vdf = Join-Path $s 'steamapps\libraryfolders.vdf'
			if (Test-Path $vdf) {
				foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') }
			}
		}
	}
	foreach ($l in ($libs | Select-Object -Unique)) {
		$p = Join-Path $l 'steamapps\common\Counter-Strike Source'
		if (Test-Path (Join-Path $p 'cstrike_win64.exe')) { return $p }
	}
	return $null
}

if (-not $GameDir) { $GameDir = Find-CssFolder }
if (-not $GameDir -or -not (Test-Path (Join-Path $GameDir 'cstrike_win64.exe'))) {
	Fail "Counter-Strike: Source (64-bit) was not found in your Steam libraries.`nInstall it from Steam (it is free if you own it), start it once, then run this again.`nOr run: .\install.ps1 -GameDir 'D:\SteamLibrary\steamapps\common\Counter-Strike Source'"
}
$Cstrike = Join-Path $GameDir 'cstrike'
Say "Counter-Strike: Source found: $GameDir" Green

if (Get-Process -Name cstrike_win64, srcds_win64, hl2 -ErrorAction SilentlyContinue) {
	Fail "Counter-Strike: Source is running. Close it completely (type quit in its console), then run this again."
}

# ---------------------------------------------------------------- 2. our own files
$Bin = Join-Path $Root 'bin'
$needed = 'mcbridge.ext.dll', 'mcbridge.smx', 'MCCss.addon64', 'MCCss.fx'
foreach ($n in $needed) {
	if (-not (Test-Path (Join-Path $Bin $n))) {
		Fail "Missing bin\$n.`nYou probably cloned the source code. Either download the ready-made release zip from the GitHub 'Releases' page,`nor build it yourself with:  powershell -ExecutionPolicy Bypass -File .\build.ps1"
	}
}

# ---------------------------------------------------------------- 3. downloads (checked against SHA-256)
New-Item -ItemType Directory -Force $DownloadCache | Out-Null
foreach ($d in $Downloads) {
	$path = Join-Path $DownloadCache $d.File
	$ok = (Test-Path $path) -and ((Get-FileHash $path -Algorithm SHA256).Hash -eq $d.Sha256)
	if (-not $ok) {
		Say "Downloading $($d.Name) ..."
		$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
		Invoke-WebRequest -Uri $d.Url -OutFile $path -UseBasicParsing -UserAgent $ua -Headers @{ Referer = 'https://reshade.me/' }
		$got = (Get-FileHash $path -Algorithm SHA256).Hash
		if ($got -ne $d.Sha256) {
			Remove-Item $path -Force
			Fail "The download of $($d.Name) does not match the expected checksum (got $got). Nothing was installed. If a newer version was published, open an issue on the project page."
		}
	}
	$d.Path = $path
}
foreach ($s in $ShaderFiles) {
	$path = Join-Path $DownloadCache $s.File
	if (-not (Test-Path $path)) { Say "Downloading $($s.File) ..."; Invoke-WebRequest -Uri $s.Url -OutFile $path -UseBasicParsing }
	$s.Path = $path
}

# ---------------------------------------------------------------- 4. install, with backups and a list of what was added
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Backup = Join-Path $GameDir "mc-passthrough-backup\$Stamp"
$Manifest = Join-Path $GameDir 'mc-passthrough-installed.txt'
$added = New-Object System.Collections.Generic.List[string]
if (Test-Path $Manifest) { Get-Content $Manifest | ForEach-Object { $added.Add($_) } }

function Put-File([string]$From, [string]$ToRel) {
	$to = Join-Path $GameDir $ToRel
	# only a file that was there before us is an "original" worth backing up (not our own file from an earlier run)
	if ((Test-Path $to) -and -not $added.Contains($ToRel)) {
		$b = Join-Path $Backup $ToRel
		New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null
		if (-not (Test-Path $b)) { Copy-Item $to $b -Force }
	}
	New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
	Copy-Item $From $to -Force
	if (-not $added.Contains($ToRel)) { $added.Add($ToRel) }
}

function Put-Tree([string]$FromDir, [string]$ToRelPrefix) {
	$full = (Resolve-Path $FromDir).Path
	Get-ChildItem $FromDir -Recurse -File | ForEach-Object {
		$rel = $_.FullName.Substring($full.Length).TrimStart('\')
		Put-File $_.FullName (Join-Path $ToRelPrefix $rel)
	}
}

# a d3d9.dll that is not ReShade (someone else's tool): don't touch it unless -Force
$d3d9 = Join-Path $GameDir 'd3d9.dll'
if ((Test-Path $d3d9) -and -not $Force) {
	$ver = (Get-Item $d3d9).VersionInfo.ProductName
	if ($ver -notmatch 'ReShade' -and -not ($added -contains 'd3d9.dll')) {
		Fail "There is already a d3d9.dll in the game folder that is not ReShade ($ver).`nI won't overwrite it. Move it away, or run with -Force."
	}
}

$work = Join-Path $env:TEMP "css-mc-install-$Stamp"
New-Item -ItemType Directory -Force $work | Out-Null
try {
	Say "Installing Metamod:Source and SourceMod ..."
	$mm = Join-Path $work 'mm'; $sm = Join-Path $work 'sm'
	Expand-Archive $Downloads[0].Path $mm -Force
	Expand-Archive $Downloads[1].Path $sm -Force
	# the 32-bit loader file just produces an error line in the 64-bit game
	Remove-Item (Join-Path $mm 'addons\metamod.vdf') -Force -ErrorAction SilentlyContinue
	Put-Tree $mm 'cstrike'
	Put-Tree $sm 'cstrike'
	# SourceMod's 64-bit loader has a different file name than the one the package points Metamod at
	$vdf = Join-Path $work 'sourcemod.vdf'
	[IO.File]::WriteAllText($vdf, "`"Metamod Plugin`"`r`n{`r`n`t`"alias`"`t`t`"sm`"`r`n`t`"file`"`t`t`"addons/sourcemod/bin/sourcemod_mm.x64.dll`"`r`n}`r`n", (New-Object Text.UTF8Encoding($false)))
	Put-File $vdf 'cstrike\addons\metamod\sourcemod.vdf'

	Say "Installing ReShade (the overlay engine) ..."
	$rs = Join-Path $work 'rs'; New-Item -ItemType Directory -Force $rs | Out-Null
	Push-Location $rs
	try { & tar.exe -xf $Downloads[2].Path ReShade64.dll } finally { Pop-Location }
	if (-not (Test-Path (Join-Path $rs 'ReShade64.dll'))) { throw "Could not unpack ReShade64.dll from the ReShade installer." }
	Put-File (Join-Path $rs 'ReShade64.dll') 'd3d9.dll'
	$ini = Join-Path $work 'ReShade.ini'
	[IO.File]::WriteAllText($ini, "[GENERAL]`r`nEffectSearchPaths=.\reshade-shaders\Shaders\`r`nTextureSearchPaths=.\reshade-shaders\Textures\`r`nPresetPath=.\ReShadePreset.ini`r`n`r`n[OVERLAY]`r`nTutorialProgress=4`r`nShowClock=0`r`nShowFPS=0`r`n`r`n[SCREENSHOT]`r`nSavePath=.\`r`n", [Text.Encoding]::ASCII)
	Put-File $ini 'ReShade.ini'
	$preset = Join-Path $work 'ReShadePreset.ini'
	[IO.File]::WriteAllText($preset, "Techniques=MCCss@MCCss.fx`r`nTechniqueSorting=MCCss@MCCss.fx`r`n", [Text.Encoding]::ASCII)
	Put-File $preset 'ReShadePreset.ini'
	foreach ($s in $ShaderFiles) { Put-File $s.Path ("reshade-shaders\Shaders\" + $s.File) }

	Say "Installing the Minecraft bridge (extension, plugin, overlay) ..."
	Put-File (Join-Path $Bin 'MCCss.addon64') 'MCCss.addon64'
	Put-File (Join-Path $Bin 'MCCss.fx') 'reshade-shaders\Shaders\MCCss.fx'
	Put-File (Join-Path $Bin 'mcbridge.ext.dll') 'cstrike\addons\sourcemod\extensions\x64\mcbridge.ext.dll'
	$auto = Join-Path $work 'mcbridge.autoload'; '' | Set-Content $auto -Encoding ascii
	Put-File $auto 'cstrike\addons\sourcemod\extensions\mcbridge.autoload'
	Put-File (Join-Path $Bin 'mcbridge.smx') 'cstrike\addons\sourcemod\plugins\mcbridge.smx'
}
finally {
	Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$added | Set-Content $Manifest -Encoding utf8
Say "Added or replaced $($added.Count) files. List: $Manifest" Gray
if (Test-Path $Backup) { Say "Backups of replaced files: $Backup" Gray }

# ---------------------------------------------------------------- 5. Java for the Minecraft side
function Find-Jdk25 {
	foreach ($pattern in @("$env:ProgramFiles\Amazon Corretto\jdk25*", "$env:ProgramFiles\Eclipse Adoptium\jdk-25*", "$env:ProgramFiles\Java\jdk-25*",
			"$env:ProgramFiles\Microsoft\jdk-25*", "$env:ProgramFiles\Zulu\zulu-25*", "$env:ProgramFiles\BellSoft\LibericaJDK-25*")) {
		$m = Get-ChildItem $pattern -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
		if ($m -and (Test-Path (Join-Path $m.FullName 'bin\java.exe'))) { return $m.FullName }
	}
	if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
		$v = & (Join-Path $env:JAVA_HOME 'bin\java.exe') -version 2>&1 | Select-Object -First 1
		if ("$v" -match '"25') { return $env:JAVA_HOME }
	}
	return $null
}
$jdk = Find-Jdk25
if (-not $jdk) {
	Say ""
	Say "The Minecraft side needs Java (JDK) 25, which was not found." Yellow
	$go = $Yes
	if (-not $Yes) { $go = (Read-Host "Install Amazon Corretto 25 now with winget? (y/n)") -match '^(y|Y)' }
	if ($go) {
		try {
			& winget install --id Amazon.Corretto.25.JDK -e --accept-package-agreements --accept-source-agreements
			$jdk = Find-Jdk25
		} catch { Say "winget failed: $_" Yellow }
	}
	if (-not $jdk) { Say "Install a JDK 25 yourself (for example https://corretto.aws/downloads/latest/), then run this installer again." Yellow }
}
$cfg = @("@echo off", "rem written by install.ps1 - safe to delete (the start scripts then search for Java themselves)")
if ($jdk) { $cfg += "set `"JAVA_HOME=$jdk`"" }
$cfg | Set-Content (Join-Path $Root 'local-config.cmd') -Encoding ascii

Say ""
Say "=== Done! ===" Green
Say "To play: double-click START-EVERYTHING.bat in this folder."
Say "Then, in Counter-Strike: Source, open the console with the ~ key and type:  map de_dust2"
Say "(See README.md for the controls: F7 Minecraft mode, F10 fly, bot_add to add bots.)"
Say ""
if (-not $Yes) { Read-Host "Press Enter to close" }
