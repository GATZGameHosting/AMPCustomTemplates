param(
    [string]$ModDirFormat  # kept for AMP compatibility, ignored in this script
)

$ErrorActionPreference = "Stop"

Write-Host "GATZ Manage Mods: starting..."

# Figure out paths based on where this script lives
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$kvpPath = Join-Path $scriptDir "GATZSteamModPlugin.kvp"

if (-not (Test-Path -LiteralPath $kvpPath)) {
    Write-Host "ERROR: GATZSteamModPlugin.kvp not found at '$($kvpPath)'."
    exit 1
}

function Get-KvpValue {
    param(
        [string]$Path,
        [string]$Key
    )

    $escapedKey = [regex]::Escape($Key)

    $line = Get-Content -LiteralPath $Path -ErrorAction Stop |
        Where-Object { $_ -match "^\s*$escapedKey\s*=" } |
        Select-Object -First 1

    if (-not $line) {
        return $null
    }

    return (($line -split "=", 2)[1]).Trim()
}

function Normalize-PathPart {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    return $Value.Trim().Trim([char[]]"\/")
}

$gameFolderName = Get-KvpValue -Path $kvpPath -Key "ModManagement.GameFolderName"
$gameBranch     = Get-KvpValue -Path $kvpPath -Key "ModManagement.GameBranch"
$modBranch      = Get-KvpValue -Path $kvpPath -Key "ModManagement.ModBranch"

$gameFolderName = Normalize-PathPart $gameFolderName
$gameBranch     = Normalize-PathPart $gameBranch
$modBranch      = Normalize-PathPart $modBranch

if ([string]::IsNullOrWhiteSpace($gameFolderName)) {
    Write-Host "ERROR: ModManagement.GameFolderName is missing or blank in '$($kvpPath)'."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($gameBranch)) {
    Write-Host "ERROR: ModManagement.GameBranch is missing or blank in '$($kvpPath)'."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($modBranch)) {
    Write-Host "ERROR: ModManagement.ModBranch is missing or blank in '$($kvpPath)'."
    exit 1
}

$serverRoot  = Join-Path $scriptDir (Join-Path $gameFolderName $gameBranch)
$workshopDir = Join-Path $serverRoot (Join-Path "steamapps\workshop\content" $modBranch)
$serverKeys  = Join-Path $serverRoot "keys"

$jobDir      = Join-Path $scriptDir "GATZModManagement"
$requestPath = Join-Path $jobDir "install-request.json"
$resultPath  = Join-Path $jobDir "install-result.json"

$jobId = ""
$request = $null
$serverOnlyIdSet = @{}
$clientServerIdSet = @{}

$movedMods = New-Object System.Collections.Generic.List[object]
$failedMods = New-Object System.Collections.Generic.List[object]

if (Test-Path -LiteralPath $requestPath) {
    try {
        $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
        $jobId = [string]$request.JobId
        Write-Host "Install request found. JobId: $jobId"

        if ($null -ne $request.ClientServerIds) {
            foreach ($id in $request.ClientServerIds) {
                $cleanId = ([string]$id).Trim()
                if ($cleanId.Length -gt 0) {
                    $clientServerIdSet[$cleanId] = $true
                }
            }
        }

        if ($null -ne $request.ServerOnlyIds) {
            foreach ($id in $request.ServerOnlyIds) {
                $cleanId = ([string]$id).Trim()
                if ($cleanId.Length -gt 0) {
                    $serverOnlyIdSet[$cleanId] = $true
                }
            }
        }

        Write-Host "Install request Client+Server IDs: $($clientServerIdSet.Count)"
        Write-Host "Install request Server Only IDs: $($serverOnlyIdSet.Count)"
    } catch {
        Write-Host "WARNING: Failed to read install request '$requestPath': $($_.Exception.Message)"
    }
} else {
    Write-Host "WARNING: No install request file found at '$requestPath'. Mods will still be processed, but plugin may not finalize this job."
}

