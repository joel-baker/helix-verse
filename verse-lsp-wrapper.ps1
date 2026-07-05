#Requires -Version 5.1
<#
.SYNOPSIS
    LSP proxy wrapper for verse-lsp that injects workspace folders from .vproject.

.DESCRIPTION
    Helix sends only a single workspace root to the LSP server. verse-lsp needs
    multiple workspace folders (pointing at Verse stdlib .digest.verse files in
    AppData) to resolve symbols and enable goto-definition.

    This wrapper starts verse-lsp and handles the LSP initialize handshake
    synchronously so that the initializeResult (including server capabilities)
    can be logged. If workspace folders are known at initialize time (rootUri is
    set), they are injected directly. If rootUri is null (e.g. when launched via
    Explorer double-click), the wrapper waits for the first textDocument/didOpen
    notification, discovers the project from the opened file's path, and injects
    workspace folders via workspace/didChangeWorkspaceFolders before forwarding
    the notification to verse-lsp.

    Subsequent textDocument/didOpen notifications (from :edit or split-view) are
    checked against the currently-active project. If the opened file belongs to a
    different project, workspace/didChangeWorkspaceFolders is sent to swap folders
    before the notification is forwarded. If no project is found (e.g. a built-in
    engine file), the current folders are preserved unchanged.

    A debug log is written to %TEMP%\verse-lsp-wrapper.log.

.PARAMETER LspBin
    Full path to verse-lsp.exe.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$LspBin
)

$ErrorActionPreference = 'Continue'
$LogFile    = "$env:TEMP\verse-lsp-wrapper.log"
$VerboseLog = $false  # set to $true to enable full message body logging for debugging

# ── Logging ──────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format 'HH:mm:ss.fff'
    "[$ts] $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Write-VerboseLog {
    param([string]$Message)
    if ($script:VerboseLog) { Write-Log $Message }
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
                Write-VerboseLog "Found vproject for '$projectName': $vp"
                return $vp
            }
            Write-Log "WARNING: Found .uefnproject '$projectName' but no AppData vproject at: $vp"
        }
        $parent = [IO.Path]::GetDirectoryName($dir)
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    Write-VerboseLog "No .uefnproject found walking up from: $StartDir"
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

    Write-VerboseLog "Built $($folders.Count) workspace folders:"
    foreach ($f in $folders) { Write-VerboseLog "  $($f.uri)" }
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

