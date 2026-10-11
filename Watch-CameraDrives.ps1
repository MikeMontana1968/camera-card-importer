<#
.SYNOPSIS
    Background watcher: imports camera media whenever a card or USB drive appears.

.DESCRIPTION
    Sleeps on a WMI volume-arrival indication and, on every wake, rescans all
    removable drives. Rescanning rather than trusting the event payload means a
    drive that arrives during a hiccup, or whose letter shows up late, still gets
    picked up. A 15-second timeout on the wait doubles as a safety poll.

    Volumes are remembered by serial number while they stay plugged in, so a card
    is never imported twice in one insertion, and a drive holding no camera media
    -- a gcode card, a plain USB stick -- is examined once and then left alone.

.PARAMETER Once
    Scan a single time and exit. Useful for testing.
#>
[CmdletBinding()]
param(
    [string] $CanonRoot = (Join-Path $env:USERPROFILE 'CameraImports\Canon'),
    [string] $GoProRoot = (Join-Path $env:USERPROFILE 'CameraImports\GoPro'),
    [switch] $KeepOriginals,
    [switch] $Eject,
    [switch] $Once,
    [switch] $Quiet,
    [string] $LogPath = (Join-Path $env:LOCALAPPDATA 'CameraImport\import.log')
)

$ErrorActionPreference = 'Stop'
$ImportScript = Join-Path $PSScriptRoot 'Import-CameraMedia.ps1'
$SourceId = 'CameraVolumeChange'

# For Show-Toast and Get-CardIdentity. The importer dot-sources this too; the
# watcher needs it to name the camera before handing off.
. (Join-Path $PSScriptRoot 'MediaLib.ps1')

# Detection toasts sit on the hot path -- Show-Toast blocks for its dwell, so
# keep these brief. The completion toast raised by the importer stays at 6s.
$DetectDwellMs = 2500

function Write-WatchLog {
    param([string] $Message, [string] $Level = 'INFO')
    $line = '{0} [{1}] (watcher) {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $written = Write-LogLine -Path $LogPath -Line $line
    # The watcher runs hidden, so a warning stream would go nowhere. Say it once
    # in the place the user will actually look: a toast.
    if ($written -ne 'ok' -and -not $script:LogDivertWarned) {
        $script:LogDivertWarned = $true
        Show-Toast -Title 'Camera import: log locked' `
            -Text ("Another process is holding`n{0}`nEntries are going to .locked" -f $LogPath) `
            -DwellMs $DetectDwellMs -Quiet:$Quiet
    }
    Write-Verbose $line
}

# Only one watcher per logon session.
$created = $false
$mutex = New-Object Threading.Mutex($true, 'Local\CameraImportWatcher', [ref] $created)
if (-not $created) {
    Write-WatchLog 'Another watcher is already running -- exiting.' 'WARN'
    return
}

$seen = @{}

function Test-DriveReady {
    <# A freshly mounted card can report its letter before the tree is browsable. #>
    param([string] $Root, [int] $TimeoutSeconds = 12)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            if (Test-Path -LiteralPath (Join-Path $Root 'DCIM')) { return $true }
            if (Test-Path -LiteralPath $Root) {
                # Root is readable but has no DCIM -- not a camera card.
                Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop | Out-Null
                return $false
            }
        }
        catch { }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Invoke-Scan {
    $present = @{}
    $disks = @()
    try {
        $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 2' -ErrorAction Stop)
    }
    catch {
        Write-WatchLog ("could not enumerate drives: {0}" -f $_.Exception.Message) 'WARN'
        return
    }

    foreach ($d in $disks) {
        # An empty card reader holds a drive letter but has no volume serial.
        if ([string]::IsNullOrEmpty($d.VolumeSerialNumber)) { continue }
        $key = '{0}|{1}' -f $d.DeviceID, $d.VolumeSerialNumber
        $present[$key] = $true
        if ($seen.ContainsKey($key)) { continue }

        $root = $d.DeviceID + '\'
        $label = if ([string]::IsNullOrWhiteSpace($d.VolumeName)) { $d.DeviceID }
                 else { '{0} ({1})' -f $d.DeviceID, $d.VolumeName }
        Write-WatchLog ("new volume {0} '{1}' -- checking" -f $d.DeviceID, $d.VolumeName)

        # Stage 1 -- fires for any removable volume, before we know what it holds.
        Show-Toast -Title 'Drive detected' -Text ("{0}`nchecking for camera media..." -f $label) `
            -DwellMs $DetectDwellMs -Quiet:$Quiet

        if (-not (Test-DriveReady $root)) {
            Write-WatchLog ("{0} has no DCIM folder -- ignoring" -f $d.DeviceID)
            # Stage 2a -- say so, rather than leaving the first toast unanswered.
            Show-Toast -Title 'No camera media' -Text ("{0}`nnothing to import." -f $label) `
                -DwellMs $DetectDwellMs -Quiet:$Quiet
            $seen[$key] = $true
            continue
        }

        # Stage 2b ("<vendor> card -- importing...") is raised by the importer,
        # not here: a DCIM folder alone does not mean there is anything to
        # import, and promising an import that never happens is worse than
        # announcing it a moment later.
        try {
            $splat = @{
                Drive     = $d.DeviceID
                CanonRoot = $CanonRoot
                GoProRoot = $GoProRoot
                LogPath   = $LogPath
            }
            if ($KeepOriginals) { $splat.KeepOriginals = $true }
            if ($Eject) { $splat.Eject = $true }
            & $ImportScript @splat | Out-Null
        }
        catch {
            Write-WatchLog ("import of {0} failed: {1}" -f $d.DeviceID, $_.Exception.Message) 'ERROR'
        }
        $seen[$key] = $true
    }

    # Forget volumes that have been pulled, so reinserting one re-imports it.
    foreach ($k in @($seen.Keys)) {
        if (-not $present.ContainsKey($k)) {
            $seen.Remove($k)
            Write-WatchLog "volume $k removed"
        }
    }
}

try {
    if ($Once) { Invoke-Scan; return }

    Unregister-Event -SourceIdentifier $SourceId -ErrorAction SilentlyContinue
    Register-CimIndicationEvent `
        -Query 'SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2 OR EventType = 3' `
        -SourceIdentifier $SourceId | Out-Null

    Write-WatchLog "started; Canon -> $CanonRoot ; GoPro -> $GoProRoot"
    Invoke-Scan   # catch anything already plugged in at logon

    while ($true) {
        # Returns as soon as a volume arrives or leaves; the timeout is a safety poll.
        $evt = Wait-Event -SourceIdentifier $SourceId -Timeout 15
        if ($evt) { Remove-Event -EventIdentifier $evt.EventIdentifier }
        try { Invoke-Scan }
        catch { Write-WatchLog ("scan error: {0}" -f $_.Exception.Message) 'ERROR' }
    }
}
finally {
    Unregister-Event -SourceIdentifier $SourceId -ErrorAction SilentlyContinue
    if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
    Write-WatchLog 'stopped'
}
