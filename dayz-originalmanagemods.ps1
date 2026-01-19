param(
    [string]$ModDirFormat  # kept for AMP compatibility, ignored in this script
)

$ErrorActionPreference = "Stop"

# Figure out paths based on where this script lives
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverRoot  = Join-Path $scriptDir "dayz\223350"
$workshopDir = Join-Path $serverRoot "steamapps\workshop\content\221100"
$serverKeys  = Join-Path $serverRoot "keys"

# ----------------------------------------------------------------------
# Read Mods.json: ClientServerIds & ServerOnlyIds (both are ID arrays)
# ----------------------------------------------------------------------
$modsJsonPath      = Join-Path $scriptDir "Mods.json"
[string[]]$ClientServerIds = @()
[string[]]$ServerOnlyIds   = @()
$modsConfig = $null
$modsJsonHasLists = $false

if (Test-Path -LiteralPath $modsJsonPath) {
    try {
        $modsJsonText = Get-Content -LiteralPath $modsJsonPath -Raw
        if ($modsJsonText -and $modsJsonText.Trim()) {
            $modsConfig = $modsJsonText | ConvertFrom-Json

            if ($modsConfig.ClientServerIds) {
                $ClientServerIds = @($modsConfig.ClientServerIds)
            }
            if ($modsConfig.ServerOnlyIds) {
                $ServerOnlyIds = @($modsConfig.ServerOnlyIds)
            }

            if ($ClientServerIds.Count -gt 0 -or $ServerOnlyIds.Count -gt 0) {
                $modsJsonHasLists = $true
            }
        }
    }
    catch {
        Write-Host "WARNING: Failed to read/parse Mods.json: $($_.Exception.Message)"
        Write-Host "         All mods will be treated as client+server for key copy."
        $ClientServerIds = @()
        $ServerOnlyIds   = @()
        $modsConfig      = $null
        $modsJsonHasLists = $false
    }
}
else {
    Write-Host "Mods.json not found; all mods will be treated as client+server for key copy."
}

if (-not (Test-Path -LiteralPath $serverRoot)) {
    Write-Host "ERROR: DayZ server root not found at '$serverRoot'."
	Write-Host "Mod management complete."
    exit 1
}

if (-not (Test-Path -LiteralPath $workshopDir)) {
	Write-Host "Mod management complete."
    exit 0
}

# Ensure server keys folder exists
if (-not (Test-Path -LiteralPath $serverKeys)) {
    New-Item -ItemType Directory -Path $serverKeys -Force | Out-Null
}

Set-Location -LiteralPath $serverRoot

$ServerOnlyNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

if (-not $modsJsonHasLists) {
    try {
        $existingModFolders = Get-ChildItem -LiteralPath $serverRoot -Directory -Filter "@*" -ErrorAction SilentlyContinue
        foreach ($f in $existingModFolders) {
            $flagPath = Join-Path $f.FullName "server_only.flag"
            if (Test-Path -LiteralPath $flagPath) {
                [void]$ServerOnlyNameSet.Add($f.Name)  # store '@ModName'
            }
        }
    }
    catch {
		Write-Host "WARNING: server_only.flag scan failed: $($_.Exception.Message)"
    }
}

# Enumerate mod folders under the DayZ workshop content
$mods = Get-ChildItem -LiteralPath $workshopDir -Directory -ErrorAction SilentlyContinue
if (-not $mods -or $mods.Count -eq 0) {
	Write-Host "Mod management complete."
    exit 0
}

# Ensure TLS 1.2 when talking to Steam
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Host "WARNING: Failed to set TLS12, continuing anyway."
}

function Get-ModNameFromMetaFiles {
    param(
        [string]$ModDir
    )

    # 1) meta.cpp: name = "Some Name"
    $metaCppPath = Join-Path $ModDir "meta.cpp"
    if (Test-Path -LiteralPath $metaCppPath) {
        $metaMatch = Select-String -Path $metaCppPath -Pattern '^\s*name\s*=\s*"(.*?)"' -AllMatches -ErrorAction SilentlyContinue
        if ($metaMatch -and $metaMatch.Matches.Count -gt 0) {
            return $metaMatch.Matches[0].Groups[1].Value
        }
    }

    # 2) mod.cpp: name = "Some Name"
    $modCppPath = Join-Path $ModDir "mod.cpp"
    if (Test-Path -LiteralPath $modCppPath) {
        $modMatch = Select-String -Path $modCppPath -Pattern '^\s*name\s*=\s*"(.*?)"' -AllMatches -ErrorAction SilentlyContinue
        if ($modMatch -and $modMatch.Matches.Count -gt 0) {
            return $modMatch.Matches[0].Groups[1].Value
        }
    }

    return $null
}

function Get-ModNameFromSteam {
    param(
        [string]$ModId
    )

    $steamPage = "https://steamcommunity.com/workshop/filedetails/?id=$ModId"

    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $steamPage -ErrorAction Stop
    } catch {
        return $null
    }

    $match = $resp.Content |
        Select-String -Pattern '<div class="workshopItemTitle">([^<]*)</div>' |
        Select-Object -First 1

    if ($match -and $match.Matches.Count -gt 0) {
        return $match.Matches[0].Groups[1].Value.Trim()
    }

    return $null
}