function Write-InstallResult {
    param(
        [bool]$Success
    )

    if (-not (Test-Path -LiteralPath $jobDir)) {
        New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    }

    $movedArray = @()
    if ($null -ne $movedMods -and $movedMods.Count -gt 0) {
        foreach ($item in $movedMods) {
            $movedArray += $item
        }
    }

    $failedArray = @()
    if ($null -ne $failedMods -and $failedMods.Count -gt 0) {
        foreach ($item in $failedMods) {
            $failedArray += $item
        }
    }

    $result = New-Object PSObject
    $result | Add-Member -MemberType NoteProperty -Name "JobId" -Value $jobId
    $result | Add-Member -MemberType NoteProperty -Name "CompletedUtc" -Value ([DateTime]::UtcNow.ToString("o"))
    $result | Add-Member -MemberType NoteProperty -Name "Success" -Value $Success
    $result | Add-Member -MemberType NoteProperty -Name "MovedMods" -Value $movedArray
    $result | Add-Member -MemberType NoteProperty -Name "Failed" -Value $failedArray

    $tmpPath = "$resultPath.tmp"
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmpPath -Encoding UTF8
    Move-Item -LiteralPath $tmpPath -Destination $resultPath -Force

    Write-Host "Wrote install result to '$($resultPath)'."
}

if (-not (Test-Path -LiteralPath $serverRoot)) {
    Write-Host "ERROR: DayZ server root not found at '$($serverRoot)'."
    $failedMods.Add([PSCustomObject]@{ Id = ""; Reason = "DayZ server root not found at '$($serverRoot)'." })
    Write-InstallResult -Success $false
    exit 1
}

if (-not (Test-Path -LiteralPath $workshopDir)) {
    Write-Host "No workshop content directory at '$($workshopDir)'. Nothing to do."
    Write-InstallResult -Success $true
    exit 0
}

# Ensure server keys folder exists
if (-not (Test-Path -LiteralPath $serverKeys)) {
    Write-Host "Creating server keys folder at '$($serverKeys)'..."
    New-Item -ItemType Directory -Path $serverKeys -Force | Out-Null
}

Set-Location -LiteralPath $serverRoot
Write-Host "Server root: $($serverRoot)"
Write-Host "Workshop dir: $($workshopDir)"

