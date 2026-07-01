#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Verse language support for the Helix editor.

.DESCRIPTION
    - Merges languages.toml into %APPDATA%\helix\languages.toml
    - Copies query files to %APPDATA%\helix\runtime\queries\verse\
    - Auto-detects verse-lsp.exe from the VS Code Verse extension
    - Runs hx --grammar fetch and hx --grammar build verse

.PARAMETER Force
    Overwrite an existing Verse language configuration without prompting.
#>
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

function Write-Step([string]$Message) {
    Write-Host "  -> $Message" -ForegroundColor Cyan
}

function Write-Success([string]$Message) {
    Write-Host "  OK $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "WARN $Message" -ForegroundColor Yellow
}

function Write-Fail([string]$Message) {
    Write-Host "FAIL $Message" -ForegroundColor Red
}

# ─────────────────────────────────────────────
# Locate script root (repo directory)
# ─────────────────────────────────────────────

$RepoRoot = $PSScriptRoot

# ─────────────────────────────────────────────
# Check prerequisites
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "Checking prerequisites..." -ForegroundColor White

# Helix
if (-not (Get-Command hx -ErrorAction SilentlyContinue)) {
    Write-Fail "'hx' not found on PATH. Install Helix from https://helix-editor.com/ and add it to PATH."
    exit 1
}
$hxVersion = (hx --version 2>&1) | Select-Object -First 1
Write-Success "Helix: $hxVersion"

# git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Fail "'git' not found on PATH. Install Git from https://git-scm.com/ and add it to PATH."
    exit 1
}
$gitVersion = (git --version 2>&1) | Select-Object -First 1
Write-Success "git: $gitVersion"

# C compiler (required for hx --grammar build)
$CCompiler = $null
foreach ($cc in @('cl', 'clang', 'gcc')) {
    if (Get-Command $cc -ErrorAction SilentlyContinue) {
        $CCompiler = $cc
        break
    }
}
if ($null -eq $CCompiler) {
    Write-Fail "No C compiler found on PATH (tried: cl, clang, gcc)."
    Write-Warn "hx --grammar build requires a C compiler."
    Write-Warn "Options:"
    Write-Warn "  - Run this script from a Visual Studio Developer PowerShell (cl.exe)"
    Write-Warn "  - Install LLVM: winget install LLVM.LLVM"
    exit 1
}
Write-Success "C compiler: $CCompiler"

# ─────────────────────────────────────────────
# Locate verse-lsp.exe
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "Locating verse-lsp.exe..." -ForegroundColor White

$VscodePath = Join-Path $env:USERPROFILE '.vscode\extensions'
$LspCandidates = @()
if (Test-Path $VscodePath) {
    $LspCandidates = @(Get-ChildItem -Path $VscodePath -Filter 'epicgames.verse-*' -Directory |
        ForEach-Object { Join-Path $_.FullName 'bin\Win64\verse-lsp.exe' } |
        Where-Object { Test-Path $_ })
}

$VerseLspPath = $null
if ($LspCandidates.Count -gt 0) {
    # Pick the most recently installed version if there are multiple
    $VerseLspPath = $LspCandidates | Select-Object -Last 1
    Write-Success "verse-lsp.exe: $VerseLspPath"
} else {
    Write-Warn "verse-lsp.exe not found. The Verse language server will NOT be configured."
    Write-Warn "Install the Epic Games Verse extension in VS Code:"
    Write-Warn "  https://marketplace.visualstudio.com/items?itemName=EpicGames.verse"
    Write-Warn "Then re-run this script to enable LSP features."
}

# ─────────────────────────────────────────────
# Determine Helix config directory
# ─────────────────────────────────────────────

$HelixConfig = Join-Path $env:APPDATA 'helix'
Write-Host ""
Write-Host "Helix config directory: $HelixConfig" -ForegroundColor White

if (-not (Test-Path $HelixConfig)) {
    Write-Step "Creating Helix config directory..."
    New-Item -ItemType Directory -Force -Path $HelixConfig | Out-Null
}

# ─────────────────────────────────────────────
# Merge languages.toml
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "Configuring languages.toml..." -ForegroundColor White

$SourceToml = Get-Content -Path (Join-Path $RepoRoot 'languages.toml') -Raw

# Substitute wrapper script path
$WrapperDest      = Join-Path $HelixConfig 'verse-lsp-wrapper.ps1'
$WrapperEscaped   = $WrapperDest -replace '\\', '\\'
$SourceToml       = $SourceToml -replace '__WRAPPER_PATH__', $WrapperEscaped

# Substitute verse-lsp.exe path (TOML strings require backslashes escaped as \\)
if ($null -ne $VerseLspPath) {
    $TomlEscapedPath = $VerseLspPath -replace '\\', '\\'
    $SourceToml = $SourceToml -replace '__VERSE_LSP_PATH__', $TomlEscapedPath
} else {
    $SourceToml = $SourceToml -replace '__VERSE_LSP_PATH__', 'verse-lsp'
}

$UserToml = Join-Path $HelixConfig 'languages.toml'
$SkipToml = $false

