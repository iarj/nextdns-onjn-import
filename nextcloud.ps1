# =========================
# NextDNS: Import ONJN blacklist into Denylist (PowerShell 5.1)
# Bulk via PUT (ordered keys to satisfy "first key is id")
# =========================

# ====== CONFIG ======
$ApiKey = "PASTE_API_KEY_AICI"   # sau foloseste Read-Host mai jos
# $ApiKey = Read-Host "NextDNS API key (din my.nextdns.io/account)"

$OnjnUrlHttp  = "http://onjn.gov.ro/wp-content/uploads/Onjn.gov.ro/Acasa/BlackList/Lista-neagra.txt"
$OnjnUrlHttps = "https://onjn.gov.ro/wp-content/uploads/Onjn.gov.ro/Acasa/BlackList/Lista-neagra.txt"

$Headers = @{
  "X-Api-Key"    = $ApiKey
  "Content-Type" = "application/json"
}

# TLS 1.2
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Get-HttpErrorBody {
  param($Exception)
  try {
    $resp = $Exception.Response
    if (-not $resp) { return $null }
    $stream = $resp.GetResponseStream()
    if (-not $stream) { return $null }
    $reader = New-Object System.IO.StreamReader($stream)
    $txt = $reader.ReadToEnd()
    return $txt
  } catch {
    return $null
  }
}

function Invoke-NextDnsJson {
  param(
    [Parameter(Mandatory=$true)][string]$Method,
    [Parameter(Mandatory=$true)][string]$Url,
    [string]$BodyJson = $null,
    [int]$MaxRetries = 8
  )

  for ($try = 0; $try -lt $MaxRetries; $try++) {
    try {
      if ($BodyJson) {
        $r = Invoke-WebRequest -Method $Method -Uri $Url -Headers $Headers -Body $BodyJson -UseBasicParsing -ErrorAction Stop
      } else {
        $r = Invoke-WebRequest -Method $Method -Uri $Url -Headers $Headers -UseBasicParsing -ErrorAction Stop
      }

      $obj = $null
      if ($r.Content) {
        try { $obj = $r.Content | ConvertFrom-Json } catch { $obj = $null }
      }
      return @{ Ok=$true; Status=$r.StatusCode; Headers=$r.Headers; Json=$obj; Raw=$r.Content }
    }
    catch {
      $status = $null
      try { $status = [int]$_.Exception.Response.StatusCode } catch {}
      $body = Get-HttpErrorBody -Exception $_.Exception

      $retryAfter = $null
      try { $retryAfter = $_.Exception.Response.Headers["Retry-After"] } catch {}

      if ($status -eq 429) {
        $sleep = 5
        if ($retryAfter) {
          try { $sleep = [int]$retryAfter } catch { $sleep = 10 }
        } else {
          $sleep = [Math]::Min(60, 5 * ($try + 1))
        }
        Write-Warning "429 Too Many Requests. Sleep ${sleep}s and retry..."
        Start-Sleep -Seconds $sleep
        continue
      }

      return @{ Ok=$false; Status=$status; Error=$_.Exception.Message; Body=$body }
    }
  }

  return @{ Ok=$false; Status=429; Error="Max retries reached (429)"; Body=$null }
}

# ====== 1) List profiles ======
$profilesResp = Invoke-NextDnsJson -Method GET -Url "https://api.nextdns.io/profiles"
if (-not $profilesResp.Ok -or ($profilesResp.Json -and $profilesResp.Json.errors)) {
  Write-Error ("Cannot list profiles. Status={0} Body={1}" -f $profilesResp.Status, $profilesResp.Body)
  exit 1
}

Write-Host "`nProfiles disponibile:"
$profilesResp.Json.data | Select-Object id,name | Format-Table -AutoSize

$ProfileId = Read-Host "Introdu Profile ID (ex: 36565d) pe care vrei sa adaugi denylist-ul"
if (-not $ProfileId) { Write-Error "ProfileId lipsa."; exit 1 }

# ====== 2) Fetch full profile (includes denylist array) ======
$profileUrl = "https://api.nextdns.io/profiles/$ProfileId"
$profileResp = Invoke-NextDnsJson -Method GET -Url $profileUrl
if (-not $profileResp.Ok -or ($profileResp.Json -and $profileResp.Json.errors)) {
  Write-Error ("Cannot read profile. Status={0} Body={1}" -f $profileResp.Status, $profileResp.Body)
  exit 1
}

