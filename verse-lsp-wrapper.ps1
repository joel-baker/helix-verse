#Requires -Version 5.1
<#
.SYNOPSIS
    LSP proxy wrapper for verse-lsp that injects workspace folders from .vproject.

.DESCRIPTION
    Helix sends only a single workspace root to the LSP server. verse-lsp needs
    multiple workspace folders (pointing at Verse stdlib .digest.verse files in
    AppData) to resolve symbols and enable goto-definition.

    This wrapper starts verse-lsp, intercepts the LSP initialize request, reads
    the .vproject from AppData, injects all required workspace folders, then
    forwards the modified request. All other traffic is forwarded byte-for-byte.

    A debug log is written to %TEMP%\verse-lsp-wrapper.log.

.PARAMETER LspBin
    Full path to verse-lsp.exe.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$LspBin
)

$ErrorActionPreference = 'Continue'
$LogFile = "$env:TEMP\verse-lsp-wrapper.log"

# ── Logging ──────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format 'HH:mm:ss.fff'
    "[$ts] $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

Write-Log "verse-lsp-wrapper starting. LspBin=$LspBin"

# ── Path helpers ──────────────────────────────────────────────────────────────

function ConvertFrom-FileUri {
    param([string]$Uri)
    if (-not $Uri) { return $null }
    $path = $Uri -replace '^file://', ''
    $path = [uri]::UnescapeDataString($path)
    # /C:/... -> C:\...
    $path = $path -replace '^/([A-Za-z]:)', '$1'
    return $path.Replace('/', '\')
}

function ConvertTo-FileUri {
    param([string]$Path)
    $fwd = $Path.Replace('\', '/')
    if ($fwd -match '^[A-Za-z]:') { $fwd = "/$fwd" }
    return "file://$fwd"
}

# ── Project discovery ─────────────────────────────────────────────────────────

function Find-VProjectFile {
    param([string]$StartDir)
    if (-not $StartDir) { return $null }

    $dir = $StartDir
    while ($dir) {
        $uefn = @(Get-ChildItem $dir -Filter '*.uefnproject' -File -ErrorAction SilentlyContinue)
        if ($uefn.Count -gt 0) {
            $projectName = [IO.Path]::GetFileNameWithoutExtension($uefn[0].Name)
            $vp = Join-Path $env:LOCALAPPDATA "UnrealEditorFortnite\Saved\VerseProject\$projectName\vproject\$projectName.vproject"
            if (Test-Path $vp) {
                Write-Log "Found vproject for '$projectName': $vp"
                return $vp
            }
            Write-Log "Found .uefnproject '$projectName' but no AppData vproject at: $vp"
        }
        $parent = [IO.Path]::GetDirectoryName($dir)
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    Write-Log "No .uefnproject found walking up from: $StartDir"
    return $null
}

function Build-WorkspaceFolders {
    param([string]$VProjectFile)

    $json = Get-Content $VProjectFile -Raw -Encoding utf8 | ConvertFrom-Json
    $folders = [System.Collections.Generic.List[psobject]]::new()

    # The vproject directory itself (verse-lsp needs this as the first entry)
    $vprojectDir = [IO.Path]::GetDirectoryName($VProjectFile)
    $folders.Add([PSCustomObject]@{
        name = $vprojectDir.Replace('\', '/')
        uri  = ConvertTo-FileUri $vprojectDir
    })

    foreach ($pkg in $json.packages) {
        $desc = $pkg.desc
        if (-not $desc -or -not $desc.dirPath) { continue }
        $role = if ($desc.settings) { $desc.settings.role } else { '' }
        if ($role -eq 'PersistenceCompatConstraint') { continue }
        if ($desc.dirPath -match '/published/') { continue }

        $folders.Add([PSCustomObject]@{
            name = $desc.dirPath
            uri  = ConvertTo-FileUri ($desc.dirPath.Replace('/', '\'))
        })
    }

    Write-Log "Built $($folders.Count) workspace folders:"
    foreach ($f in $folders) { Write-Log "  $($f.uri)" }
    return $folders
}

# ── LSP framing ───────────────────────────────────────────────────────────────

# Reads one LSP message from a raw Stream. Returns @{Body=[byte[]]} or $null on EOF.
function Read-LspMessage {
    param([System.IO.Stream]$Stream)

    $contentLength = -1
    $headerLine    = [System.Text.StringBuilder]::new()
    # State machine: 0=chars 1=CR 2=CRLF 3=CRLF+CR  (looking for \r\n\r\n)
    $state = 0
    $headersEnd = $false

    while (-not $headersEnd) {
        $b = $Stream.ReadByte()
        if ($b -eq -1) { return $null }

        if ($b -eq 13) {                    # CR
            if ($state -eq 2) { $state = 3 } else { $state = 1 }
        } elseif ($b -eq 10) {              # LF
            if ($state -eq 1) {
                $state = 2
                $line = $headerLine.ToString()
                if ($line -match '^Content-Length:\s*(\d+)') {
                    $contentLength = [int]$Matches[1]
                }
                [void]$headerLine.Clear()
            } elseif ($state -eq 3) {
                $headersEnd = $true         # \r\n\r\n  complete
            } else {
                $state = 0
            }
        } else {
            $state = 0
            [void]$headerLine.Append([char]$b)
        }
    }

    if ($contentLength -lt 0) { return $null }

    $body   = New-Object byte[] $contentLength
    $offset = 0
    while ($offset -lt $contentLength) {
        $n = $Stream.Read($body, $offset, $contentLength - $offset)
        if ($n -le 0) { return $null }
        $offset += $n
    }

    return @{ Body = $body }
}

# Writes one LSP message (Content-Length framed) to a Stream.
function Send-LspMessage {
    param([System.IO.Stream]$Stream, [byte[]]$Body)
    $header = [System.Text.Encoding]::ASCII.GetBytes("Content-Length: $($Body.Length)`r`n`r`n")
    $Stream.Write($header, 0, $header.Length)
    $Stream.Write($Body,   0, $Body.Length)
    $Stream.Flush()
}

# ── Start verse-lsp ───────────────────────────────────────────────────────────

if (-not (Test-Path $LspBin)) {
    Write-Log "ERROR: verse-lsp binary not found: $LspBin"
    exit 1
}

$psi = [System.Diagnostics.ProcessStartInfo]::new($LspBin)
$psi.UseShellExecute        = $false
$psi.RedirectStandardInput  = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $false   # let stderr pass through

$child = [System.Diagnostics.Process]::new()
$child.StartInfo = $psi
[void]$child.Start()
Write-Log "Started verse-lsp PID=$($child.Id)"

$childIn  = $child.StandardInput.BaseStream
$childOut = $child.StandardOutput.BaseStream
$helixIn  = [Console]::OpenStandardInput()
$helixOut = [Console]::OpenStandardOutput()

# ── Background runspace: child stdout → helix stdout ─────────────────────────

$fwdRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$fwdRunspace.Open()
$fwdRunspace.SessionStateProxy.SetVariable('src', $childOut)
$fwdRunspace.SessionStateProxy.SetVariable('dst', $helixOut)

$fwdPs = [System.Management.Automation.PowerShell]::Create()
$fwdPs.Runspace = $fwdRunspace
[void]$fwdPs.AddScript(@'
    $buf = New-Object byte[] 65536
    while ($true) {
        try {
            $n = $src.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $dst.Write($buf, 0, $n)
            $dst.Flush()
        } catch { break }
    }
'@)
$fwdHandle = $fwdPs.BeginInvoke()
Write-Log "Stdout-forward runspace started"

# ── Main loop: helix stdin → child stdin ──────────────────────────────────────

$initInjected = $false

while ($true) {
    $msg = Read-LspMessage $helixIn
    if ($null -eq $msg) {
        Write-Log "Helix stdin closed — shutting down"
        break
    }

    $bodyBytes = $msg.Body
    $forwarded = $false

    try {
        $jsonText = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
        $obj = $jsonText | ConvertFrom-Json

        if (-not $initInjected -and $obj.method -eq 'initialize') {
            $initInjected = $true
            Write-Log "Intercepted initialize. rootUri=$($obj.params.rootUri)"

            # Resolve project root
            $rootUri  = $obj.params.rootUri
            $startDir = if ($rootUri) { ConvertFrom-FileUri $rootUri } else { (Get-Location).Path }
            Write-Log "Walking up from: $startDir"

            $vprojectFile = Find-VProjectFile $startDir
            if ($vprojectFile) {
                $folders = @(Build-WorkspaceFolders $vprojectFile)

                # Replace workspaceFolders in params
                if ($obj.params | Get-Member workspaceFolders -ErrorAction SilentlyContinue) {
                    $obj.params.workspaceFolders = $folders
                } else {
                    $obj.params | Add-Member -NotePropertyName workspaceFolders -NotePropertyValue $folders
                }

                $newJson   = $obj | ConvertTo-Json -Depth 20 -Compress
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($newJson)
                Write-Log "Injected $($folders.Count) workspace folders into initialize"
            } else {
                Write-Log "No vproject found — forwarding initialize unchanged"
            }

        } elseif ($obj.method -eq 'shutdown') {
            # Forward shutdown to verse-lsp, then immediately ack Helix so it
            # doesn't wait for a response verse-lsp will never send.
            Send-LspMessage $childIn $bodyBytes
            $forwarded = $true
            $ackJson   = "{`"jsonrpc`":`"2.0`",`"id`":$($obj.id),`"result`":null}"
            $ackBytes  = [System.Text.Encoding]::UTF8.GetBytes($ackJson)
            Send-LspMessage $helixOut $ackBytes
            Write-Log "Forwarded shutdown and sent immediate ack to Helix (id=$($obj.id))"

        } elseif ($obj.method -eq 'exit') {
            # Forward exit then terminate immediately — no point waiting for verse-lsp.
            Send-LspMessage $childIn $bodyBytes
            $forwarded = $true
            Write-Log "Received exit notification — terminating"
            break
        }
    } catch {
        Write-Log "Error processing message: $_"
    }

    if (-not $forwarded) {
        Send-LspMessage $childIn $bodyBytes
    }
}

# ── Cleanup ───────────────────────────────────────────────────────────────────

try { $childIn.Close() } catch {}
try { if (-not $child.HasExited) { $child.Kill() } } catch {}
Write-Log "verse-lsp-wrapper exiting"