# Map: workshop ID -> @ModName (dest folder name)
$IdToName = @{}

foreach ($modFolder in $mods) {
    $modDir = $modFolder.FullName
    $modId  = [string]$modFolder.Name

    # 1) Try meta.cpp / mod.cpp
    $modName = Get-ModNameFromMetaFiles -ModDir $modDir

    # 2) Fallback to Steam page if needed
    if (-not $modName) {
        $modName = Get-ModNameFromSteam -ModId $modId
    }

    if (-not $modName) {
        Write-Host "  ERROR: Unable to determine name for workshop item $modId. Skipping."
        continue
    }

    # Sanitize for Windows filesystem
    $modName = $modName -replace '[\\/:*?"<>|]', '-'
    $destFolderName = "@$modName"
    $destPath = Join-Path $serverRoot $destFolderName

    # Remember mapping id -> @name for later JSON update
    $IdToName[$modId] = $destFolderName

    # If a destination folder already exists, remove it so we overwrite with new version
    if (Test-Path -LiteralPath $destPath) {
        Remove-Item -LiteralPath $destPath -Recurse -Force
    }

    Move-Item -LiteralPath $modDir -Destination $destPath -Force

    # ------------------------------------------------------------------
    # Determine whether this mod is server-only & manage sentinel file
    # ------------------------------------------------------------------
	$isServerOnly = $false

	if ($modsJsonHasLists) {
		if ($ServerOnlyIds -contains $modId) {
			$isServerOnly = $true
		}
	}
	else {
		# Mods.json has no lists: preserve server-only by matching '@ModName'
		if ($ServerOnlyNameSet.Contains($destFolderName)) {
			$isServerOnly = $true
		}
	}

    $serverOnlyFlag = Join-Path $destPath 'server_only.flag'

    if ($isServerOnly) {
        if (-not (Test-Path -LiteralPath $serverOnlyFlag)) {
            New-Item -ItemType File -Path $serverOnlyFlag -Force | Out-Null
        } else {
        }
    }
    else {
        if (Test-Path -LiteralPath $serverOnlyFlag) {
            Remove-Item -LiteralPath $serverOnlyFlag -Force
        }
    }

    # ----------------------------------------------------------------------
    # Copy .bikey files from mod's keys folder into server root 'keys' folder
    # Rules:
    #   - If Mods.json had ID arrays, only copy for ClientServerIds.
    #   - If Mods.json is missing/empty, treat all mods as client+server (copy keys).
    # ----------------------------------------------------------------------
    $shouldCopyKeys = (-not $isServerOnly)

    if ($shouldCopyKeys) {
        try {
            $candidateKeyDirs = Get-ChildItem -LiteralPath $destPath -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^(?i)keys?$' }   # "key" or "keys", any case

            if ($candidateKeyDirs -and $candidateKeyDirs.Count -gt 0) {
                foreach ($keysDir in $candidateKeyDirs) {
                    $keysPath = $keysDir.FullName

                    $bikeyFiles = Get-ChildItem -LiteralPath $keysPath -Filter "*.bikey" -File -Recurse -ErrorAction SilentlyContinue
                    foreach ($bikey in $bikeyFiles) {
                        $destKeyPath = Join-Path $serverKeys $bikey.Name
                        Copy-Item -LiteralPath $bikey.FullName -Destination $destKeyPath -Force
                    }
                }
            } else {
                Write-Host "  No bikey found for '$modName'."
            }
        }
        catch {
            Write-Host "  ERROR while copying .bikey files for mod '$modName' ($modId): $($_.Exception.Message)"
        }
    }
    else {
    }
}

# After moving everything, check if workshopDir (content\221100) is now empty
$remaining = Get-ChildItem -LiteralPath $workshopDir -Force -ErrorAction SilentlyContinue

# $workshopDir = <serverRoot>\steamapps\workshop\content\221100
# We want to delete the whole 'steamapps\workshop' folder once 221100 is empty
$workshopRoot = Join-Path $serverRoot "steamapps\workshop"

if (-not $remaining -or $remaining.Count -eq 0) {

    if (Test-Path -LiteralPath $workshopRoot) {
        Remove-Item -LiteralPath $workshopRoot -Recurse -Force
    } else {
    }
} else {
}

# ----------------------------------------------------------------------
# Update Mods.json with @names (keeping order) + ;-joined strings
# ----------------------------------------------------------------------
$ClientServerNames = @()
foreach ($id in $ClientServerIds) {
    if ($IdToName.ContainsKey($id)) { $ClientServerNames += $IdToName[$id] }
}

$ServerOnlyNames = @()
foreach ($id in $ServerOnlyIds) {
    if ($IdToName.ContainsKey($id)) { $ServerOnlyNames += $IdToName[$id] }
}

$modsOut = [pscustomobject]@{
    ClientServerIds    = $ClientServerIds
    ServerOnlyIds      = $ServerOnlyIds
    ClientServerNames  = $ClientServerNames
    ServerOnlyNames    = $ServerOnlyNames
    ClientServerJoined = ($ClientServerNames -join ';')
    ServerOnlyJoined   = ($ServerOnlyNames   -join ';')
}

$modsOut | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $modsJsonPath -Encoding UTF8

Write-Host ""
Write-Host "Mod management complete."
exit 0
