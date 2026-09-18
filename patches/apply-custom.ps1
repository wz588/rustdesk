<#
    Applies this fork's custom-client modifications to a clean RustDesk checkout.

    Why a script instead of `git apply` + .patch files:
      The previous patches were generated against an older RustDesk (they referenced
      "RELAY_SERVERS" / "UPDATE_URL" / a placeholder in place of the real public key,
      and a Dart file that no longer exists), so `git apply` always failed. These
      replacements are anchored on the *current* source text and fail loudly when
      upstream drifts, instead of silently producing an unmodified client.

    Customisations applied
      1. libs/hbb_common/src/config.rs : RENDEZVOUS_SERVERS  -> self-hosted server
      2. libs/hbb_common/src/config.rs : RS_PUB_KEY          -> self-hosted server public key
      3. src/common.rs                 : is_custom_client()  -> always true

      (3) is what hides the update check everywhere, because RustDesk uses that single
      predicate to gate: common::check_software_update(), the Dart checkUpdate()
      handler, the "check update" entry in settings, and the update banner on the home
      page. With it enabled the client never contacts RustDesk's official update
      service.

    Note: libs/hbb_common is a git submodule, so git apply would touch a submodule
    working tree; a plain text rewrite avoids that whole class of problems.
#>

$ErrorActionPreference = 'Stop'

$RendezvousServer = 'rustdesk.newdebao.com'
$RsPubKey         = 'zp4ev7m8mR2hqMB4hjxxH9GbroH8tzW8VbPYW4a5ufo='

# Resolve everything from this script's own location (patches/ lives at the repo
# root) so the caller's working directory never matters.
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Set-SourceText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Replacement,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "[$Label] file not found: $Path"
    }

    $text = [System.IO.File]::ReadAllText($Path)
    $regex = [regex]::new($Pattern)
    $hits = $regex.Matches($text).Count

    if ($hits -ne 1) {
        throw "[$Label] expected exactly 1 match of /$Pattern/ in $Path but found $hits. " +
              "Upstream source has drifted - update patches/apply-custom.ps1."
    }

    $text = $regex.Replace($text, $Replacement, 1)
    [System.IO.File]::WriteAllText($Path, $text)
    Write-Host "[ok] $Label"
}

$hbbConfig = Join-Path $RepoRoot 'libs/hbb_common/src/config.rs'
$commonRs  = Join-Path $RepoRoot 'src/common.rs'

Set-SourceText -Path $hbbConfig `
    -Pattern 'pub const RENDEZVOUS_SERVERS: &\[&str\] = &\[[^\]]*\];' `
    -Replacement ('pub const RENDEZVOUS_SERVERS: &[&str] = &["' + $RendezvousServer + '"];') `
    -Label 'RENDEZVOUS_SERVERS'

Set-SourceText -Path $hbbConfig `
    -Pattern 'pub const RS_PUB_KEY: &str = "[^"]*";' `
    -Replacement ('pub const RS_PUB_KEY: &str = "' + $RsPubKey + '";') `
    -Label 'RS_PUB_KEY'

Set-SourceText -Path $commonRs `
    -Pattern 'get_app_name\(\) != "RustDesk"' `
    -Replacement 'true /* custom client build: never contact the official update service */' `
    -Label 'is_custom_client()'

# --- verify the result really landed -----------------------------------------
$configText = [System.IO.File]::ReadAllText($hbbConfig)
$commonText = [System.IO.File]::ReadAllText($commonRs)
$checks = @(
    @{ Name = 'rendezvous server rewritten';  Ok = $configText.Contains('&["' + $RendezvousServer + '"]') },
    @{ Name = 'server public key rewritten';  Ok = $configText.Contains('"' + $RsPubKey + '"') },
    @{ Name = 'no official rendezvous left';  Ok = -not $configText.Contains('rs-ny.rustdesk.com') },
    @{ Name = 'no official pubkey left';      Ok = -not $configText.Contains('OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=') },
    @{ Name = 'is_custom_client() forced';    Ok = -not $commonText.Contains('get_app_name() != "RustDesk"') }
)

$failed = @($checks | Where-Object { -not $_.Ok })
foreach ($c in $checks) {
    Write-Host ("[{0}] {1}" -f $(if ($c.Ok) { 'ok' } else { 'FAIL' }), $c.Name)
}
if ($failed.Count -gt 0) {
    throw ('custom client verification failed: ' + (($failed | ForEach-Object { $_.Name }) -join ', '))
}

Write-Host ''
Write-Host 'Custom client modifications applied and verified.'
Write-Host "  rendezvous : $RendezvousServer"
Write-Host "  public key : $RsPubKey"
