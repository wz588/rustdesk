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
      4. src/common.rs                 : load_custom_client() seeds
                                         DEFAULT_SETTINGS["access-mode"] = "full"

      (3) is what hides the update check everywhere, because RustDesk uses that single
      predicate to gate: common::check_software_update(), the Dart checkUpdate()
      handler, the "check update" entry in settings, and the update banner on the home
      page. With it enabled the client never contacts RustDesk's official update
      service.

      (4) makes "Full Access" the default for Settings -> Security -> Permissions,
      which is driven by the `access-mode` option. RustDesk only treats the exact
      value "full" as "every capability granted" (src/server/connection.rs ::
      is_permission_enabled_locally); any other value - including the unset default
      that a custom build ships with - falls through to the individual
      enable-keyboard / enable-clipboard / ... options, and the settings page then
      shows "Custom".

      Rather than touch that permission logic, the value is seeded through the option
      layer RustDesk already provides for exactly this purpose: Config::get_option
      resolves OVERWRITE_SETTINGS > user config > DEFAULT_SETTINGS, so an entry in
      DEFAULT_SETTINGS becomes the default while the dropdown stays usable - choosing
      Custom or Screen Share later saves a real value, which then wins. (An
      OVERWRITE_SETTINGS entry would instead grey the dropdown out, because
      is_option_fixed() reports it as locked.)

      DEFAULT_SETTINGS is per-process, which is why the seed goes into
      load_custom_client(): core_main.rs, service.rs and flutter_ffi.rs all call it
      early, so both the UI process and the service that actually serves incoming
      connections pick it up.

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

# (4) default the permission mode to "Full Access" - see the header for why this
# goes through DEFAULT_SETTINGS instead of OVERWRITE_SETTINGS, and why it is
# seeded from load_custom_client(). The regex anchors on the function signature
# so that a rename upstream fails the build instead of silently shipping a
# client that falls back to "Custom".
$AccessModeSeed = @'
pub fn load_custom_client() {
    // Custom client build: default the permission mode to "Full Access"
    // (Settings -> Security -> Permissions). DEFAULT_SETTINGS is only consulted
    // when neither an override nor the user config has a value, so the dropdown
    // stays usable and an explicit choice by the user still wins.
    if is_custom_client() {
        config::DEFAULT_SETTINGS
            .write()
            .unwrap()
            .insert("access-mode".to_owned(), "full".to_owned());
    }
'@

Set-SourceText -Path $commonRs `
    -Pattern 'pub fn load_custom_client\(\) \{' `
    -Replacement $AccessModeSeed `
    -Label 'access-mode default'

# --- verify the result really landed -----------------------------------------
$configText = [System.IO.File]::ReadAllText($hbbConfig)
$commonText = [System.IO.File]::ReadAllText($commonRs)
$checks = @(
    @{ Name = 'rendezvous server rewritten';  Ok = $configText.Contains('&["' + $RendezvousServer + '"]') },
    @{ Name = 'server public key rewritten';  Ok = $configText.Contains('"' + $RsPubKey + '"') },
    @{ Name = 'no official rendezvous left';  Ok = -not $configText.Contains('rs-ny.rustdesk.com') },
    @{ Name = 'no official pubkey left';      Ok = -not $configText.Contains('OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=') },
    @{ Name = 'is_custom_client() forced';    Ok = -not $commonText.Contains('get_app_name() != "RustDesk"') },
    @{ Name = 'permission default = full';    Ok = $commonText.Contains('"access-mode".to_owned(), "full".to_owned()') }
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
Write-Host "  permissions: access-mode defaults to Full Access"
