#Requires -Version 5.1
<#
.SYNOPSIS
    Removes Verse language support from the Helix editor.

.DESCRIPTION
    - Removes Verse stanzas from %APPDATA%\helix\languages.toml
    - Removes %APPDATA%\helix\runtime\queries\verse\
    - Removes %APPDATA%\helix\runtime\grammars\verse.dll
    - Removes %APPDATA%\helix\runtime\grammars\sources\verse\
    - Removes %APPDATA%\helix\verse-lsp-wrapper.ps1

    If languages.toml is empty after removing the Verse stanzas it is deleted.
    No other Helix configuration is touched.

.PARAMETER Force
    Skip the confirmation prompt.
#>
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

function Write-Step([string]$Message)    { Write-Host "  -> $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "  OK $Message" -ForegroundColor Green }
function Write-Warn([string]$Message)    { Write-Host "WARN $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message)    { Write-Host "FAIL $Message" -ForegroundColor Red }

function Remove-IfExists([string]$Path, [string]$Label) {
    if (Test-Path $Path) {
        Write-Step "Removing $Label"
        Remove-Item -Path $Path -Recurse -Force
        Write-Success "Removed: $Path"
    } else {
        Write-Host "  -- Not present: $Label" -ForegroundColor DarkGray
    }
}

# ─────────────────────────────────────────────
# Confirm
# ─────────────────────────────────────────────

$HelixConfig = Join-Path $env:APPDATA 'helix'

Write-Host ""
Write-Host "This will remove Verse language support from Helix:" -ForegroundColor White
Write-Host "  Config dir: $HelixConfig" -ForegroundColor DarkGray
Write-Host ""

if (-not $Force) {
    $Answer = 'n'
    try {
        $Answer = Read-Host "Continue? [y/N]"
    } catch {
        Write-Host "  (Non-interactive session — use -Force to skip this prompt.)" -ForegroundColor DarkGray
    }
    if ($Answer -notmatch '^[yY]') {
        Write-Host "Aborted." -ForegroundColor DarkGray
        exit 0
    }
}

# ─────────────────────────────────────────────
# Remove Verse stanzas from languages.toml
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "Updating languages.toml..." -ForegroundColor White

$UserToml = Join-Path $HelixConfig 'languages.toml'

if (Test-Path $UserToml) {
    Write-Step "Removing Verse stanzas from $UserToml"

    $Lines   = (Get-Content -Path $UserToml) + @('')
    $Stanzas = @()
    $Current = [System.Collections.Generic.List[string]]::new()

    foreach ($Line in $Lines) {
        if ($Line -match '^\s*\[' -and $Current.Count -gt 0) {
            $Stanzas += , $Current.ToArray()
            $Current  = [System.Collections.Generic.List[string]]::new()
        }
        $Current.Add($Line)
    }
    if ($Current.Count -gt 0) { $Stanzas += , $Current.ToArray() }

    $Filtered = $Stanzas | Where-Object {
        $Header = $_[0]
        $Body   = $_ -join "`n"
        -not (
            $Header -match '^\[language-server\.verse-lsp\]' -or
            ($Header -match '^\[\[language\]\]' -and $Body -match 'name\s*=\s*"verse"') -or
            ($Header -match '^\[\[grammar\]\]'  -and $Body -match 'name\s*=\s*"verse"')
        )
    }

    $Cleaned = (($Filtered | ForEach-Object { $_ -join "`n" }) -join "`n").Trim()

    if ($Cleaned -eq '') {
        Remove-Item -Path $UserToml -Force
        Write-Success "languages.toml was Verse-only — file removed"
    } else {
        Set-Content -Path $UserToml -Value $Cleaned -NoNewline
        Write-Success "Verse stanzas removed from languages.toml"
    }
} else {
    Write-Host "  -- languages.toml not found, nothing to clean" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────
# Remove installed files
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "Removing installed files..." -ForegroundColor White

Remove-IfExists (Join-Path $HelixConfig 'verse-lsp-wrapper.ps1')          'LSP wrapper script'
Remove-IfExists (Join-Path $HelixConfig 'runtime\queries\verse')           'query files'
Remove-IfExists (Join-Path $HelixConfig 'runtime\grammars\verse.dll')      'compiled grammar'
Remove-IfExists (Join-Path $HelixConfig 'runtime\grammars\sources\verse')  'grammar source'

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host " Verse support removed from Helix." -ForegroundColor Green
Write-Host "────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