if (Test-Path $UserToml) {
    $ExistingContent = Get-Content -Path $UserToml -Raw

    # Check if a verse language entry already exists
    if ($ExistingContent -match '(?m)^\[\[language\]\][\s\S]*?name\s*=\s*"verse"' -or
        $ExistingContent -match '(?m)^name\s*=\s*"verse"') {

        if (-not $Force) {
            Write-Warn "A Verse language entry already exists in $UserToml"
            $Answer = 'n'
            try {
                $Answer = Read-Host "Overwrite it? [y/N]"
            } catch {
                Write-Host "  (Non-interactive session — defaulting to skip. Use -Force to overwrite.)" -ForegroundColor DarkGray
            }
            if ($Answer -notmatch '^[yY]') {
                Write-Host "  Skipping languages.toml (use -Force to overwrite automatically)." -ForegroundColor DarkGray
                $SkipToml = $true
            }
        }
    }
}

if (-not ($SkipToml -eq $true)) {
    if (Test-Path $UserToml) {
        # Parse the existing TOML into stanzas (split on header lines starting with [ or [[)
        # and drop any stanzas that belong to Verse
        $Lines = (Get-Content -Path $UserToml) + @('')
        $Stanzas = @()
        $Current = [System.Collections.Generic.List[string]]::new()

        foreach ($Line in $Lines) {
            if ($Line -match '^\s*\[' -and $Current.Count -gt 0) {
                $Stanzas += , $Current.ToArray()
                $Current = [System.Collections.Generic.List[string]]::new()
            }
            $Current.Add($Line)
        }
        if ($Current.Count -gt 0) { $Stanzas += , $Current.ToArray() }

        $Filtered = $Stanzas | Where-Object {
            $Header = $_[0]
            $Body   = $_ -join "`n"
            -not (
                # Verse LSP server stanza
                $Header -match '^\[language-server\.verse-lsp\]' -or
                # Any malformed header containing "verse" in brackets (defensive)
                ($Header -match '^\[' -and $Header -match '"verse"') -or
                # [[language]] stanza with name = "verse"
                ($Header -match '^\[\[language\]\]' -and $Body -match 'name\s*=\s*"verse"') -or
                # [[grammar]] stanza with name = "verse"
                ($Header -match '^\[\[grammar\]\]'  -and $Body -match 'name\s*=\s*"verse"')
            )
        }

        $Cleaned = ($Filtered | ForEach-Object { $_ -join "`n" }) -join "`n"
        $Cleaned = $Cleaned.TrimEnd()
        Set-Content -Path $UserToml -Value ($Cleaned + "`n`n" + $SourceToml.TrimStart()) -NoNewline
    } else {
        Set-Content -Path $UserToml -Value $SourceToml -NoNewline
    }
    Write-Success "languages.toml updated: $UserToml"
}

# ─────────────────────────────────────────────
# Copy LSP wrapper script
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "Installing LSP wrapper..." -ForegroundColor White

$WrapperSrc  = Join-Path $RepoRoot 'verse-lsp-wrapper.ps1'
$WrapperDest = Join-Path $HelixConfig 'verse-lsp-wrapper.ps1'
Write-Step "Copying to $WrapperDest"
Copy-Item -Path $WrapperSrc -Destination $WrapperDest -Force
Write-Success "LSP wrapper installed"

# ─────────────────────────────────────────────
# Copy query files
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "Installing query files..." -ForegroundColor White

$QueryDest = Join-Path $HelixConfig 'runtime\queries\verse'
Write-Step "Copying to $QueryDest"
New-Item -ItemType Directory -Force -Path $QueryDest | Out-Null
Copy-Item -Path (Join-Path $RepoRoot 'queries\verse\*') -Destination $QueryDest -Force
Write-Success "Query files installed"

# ─────────────────────────────────────────────
# Fetch and build the Tree-sitter grammar
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "Fetching Tree-sitter grammar source..." -ForegroundColor White
Write-Step "Running: hx --grammar fetch"
hx --grammar fetch
# hx --grammar fetch exits non-zero if *any* grammar fails to fetch (e.g. unrelated grammars).
# Check specifically that the verse grammar was obtained before continuing.
$HelixRuntime = Join-Path $env:APPDATA 'helix\runtime\grammars'
$VerseGrammarFetched = Test-Path (Join-Path $HelixRuntime 'sources\verse')
if (-not $VerseGrammarFetched) {
    Write-Fail "The verse grammar source was not fetched. Check your internet connection and git installation."
    exit 1
}
Write-Success "Grammar source fetched"

Write-Host ""
Write-Host "Building Tree-sitter grammar..." -ForegroundColor White
Write-Step "Running: hx --grammar build verse"
hx --grammar build verse
# hx --grammar build exits non-zero if *any* grammar fails to build (e.g. unrelated grammars).
# Check specifically that the verse grammar .dll was produced.
$VerseGrammarBuilt = Test-Path (Join-Path $HelixRuntime 'verse.dll')
if (-not $VerseGrammarBuilt) {
    Write-Fail "The verse grammar did not build successfully."
    Write-Warn "Make sure a C compiler (cl.exe or clang) is on PATH."
    Write-Warn "Run this script from a Visual Studio Developer PowerShell, or install LLVM:"
    Write-Warn "  winget install LLVM.LLVM"
    exit 1
}
Write-Success "Grammar compiled"

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host " Verse support for Helix installed!" -ForegroundColor Green
Write-Host "────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host " Open any .verse file with:  hx example.verse"
Write-Host ""
if ($null -eq $VerseLspPath) {
    Write-Warn "LSP features are disabled. Install the VS Code Verse extension and re-run install.ps1."
}
