# =============================================================================
# talespire-sync.ps1
# =============================================================================

param(
    [string]$SyncDir = "$env:USERPROFILE\AppData\LocalLow\BouncyRock Entertainment\TaleSpire\Symbiotes\Toolset\.localstorage"
)

# --- config ---
$ApiBase   = "https://app01.iph.ar"
$PollEvery = 5
$ClientId  = $env:USERNAME

# --- state ---
$lastSyncedVersion  = 0
$lastSyncedChecksum = ""

# =============================================================================
# Helpers
# =============================================================================

function Log($msg) {
    Write-Host "[$(Get-Date -f 'HH:mm:ss')] $msg"
}

function Get-StatusCode($err) {
    try { return [int]$err.Exception.Response.StatusCode } catch { return 0 }
}

# Zip the entire $SyncDir into an in-memory byte array.
function Get-DirectoryZipBytes {
    $stream = [System.IO.MemoryStream]::new()
    $zip    = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)

    Get-ChildItem -Path $SyncDir -Recurse -File | ForEach-Object {
        $relativePath = $_.FullName.Substring($SyncDir.Length).TrimStart('\', '/')
        $entry        = $zip.CreateEntry($relativePath, [System.IO.Compression.CompressionLevel]::Optimal)
        $entryStream  = $entry.Open()
        $fileBytes    = [System.IO.File]::ReadAllBytes($_.FullName)
        $entryStream.Write($fileBytes, 0, $fileBytes.Length)
        $entryStream.Dispose()
    }

    $zip.Dispose()
    return $stream.ToArray()
}

# Unzip bytes into $SyncDir, merging (overwrite matching files, leave others).
function Expand-ZipBytesToDirectory($bytes) {
    $stream = [System.IO.MemoryStream]::new($bytes)
    $zip    = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Read)

    foreach ($entry in $zip.Entries) {
        $destPath = Join-Path $SyncDir $entry.FullName
        $destDir  = Split-Path $destPath

        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        $entryStream = $entry.Open()
        $fileStream  = [System.IO.File]::OpenWrite($destPath)
        $entryStream.CopyTo($fileStream)
        $fileStream.Dispose()
        $entryStream.Dispose()
    }

    $zip.Dispose()
    $stream.Dispose()
}

# Compute a stable checksum of the directory's contents.
# Sorts files by relative path for determinism, then hashes path+bytes for each file.
# This is independent of zip metadata, so it won't drift between ticks.
function Get-DirectoryChecksum {
    $sha = [System.Security.Cryptography.SHA256]::Create()

    Get-ChildItem -Path $SyncDir -Recurse -File |
        Sort-Object FullName |
        ForEach-Object {
            $relativePath = $_.FullName.Substring($SyncDir.Length).TrimStart('\', '/')
            $pathBytes    = [System.Text.Encoding]::UTF8.GetBytes($relativePath)
            $fileBytes    = [System.IO.File]::ReadAllBytes($_.FullName)
            $sha.TransformBlock($pathBytes, 0, $pathBytes.Length, $null, 0) | Out-Null
            $sha.TransformBlock($fileBytes, 0, $fileBytes.Length, $null, 0) | Out-Null
        }

    $sha.TransformFinalBlock(@(), 0, 0) | Out-Null
    $hash = ($sha.Hash | ForEach-Object { $_.ToString("x2") }) -join ""
    $sha.Dispose()
    return $hash
}

# =============================================================================
# Core operations
# =============================================================================

function Push-State {
    $bytes  = Get-DirectoryZipBytes
    $body   = @{
        version    = $script:lastSyncedVersion
        updated_by = $ClientId
        data_b64   = [System.Convert]::ToBase64String($bytes)
    } | ConvertTo-Json

    try {
        $resp = Invoke-RestMethod "$ApiBase/state" -Method POST -Body $body -ContentType "application/json"
        $script:lastSyncedVersion  = $resp.version
        $script:lastSyncedChecksum = Get-DirectoryChecksum
        Log "pushed  --> version $($script:lastSyncedVersion)"
        return $true
    }
    catch {
        $code = Get-StatusCode $_
        if ($code -eq 409) {
            Log "conflict (409) --> will pull"
        } else {
            Log "push failed ($code)"
        }
        return $false
    }
}

function Pull-State {
    try {
        $full  = Invoke-RestMethod "$ApiBase/state/full" -Method GET
        $bytes = [System.Convert]::FromBase64String($full.data_b64)

        if (-not (Test-Path $SyncDir)) {
            New-Item -ItemType Directory -Path $SyncDir -Force | Out-Null
        }

        Expand-ZipBytesToDirectory $bytes
        $script:lastSyncedVersion  = $full.version
        $script:lastSyncedChecksum = Get-DirectoryChecksum
        Log "pulled  --> version $($script:lastSyncedVersion)"
    }
    catch {
        Log "pull failed: $_"
    }
}

# =============================================================================
# Sync tick
# =============================================================================

function Invoke-SyncTick {
    # Check server reachability and get current remote version
    try {
        $meta = Invoke-RestMethod "$ApiBase/state" -Method GET
    }
    catch {
        Log "server unreachable: $_"
        return
    }

    # Remote is ahead --> pull (version is the authoritative signal)
    if ($meta.version -gt $script:lastSyncedVersion) {
        Log "remote is v$($meta.version), local is v$($script:lastSyncedVersion) --> pulling"
        Pull-State
        return
    }

    # Remote is current --> check for local changes and push if any
    if (Test-Path $SyncDir) {
        $localChecksum = Get-DirectoryChecksum

        if ($localChecksum -ne $script:lastSyncedChecksum) {
            Log "local changed --> pushing"
            $ok = Push-State
            if (-not $ok) { Pull-State }
        }
    }
}

# =============================================================================
# Entry point
# =============================================================================

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

Log "talespire-sync starting"
Log "  client : $ClientId"
Log "  dir    : $SyncDir"
Log "  poll   : ${PollEvery}s"
Log "  server : $ApiBase"

Invoke-SyncTick

while ($true) {
    Start-Sleep -Seconds $PollEvery
    Invoke-SyncTick
}