$profile = $profileResp.Json.data
$existingDeny = @()
if ($profile.denylist) { $existingDeny = $profile.denylist }

Write-Host ("`nExisting denylist entries in profile: {0}" -f $existingDeny.Count)

# Backup existing denylist
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$backupFile = Join-Path $PSScriptRoot ("nextdns_denylist_backup_{0}.json" -f $ts)
@{ data = $existingDeny } | ConvertTo-Json -Depth 10 | Out-File -FilePath $backupFile -Encoding UTF8
Write-Host ("Backup saved: {0}" -f $backupFile)

# Build map id -> active (preserve existing)
$denyMap = @{}
foreach ($e in $existingDeny) {
  if ($e -and $e.id) {
    $denyMap[$e.id.ToLower()] = [bool]$e.active
  }
}

# ====== 3) Download + normalize ONJN list ======
try {
  $content = (Invoke-WebRequest -Uri $OnjnUrlHttp -UseBasicParsing).Content
} catch {
  Write-Warning "Download HTTP a esuat. Incerc HTTPS..."
  $content = (Invoke-WebRequest -Uri $OnjnUrlHttps -UseBasicParsing).Content
}

$onjnDomains = $content -split "`r?`n" |
  ForEach-Object { $_.Trim().ToLower() } |
  Where-Object { $_ -and ($_ -notmatch '^\s*#') } |
  ForEach-Object { $_.Split('#')[0].Trim() } |
  ForEach-Object { $_ -replace '^\*\.', '' } |
  Where-Object { $_ -match '^[a-z0-9][a-z0-9\.-]*[a-z0-9]$' } |
  Sort-Object -Unique

Write-Host ("ONJN unique domains: {0}" -f $onjnDomains.Count)

$addedCount = 0
foreach ($d in $onjnDomains) {
  if (-not $denyMap.ContainsKey($d)) { $addedCount++ }
  $denyMap[$d] = $true
}

Write-Host ("Will add new domains (approx): {0}" -f $addedCount)
Write-Host ("Final denylist size will be: {0}" -f $denyMap.Count)

# Save normalized ONJN domains for audit
$onjnOut = Join-Path $PSScriptRoot ("onjn_domains_unique_{0}.txt" -f $ts)
$onjnDomains | Out-File -FilePath $onjnOut -Encoding UTF8
Write-Host ("Saved normalized ONJN list: {0}" -f $onjnOut)

# ====== 4) Build final denylist payload (ORDERED keys: id first, active second) ======
$finalList = @()
foreach ($k in ($denyMap.Keys | Sort-Object)) {
  $finalList += [ordered]@{ id = $k; active = $denyMap[$k] }
}

# Two payload variants:
$payloadWrapped = ([ordered]@{ data = $finalList } | ConvertTo-Json -Depth 10 -Compress)
$payloadArray   = ($finalList | ConvertTo-Json -Depth 10 -Compress)

# ====== 5) PUT denylist (bulk) ======
$denyUrl = "https://api.nextdns.io/profiles/$ProfileId/denylist"

Write-Host "`nUpdating denylist via PUT (bulk)..."

# Try wrapped first (most common JSON-API style), then raw array
$putResp = Invoke-NextDnsJson -Method PUT -Url $denyUrl -BodyJson $payloadWrapped
if (-not $putResp.Ok -or ($putResp.Json -and $putResp.Json.errors)) {
  Write-Warning ("PUT (wrapped) failed. Status={0}. Body={1}" -f $putResp.Status, $putResp.Body)
  Write-Warning "Trying PUT with raw array payload..."
  $putResp = Invoke-NextDnsJson -Method PUT -Url $denyUrl -BodyJson $payloadArray
}

if (-not $putResp.Ok) {
  Write-Error ("PUT failed. Status={0} Error={1} Body={2}" -f $putResp.Status, $putResp.Error, $putResp.Body)
  exit 1
}

if ($putResp.Json -and $putResp.Json.errors) {
  Write-Error ("PUT returned errors: " + ($putResp.Json.errors | ConvertTo-Json -Compress))
  exit 1
}

Write-Host "DONE. Denylist updated successfully."