# Enumerate mod folders under the DayZ workshop content
$mods = Get-ChildItem -LiteralPath $workshopDir -Directory -ErrorAction SilentlyContinue
if (-not $mods -or $mods.Count -eq 0) {
    Write-Host "No workshop mods found under '$($workshopDir)'."
    Write-InstallResult -Success $true
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
        Write-Host ("  Failed to fetch Steam page for {0}: {1}" -f $ModId, $_.Exception.Message)
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

foreach ($modFolder in $mods) {
    $modDir = $modFolder.FullName
    $modId  = $modFolder.Name
    Write-Host ""
    Write-Host "Processing workshop mod ID $($modId) at '$($modDir)'..."

    try {
        # 1) Try meta.cpp / mod.cpp
        $modName = Get-ModNameFromMetaFiles -ModDir $modDir

        # 2) Fallback to Steam page if needed
        if (-not $modName) {
            Write-Host "  No name found in meta/mod.cpp. Fetching from Steam..."
            $modName = Get-ModNameFromSteam -ModId $modId
        }

        if (-not $modName) {
            $reason = "Unable to determine name for workshop item $($modId)."
            Write-Host "  ERROR: $($reason) Skipping."
            $failedMods.Add([PSCustomObject]@{ Id = $modId; Reason = $reason })
            continue
        }

        # Sanitize for Windows filesystem
        $sourceName = $modName
        $modName = $modName -replace '[\\/:*?"<>|]', '-'
        $destFolderName = "@$modName"
        $destPath = Join-Path $serverRoot $destFolderName

        # If a destination folder already exists, remove it so we overwrite with new version
        if (Test-Path -LiteralPath $destPath) {
            Write-Host "  Removing existing destination folder '$($destPath)'..."
            Remove-Item -LiteralPath $destPath -Recurse -Force
        }

        Write-Host "  Moving mod '$($modName)' ($($modId)) -> '$($destFolderName)'..."
        Move-Item -LiteralPath $modDir -Destination $destPath -Force

        # ----------------------------------------------------------------------
        # Copy .bikey files from mod's keys folder into server root 'keys' folder.
        # Only Client+Server mods should copy keys.
        # Server Only mods should not copy keys into the server root keys folder.
        # Folder name could be: keys, key, Keys, Key (case-insensitive)
        # ----------------------------------------------------------------------
        $keysFolderFound = $false
        $bikeysCopied = 0
        $keyWarning = ""

        $isServerOnly = $serverOnlyIdSet.ContainsKey($modId)
        $isClientServer = $clientServerIdSet.ContainsKey($modId)

        if ($isServerOnly -and -not $isClientServer) {
            $keyWarning = "Server Only mod; skipped .bikey copy."
            Write-Host "  Server Only mod detected. Skipping .bikey copy to server keys folder."
        } else {
            try {
                $candidateKeyDirs = Get-ChildItem -LiteralPath $destPath -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^(?i)keys?$' }   # "key" or "keys", any case

                if ($candidateKeyDirs -and $candidateKeyDirs.Count -gt 0) {
                    $keysFolderFound = $true

                    foreach ($keysDir in $candidateKeyDirs) {
                        $keysPath = $keysDir.FullName
                        Write-Host "  Found keys directory '$($keysPath)'. Copying .bikey files to '$($serverKeys)'..."

                        $bikeyFiles = Get-ChildItem -LiteralPath $keysPath -Filter "*.bikey" -File -Recurse -ErrorAction SilentlyContinue
                        if ($bikeyFiles -and $bikeyFiles.Count -gt 0) {
                            foreach ($bikey in $bikeyFiles) {
                                $destKeyPath = Join-Path $serverKeys $bikey.Name
                                Copy-Item -LiteralPath $bikey.FullName -Destination $destKeyPath -Force
                                $bikeysCopied++
                            }
                        }
                    }

                    if ($bikeysCopied -eq 0) {
                        $keyWarning = "Key folder found, but no .bikey files were copied. If this mod requires a separate key, add it manually."
                        Write-Host "  WARNING: $($keyWarning)"
                    }
                } else {
                    $keyWarning = "No key/keys folder found. If this mod requires a separate key, add it manually."
                    Write-Host "  WARNING: $($keyWarning)"
                }
            } catch {
                $keyWarning = "Error while copying .bikey files: $($_.Exception.Message)"
                Write-Host "  WARNING: $($keyWarning)"
            }
        }

        $movedMods.Add([PSCustomObject]@{
            Id              = $modId
            FolderName      = $destFolderName
            SourceName      = $sourceName
            KeysFolderFound = $keysFolderFound
            BikeysCopied    = $bikeysCopied
            KeyWarning      = $keyWarning
        })
    } catch {
        $reason = $_.Exception.Message
        Write-Host "  ERROR while processing workshop item $($modId): $($reason)"
        $failedMods.Add([PSCustomObject]@{ Id = $modId; Reason = $reason })
    }
}

# After moving everything, check if workshopDir (content\221100) is now empty
$remaining = Get-ChildItem -LiteralPath $workshopDir -Force -ErrorAction SilentlyContinue

# $workshopDir = <serverRoot>\steamapps\workshop\content\221100
# We want to delete the whole 'steamapps\workshop' folder once 221100 is empty
$workshopRoot = Join-Path $serverRoot "steamapps\workshop"

if (-not $remaining -or $remaining.Count -eq 0) {
    Write-Host ""
    Write-Host "DayZ workshop content '$($workshopDir)' is now empty."

    if (Test-Path -LiteralPath $workshopRoot) {
        Write-Host "Deleting workshop root directory '$($workshopRoot)'..."
        Remove-Item -LiteralPath $workshopRoot -Recurse -Force
    } else {
        Write-Host "Workshop root directory '$($workshopRoot)' not found (already removed?)."
    }
} else {
    Write-Host ""
    Write-Host "DayZ workshop content '$($workshopDir)' is not empty; leaving workshop folder in place."
}

$success = ($failedMods.Count -eq 0)
Write-InstallResult -Success $success

Write-Host ""
Write-Host "GATZ Manage Mods: completed."
if ($success) {
    exit 0
}

exit 1
