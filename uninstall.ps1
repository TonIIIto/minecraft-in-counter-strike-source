<#
.SYNOPSIS
  Removes everything install.ps1 added to Counter-Strike: Source and puts back the files it replaced.
#>
[CmdletBinding()]
param([string]$GameDir, [switch]$Yes)

$ErrorActionPreference = 'Stop'
function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }

function Find-CssFolder {
	$libs = @()
	$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
	foreach ($s in @($steam, "${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam")) {
		if ($s -and (Test-Path $s)) {
			$libs += $s
			$vdf = Join-Path $s 'steamapps\libraryfolders.vdf'
			if (Test-Path $vdf) { foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') } }
		}
	}
	foreach ($l in ($libs | Select-Object -Unique)) {
		$p = Join-Path $l 'steamapps\common\Counter-Strike Source'
		if (Test-Path (Join-Path $p 'mc-passthrough-installed.txt')) { return $p }
	}
	return $null
}

if (-not $GameDir) { $GameDir = Find-CssFolder }
if (-not $GameDir) { Say "Nothing to uninstall: no mc-passthrough-installed.txt found in your Counter-Strike Source folder." Yellow; exit 0 }
if (Get-Process -Name cstrike_win64, srcds_win64, hl2 -ErrorAction SilentlyContinue) { Say "Close Counter-Strike: Source first." Red; exit 1 }

$Manifest = Join-Path $GameDir 'mc-passthrough-installed.txt'
$files = Get-Content $Manifest | Where-Object { $_ }
$backupRoot = Join-Path $GameDir 'mc-passthrough-backup'
Say "This removes $($files.Count) files from: $GameDir" Cyan
if (-not $Yes -and ((Read-Host "Continue? (y/n)") -notmatch '^(y|Y)')) { exit 0 }

# the oldest backup of each file is the original one
$oldest = @{}
if (Test-Path $backupRoot) {
	foreach ($dir in (Get-ChildItem $backupRoot -Directory | Sort-Object Name)) {
		$full = $dir.FullName
		Get-ChildItem $dir.FullName -Recurse -File | ForEach-Object {
			$rel = $_.FullName.Substring($full.Length).TrimStart('\')
			if (-not $oldest.ContainsKey($rel)) { $oldest[$rel] = $_.FullName }
		}
	}
}

foreach ($rel in $files) {
	$path = Join-Path $GameDir $rel
	if (Test-Path $path) { Remove-Item $path -Force }
	if ($oldest.ContainsKey($rel)) { Copy-Item $oldest[$rel] $path -Force; Say "restored $rel" }
}

# empty folders we created
foreach ($rel in ($files | ForEach-Object { Split-Path $_ } | Sort-Object -Unique | Sort-Object Length -Descending)) {
	$p = Join-Path $GameDir $rel
	while ($rel -and (Test-Path $p) -and -not (Get-ChildItem $p -Force | Select-Object -First 1)) {
		Remove-Item $p -Force
		$rel = Split-Path $rel; $p = Join-Path $GameDir $rel
	}
}

Remove-Item $Manifest -Force
Say "Removed. (Backups stay in $backupRoot until you delete that folder.)" Green
if (-not $Yes) { Read-Host "Press Enter to close" }