function Start-ForwardRunspace {
    param(
        [System.IO.Stream]$Src,
        [System.IO.Stream]$Dst,
        [string]$LogPath
    )
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('src', $Src)
    $rs.SessionStateProxy.SetVariable('dst', $Dst)
    $rs.SessionStateProxy.SetVariable('logPath', $LogPath)
    $rs.SessionStateProxy.SetVariable('verboseLog', $VerboseLog)
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript(@'
        function FwdLog([string]$m) {
            if (-not $verboseLog) { return }
            $ts = (Get-Date -Format 'HH:mm:ss.fff')
            "[$ts] [verse-lsp→helix] $m" | Out-File -FilePath $logPath -Append -Encoding utf8
        }
        $hdr = [System.Text.StringBuilder]::new()
        while ($true) {
            try {
                # Parse LSP frame from verse-lsp
                $contentLength = -1
                $hdr.Clear()
                $state = 0
                $headersEnd = $false
                while (-not $headersEnd) {
                    $b = $src.ReadByte()
                    if ($b -eq -1) { return }
                    if ($b -eq 13) {
                        if ($state -eq 2) { $state = 3 } else { $state = 1 }
                    } elseif ($b -eq 10) {
                        if ($state -eq 1) {
                            $state = 2
                            $line = $hdr.ToString()
                            if ($line -match '^Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
                            [void]$hdr.Clear()
                        } elseif ($state -eq 3) { $headersEnd = $true }
                        else { $state = 0 }
                    } else { $state = 0; [void]$hdr.Append([char]$b) }
                }
                if ($contentLength -lt 0) { return }
                $body = New-Object byte[] $contentLength
                $offset = 0
                while ($offset -lt $contentLength) {
                    $n = $src.Read($body, $offset, $contentLength - $offset)
                    if ($n -le 0) { return }
                    $offset += $n
                }
                $bodyText = [System.Text.Encoding]::UTF8.GetString($body)
                FwdLog $bodyText
                # Forward to Helix
                $hdrBytes = [System.Text.Encoding]::ASCII.GetBytes("Content-Length: $contentLength`r`n`r`n")
                $dst.Write($hdrBytes, 0, $hdrBytes.Length)
                $dst.Write($body, 0, $body.Length)
                $dst.Flush()
            } catch {
                $ts = (Get-Date -Format 'HH:mm:ss.fff')
                "[$ts] [verse-lsp→helix] ERROR: $_" | Out-File -FilePath $logPath -Append -Encoding utf8
                break
            }
        }
'@)
    [void]$ps.BeginInvoke()
    return $ps
}

# ── Project state ─────────────────────────────────────────────────────────────

# Tracks the currently-active .vproject file and its workspace folders.
# $projectCache maps directory path → vproject path (only positive results cached).
$currentVProjectFile = $null
$currentFolders      = [System.Collections.Generic.List[psobject]]::new()
$projectCache        = @{}

# Finds the vproject for a file URI and, if it differs from the current project,
# sends workspace/didChangeWorkspaceFolders to verse-lsp and updates state.
# Pass the verse-lsp stdin stream as $ChildIn.
function Invoke-ProjectSwapIfNeeded {
    param(
        [string]$DocUri,
        [System.IO.Stream]$ChildIn
    )

    $docPath = ConvertFrom-FileUri $DocUri
    if (-not $docPath) { return }
    $fileDir = [IO.Path]::GetDirectoryName($docPath)
    if (-not $fileDir) { return }

    # Resolve vproject — cache all results including $null to avoid filesystem
    # walks on every hover/completion event (hot path after this fix).
    if ($script:projectCache.ContainsKey($fileDir)) {
        $vprojectFile = $script:projectCache[$fileDir]
    } else {
        $vprojectFile = Find-VProjectFile $fileDir
        $script:projectCache[$fileDir] = $vprojectFile  # cache $null too
    }

    if (-not $vprojectFile) {
        return
    }

    if ($vprojectFile -eq $script:currentVProjectFile) {
        return
    }

    Write-Log "Project changed: '$([IO.Path]::GetFileNameWithoutExtension($script:currentVProjectFile))' → '$([IO.Path]::GetFileNameWithoutExtension($vprojectFile))'"
    $newFolders = Build-WorkspaceFolders $vprojectFile

    $changeNotif = [PSCustomObject]@{
        jsonrpc = '2.0'
        method  = 'workspace/didChangeWorkspaceFolders'
        params  = [PSCustomObject]@{
            event = [PSCustomObject]@{
                added   = $newFolders
                removed = $script:currentFolders
            }
        }
    }
    $changeJson  = $changeNotif | ConvertTo-Json -Depth 20 -Compress
    $changeBytes = [System.Text.Encoding]::UTF8.GetBytes($changeJson)
    Write-VerboseLog "Sending workspace/didChangeWorkspaceFolders: $changeJson"
    Send-LspMessage $ChildIn $changeBytes

    $script:currentVProjectFile = $vprojectFile
    $script:currentFolders      = $newFolders
    Write-Log "Workspace swap complete — $($newFolders.Count) folders active"
}

# ── Init handshake (synchronous — background runspace not yet started) ────────

# Step 1: Read 'initialize' from Helix, inject workspace folders, forward to verse-lsp.
Write-VerboseLog "Waiting for initialize from Helix..."
$initMsg = Read-LspMessage $helixIn
if ($null -eq $initMsg) {
    Write-Log "ERROR: Helix closed stdin before sending initialize"
    exit 1
}

$initBodyBytes = $initMsg.Body
try {
    $initJson = [System.Text.Encoding]::UTF8.GetString($initBodyBytes)
    $initObj  = $initJson | ConvertFrom-Json
    Write-Log "initialize: rootUri=$($initObj.params.rootUri)"

    $rootUri  = $initObj.params.rootUri
    $startDir = if ($rootUri) { ConvertFrom-FileUri $rootUri } else { $null }

    if ($startDir) {
        Write-VerboseLog "Walking up from: $startDir"
        $vprojectFile = Find-VProjectFile $startDir
        if ($vprojectFile) {
            $folders = Build-WorkspaceFolders $vprojectFile

            if ($initObj.params | Get-Member workspaceFolders -ErrorAction SilentlyContinue) {
                $initObj.params.workspaceFolders = $folders
            } else {
                $initObj.params | Add-Member -NotePropertyName workspaceFolders -NotePropertyValue $folders
            }

            $initBodyBytes = [System.Text.Encoding]::UTF8.GetBytes(($initObj | ConvertTo-Json -Depth 20 -Compress))
            $script:currentVProjectFile = $vprojectFile
            $script:currentFolders      = $folders
            Write-Log "Injected $($folders.Count) workspace folders into initialize for '$([IO.Path]::GetFileNameWithoutExtension($vprojectFile))'"
        } else {
            Write-Log "No vproject found from rootUri — will inject at textDocument/didOpen"
        }
    } else {
        Write-Log "rootUri is null — will inject workspace folders at textDocument/didOpen"
    }
} catch {
    Write-Log "ERROR processing initialize: $_ — forwarding unchanged"
}

Send-LspMessage $childIn $initBodyBytes
Write-VerboseLog "Forwarded initialize to verse-lsp"

# Step 2: Read 'initializeResult' from verse-lsp, log capabilities, forward to Helix.
Write-VerboseLog "Waiting for initializeResult from verse-lsp..."
$initResult = Read-LspMessage $childOut
if ($null -eq $initResult) {
    Write-Log "ERROR: verse-lsp closed stdout before sending initializeResult"
    exit 1
}
$initResultJson = [System.Text.Encoding]::UTF8.GetString($initResult.Body)
Write-VerboseLog "initializeResult: $initResultJson"
try {
    $initResultObj = $initResultJson | ConvertFrom-Json
    $wfCap = $initResultObj.result.capabilities.workspace.workspaceFolders
    Write-Log "workspace.workspaceFolders: supported=$($wfCap.supported) changeNotifications=$($wfCap.changeNotifications)"
} catch {
    Write-Log "WARNING: Could not parse workspace.workspaceFolders capability: $_"
}

Send-LspMessage $helixOut $initResult.Body
Write-VerboseLog "Forwarded initializeResult to Helix"

# Step 3: Read 'initialized' from Helix, forward to verse-lsp.
Write-VerboseLog "Waiting for initialized from Helix..."
$initializedMsg = Read-LspMessage $helixIn
if ($null -eq $initializedMsg) {
    Write-Log "ERROR: Helix closed stdin before sending initialized"
    exit 1
}
Send-LspMessage $childIn $initializedMsg.Body
Write-VerboseLog "Forwarded initialized to verse-lsp"

# Step 4: Synchronously drain server→client requests after 'initialized'.
# verse-lsp sends client/registerCapability before Helix ACKs it.
# Helix's send order is: initialized → textDocument/didOpen → registerCapability ACK.
# So we must buffer any non-ACK Helix messages until the real ACK arrives, then
# process the buffer (which triggers workspace injection for any buffered didOpen).
Write-VerboseLog "Draining server→client requests synchronously..."

$pendingBuffer = [System.Collections.Generic.List[byte[]]]::new()
$draining      = $true
$drainCount    = 0
$maxDrainMsgs  = 20   # safety valve: bail out if server floods us without registerCapability

while ($draining) {
    $serverMsg = Read-LspMessage $childOut
    if ($null -eq $serverMsg) {
        Write-Log "ERROR: verse-lsp closed stdout during post-init drain"
        exit 1
    }
    $serverJson = [System.Text.Encoding]::UTF8.GetString($serverMsg.Body)
    Write-VerboseLog "[verse-lsp→helix sync] $serverJson"
    Send-LspMessage $helixOut $serverMsg.Body
    $drainCount++

    try {
        $serverObj = $serverJson | ConvertFrom-Json

        if ($serverObj.method -eq 'client/registerCapability') {
            Write-VerboseLog "Intercepted client/registerCapability (id=$($serverObj.id)) — buffering Helix messages until ACK"
            $regCapId = $serverObj.id

            # Inner loop: buffer non-ACK Helix messages until the real ACK arrives.
            while ($true) {
                $helixMsg = Read-LspMessage $helixIn
                if ($null -eq $helixMsg) {
                    Write-Log "ERROR: Helix stdin closed while waiting for registerCapability ACK"
                    exit 1
                }
                $helixJson = [System.Text.Encoding]::UTF8.GetString($helixMsg.Body)
                $helixObj  = $helixJson | ConvertFrom-Json

                # ACK detection: has 'id' matching the request + no 'method' field.
                $hasMatchingId = ($null -ne $helixObj.id -and [string]$helixObj.id -eq [string]$regCapId)
                $hasMethod     = ($helixObj | Get-Member 'method' -MemberType NoteProperty -ErrorAction SilentlyContinue) -ne $null

                if ($hasMatchingId -and -not $hasMethod) {
                    Write-VerboseLog "[helix→verse-lsp sync ACK] $helixJson"
                    Send-LspMessage $childIn $helixMsg.Body
                    Write-VerboseLog "registerCapability ACK confirmed — drain complete"
                    $draining = $false
                    break
                } else {
                    Write-VerboseLog "[helix→verse-lsp buffered] $helixJson"
                    $pendingBuffer.Add($helixMsg.Body)
                }
            }
        } elseif ($drainCount -ge $maxDrainMsgs) {
            Write-Log "WARNING: drain safety valve reached ($maxDrainMsgs messages) without client/registerCapability — proceeding"
            $draining = $false
        }
        # Notifications (no id) and other messages: forward already done above, keep draining.
    } catch {
        Write-Log "ERROR parsing server message during drain: $_ — proceeding"
        $draining = $false
    }
}

# Step 5: If rootUri was null and we found a workspace from the buffered didOpen,
# restart verse-lsp so it initializes WITH the workspace folders (matching the
# working-case path where folders are injected directly into 'initialize').
# From Helix's perspective the handshake is already complete; we secretly replace
# the verse-lsp process behind the scenes.

if ($null -eq $script:currentVProjectFile) {
    # Scan the pending buffer for a textDocument/didOpen we can use to find the workspace.
    $restartVProject = $null
    $restartFolders  = $null

    foreach ($bufferedBytes in $pendingBuffer) {
        try {
            $bJson = [System.Text.Encoding]::UTF8.GetString($bufferedBytes)
            $bObj  = $bJson | ConvertFrom-Json
            if ($bObj.method -eq 'textDocument/didOpen') {
                $docPath = ConvertFrom-FileUri $bObj.params.textDocument.uri
                $fileDir = [IO.Path]::GetDirectoryName($docPath)
                $vf      = Find-VProjectFile $fileDir
                if ($vf) {
                    $restartVProject = $vf
                    $restartFolders  = Build-WorkspaceFolders $vf
                    break
                }
            }
        } catch {}
    }

    if ($restartVProject) {
        Write-Log "Restarting verse-lsp with $($restartFolders.Count) workspace folders for '$([IO.Path]::GetFileNameWithoutExtension($restartVProject))'..."

        # Kill the first verse-lsp instance (it has no workspace).
        try { $childIn.Close() }  catch {}
        try { $childOut.Close() } catch {}
        try { if (-not $child.HasExited) { $child.Kill() } } catch {}
        Write-VerboseLog "Old verse-lsp (PID=$($child.Id)) terminated"

        # Start a fresh verse-lsp instance.
        $psi2 = [System.Diagnostics.ProcessStartInfo]::new($LspBin)
        $psi2.UseShellExecute        = $false
        $psi2.RedirectStandardInput  = $true
        $psi2.RedirectStandardOutput = $true
        $child = [System.Diagnostics.Process]::new()
        $child.StartInfo = $psi2
        [void]$child.Start()
        Write-VerboseLog "New verse-lsp started PID=$($child.Id)"

        $childIn  = $child.StandardInput.BaseStream
        $childOut = $child.StandardOutput.BaseStream

        # Inject workspace folders into a copy of the original initialize params.
        if ($initObj.params | Get-Member workspaceFolders -ErrorAction SilentlyContinue) {
            $initObj.params.workspaceFolders = $restartFolders
        } else {
            $initObj.params | Add-Member -NotePropertyName workspaceFolders -NotePropertyValue $restartFolders
        }
        $initBytes2 = [System.Text.Encoding]::UTF8.GetBytes(($initObj | ConvertTo-Json -Depth 20 -Compress))
        Send-LspMessage $childIn $initBytes2
        Write-VerboseLog "Sent initialize (with workspace folders) to new verse-lsp"

        # Read and discard initializeResult — Helix already has it from instance 1.
        $initResult2 = Read-LspMessage $childOut
        if ($null -eq $initResult2) {
            Write-Log "ERROR: new verse-lsp closed stdout before sending initializeResult"
            exit 1
        }
        Write-VerboseLog "Received initializeResult from new verse-lsp (discarding — Helix already has it)"

        # Send 'initialized' — Helix already sent this; replay it internally.
        $initNotifBytes = [System.Text.Encoding]::UTF8.GetBytes('{"jsonrpc":"2.0","method":"initialized","params":{}}')
        Send-LspMessage $childIn $initNotifBytes
        Write-VerboseLog "Sent initialized to new verse-lsp"

        # Drain new verse-lsp's post-init requests. Handle client/registerCapability
        # internally (Helix already ACKed it for instance 1, don't send again).
        $internalDrainCount = 0
        $internalDraining   = $true
        while ($internalDraining) {
            $sMsg = Read-LspMessage $childOut
            if ($null -eq $sMsg) {
                Write-Log "ERROR: new verse-lsp closed stdout during internal drain"
                exit 1
            }
            $sJson = [System.Text.Encoding]::UTF8.GetString($sMsg.Body)
            Write-VerboseLog "[new verse-lsp internal drain] $sJson"
            $internalDrainCount++

            try {
                $sObj = $sJson | ConvertFrom-Json
                if ($sObj.method -eq 'client/registerCapability') {
                    $ackBytes2 = [System.Text.Encoding]::UTF8.GetBytes(
                        "{`"jsonrpc`":`"2.0`",`"id`":$($sObj.id),`"result`":null}")
                    Send-LspMessage $childIn $ackBytes2
                    Write-Log "Internally ACKed client/registerCapability — restart complete"
                    $internalDraining = $false
                } elseif ($internalDrainCount -ge 20) {
                    Write-Log "WARNING: internal drain safety valve — proceeding"
                    $internalDraining = $false
                }
            } catch {
                Write-Log "ERROR in internal drain: $_ — proceeding"
                $internalDraining = $false
            }
        }

        $script:currentVProjectFile = $restartVProject
        $script:currentFolders      = $restartFolders
        Write-Log "verse-lsp restart complete — $($restartFolders.Count) folders active"
    } else {
        Write-Log "No workspace found in buffered messages — continuing without restart"
    }
}

# Step 6: Start background byte pump for all subsequent verse-lsp → Helix traffic.
$fwdPs = Start-ForwardRunspace -Src $childOut -Dst $helixOut -LogPath $LogFile
Write-VerboseLog "Stdout-forward runspace started"

# ── Flush buffered Helix messages to verse-lsp ────────────────────────────────

Write-VerboseLog "Flushing $($pendingBuffer.Count) buffered message(s) to verse-lsp..."
foreach ($bufferedBytes in $pendingBuffer) {
    try {
        $bufferedJson = [System.Text.Encoding]::UTF8.GetString($bufferedBytes)
        $bufferedObj  = $bufferedJson | ConvertFrom-Json
        Write-VerboseLog "[helix→verse-lsp buffered flush] $bufferedJson"

        # If no restart occurred (workspace not found), try dynamic injection as a fallback.
        if ($null -eq $script:currentVProjectFile -and
            $bufferedObj.method -like 'textDocument/*' -and
            $bufferedObj.method -ne 'textDocument/didClose') {
            $docUri = $bufferedObj.params.textDocument.uri
            if ($docUri) { Invoke-ProjectSwapIfNeeded -DocUri $docUri -ChildIn $childIn }
        }
    } catch {
        Write-Log "ERROR processing buffered message: $_"
    }
    Send-LspMessage $childIn $bufferedBytes
}

# ── Main loop: helix stdin → child stdin ──────────────────────────────────────

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

        if ($obj.method -like 'textDocument/*' -and $obj.method -ne 'textDocument/didClose') {
            $docUri = $obj.params.textDocument.uri
            if ($docUri) { Invoke-ProjectSwapIfNeeded -DocUri $docUri -ChildIn $childIn }

        } elseif ($obj.method -eq 'shutdown') {
            # Close verse-lsp stdout so the background pump's ReadByte() returns -1
            # immediately, ending the pump loop. This avoids the blocking Stop() call
            # and eliminates the concurrent-write race on $helixOut.
            try { $childOut.Close() } catch {}
            Send-LspMessage $childIn $bodyBytes
            $forwarded = $true
            $ackJson  = "{`"jsonrpc`":`"2.0`",`"id`":$($obj.id),`"result`":null}"
            $ackBytes = [System.Text.Encoding]::UTF8.GetBytes($ackJson)
            Send-LspMessage $helixOut $ackBytes
            Write-Log "Forwarded shutdown and sent immediate ack to Helix (id=$($obj.id))"

        } elseif ($obj.method -eq 'exit') {
            Send-LspMessage $childIn $bodyBytes
            $forwarded = $true
            Write-Log "Received exit notification — terminating"
            break
        }
    } catch {
        Write-Log "Error processing message: $_"
    }

    if (-not $forwarded) {
        Write-VerboseLog "[helix→verse-lsp] $jsonText"
        Send-LspMessage $childIn $bodyBytes
    }
}

# ── Cleanup ───────────────────────────────────────────────────────────────────

try { $childIn.Close() } catch {}
try { if (-not $child.HasExited) { $child.Kill() } } catch {}
Write-Log "verse-lsp-wrapper exiting"
