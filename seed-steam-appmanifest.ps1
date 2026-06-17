param(
    [Parameter(Mandatory = $true)]
    [string]$SteamAppsDir,

    [Parameter(Mandatory = $true)]
    [string]$LauncherPath,

    [Parameter(Mandatory = $true)]
    [string]$AppId,

    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [Parameter(Mandatory = $true)]
    [string]$InstallDir
)

$manifestPath = Join-Path $SteamAppsDir "appmanifest_$AppId.acf"

if (Test-Path $manifestPath) {
    Write-Host "Steam appmanifest already exists: $manifestPath"
    exit 0
}

New-Item -ItemType Directory -Force -Path $SteamAppsDir | Out-Null

$escapedLauncherPath = $LauncherPath.Replace('\', '\\')

$acf = @"
"AppState"
{
	"appid"		"$AppId"
	"Universe"		"1"
	"LauncherPath"		"$escapedLauncherPath"
	"name"		"$AppName"
	"StateFlags"		"1026"
	"installdir"		"$InstallDir"
	"LastUpdated"		"0"
	"LastPlayed"		"0"
	"SizeOnDisk"		"0"
	"StagingSize"		"0"
	"buildid"		"0"
	"LastOwner"		"0"
	"DownloadType"		"1"
	"UpdateResult"		"0"
}
"@

Set-Content -Path $manifestPath -Value $acf -Encoding ASCII

Write-Host "Created Steam appmanifest seed: $manifestPath"
exit 0
