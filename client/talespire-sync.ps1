# =============================================================================
# talespire-sync.ps1
# =============================================================================

# --- config ---
$ApiBase   = "https://app01.iph.ar"
$FilePath  = "$env:USERPROFILE\AppData\LocalLow\BouncyRock Entertainment\TaleSpire\Symbiotes\Toolset\.localstorage\d8383957-1a6b-4719-9b68-797f03145404"
$PollEvery = 30
$ClientId  = $env:USERNAME

# --- state ---
$version            = 0
$lastSyncedChecksum = ""

# =============================================================================
# Helpers
# =============================================================================

function Get-Checksum($path) {
    if (-not (Test-Path $path)) { return "" }
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hash  = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    $sha.Dispose()
    return $hash
}

function Get-StatusCode($err) {
    try { return [int]$err.Exception.Response.StatusCode } catch { return 0 }
}

function Log($msg) {
    Write-Host "[$(Get-Date -f 'HH:mm:ss')] $msg"
}

# =============================================================================
# Core operations
# =============================================================================

function Push-State {
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $body  = @{
        version    = $script:version
        updated_by = $ClientId
        data_b64   = [System.Convert]::ToBase64String($bytes)
    } | ConvertTo-Json

    try {
        $resp = Invoke-RestMethod "$ApiBase/state" -Method POST -Body $body -ContentType "application/json"
        $script:version            = $resp.version
        $script:lastSyncedChecksum = $resp.checksum
        Log "pushed  → version $($script:version)"
        return $true
    }
    catch {
        $code = Get-StatusCode $_
        if ($code -eq 409) {
            Log "conflict (409) → will pull"
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

        $dir = Split-Path $FilePath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        [System.IO.File]::WriteAllBytes($FilePath, $bytes)
        $script:version            = $full.version
        $script:lastSyncedChecksum = $full.checksum
        Log "pulled  → version $($script:version)"
    }
    catch {
        Log "pull failed: $_"
    }
}

# =============================================================================
# Sync tick — called once on startup, then every $PollEvery seconds
# =============================================================================

function Invoke-SyncTick {
    try {
        $meta = Invoke-RestMethod "$ApiBase/state" -Method GET
    }
    catch {
        Log "server unreachable: $_"
        return
    }

    # Bootstrap: server empty, we have a file → push it
    if ($meta.version -eq 0 -and (Test-Path $FilePath)) {
        Log "server empty → bootstrapping"
        Push-State
        return
    }

    # Remote changed → pull (remote always wins)
    if ($meta.checksum -ne $script:lastSyncedChecksum) {
        Log "remote changed → pulling"
        Pull-State
        return
    }

    # Local changed → push
    $localChecksum = Get-Checksum $FilePath
    if ($localChecksum -ne "" -and $localChecksum -ne $script:lastSyncedChecksum) {
        Log "local changed → pushing"
        $ok = Push-State
        if (-not $ok) { Pull-State }
    }
}

# =============================================================================
# Entry point
# =============================================================================

Log "talespire-sync starting (client: $ClientId, poll: ${PollEvery}s)"

Invoke-SyncTick

while ($true) {
    Start-Sleep -Seconds $PollEvery
    Invoke-SyncTick
}
