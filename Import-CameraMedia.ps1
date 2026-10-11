<#
.SYNOPSIS
    Moves camera media off removable drives into a dated library, per vendor.

.DESCRIPTION
    Canon  -> %USERPROFILE%\CameraImports\Canon\<yyyy>\<Mmm-dd>
    GoPro  -> %USERPROFILE%\CameraImports\GoPro\<yyyy>\<Mmm-dd>\DCIM\<card folders...>
              A 1:1 mirror of the card: same folders, same names, every file
              (including .LRV/.THM). The day is that of the card's earliest file.

    A card is first identified from files in its root (cheap, and for GoPro it
    names the exact model). That identity classifies files that carry no
    metadata of their own -- MP4s, proxies -- while per-file EXIF overrides it
    whenever present, because a card that has been through several cameras
    carries stale root markers.

    Every file is copied with an inline SHA-256 computed during the single read
    of the card; the copy is re-hashed on disk and the source is deleted only
    once the two agree. A failed verification leaves the card untouched.

    If a drive holds no media this script changes nothing at all: no folders are
    created, nothing is deleted, nothing is read twice. It does say so with a
    toast, so a card that looks ignored can be told apart from one that was
    never noticed.

.PARAMETER Drive
    Drive roots (e.g. 'D:'). Defaults to every removable drive.

.EXAMPLE
    .\Import-CameraMedia.ps1 -Drive D: -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]] $Drive,
    [string]   $CanonRoot = (Join-Path $env:USERPROFILE 'CameraImports\Canon'),
    [string]   $GoProRoot = (Join-Path $env:USERPROFILE 'CameraImports\GoPro'),
    [switch]   $KeepOriginals,
    [switch]   $Eject,
    [switch]   $Quiet,
    [string]   $LogPath = (Join-Path $env:LOCALAPPDATA 'CameraImport\import.log')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MediaLib.ps1')

# Progress toasts sit in front of the work, and Show-Toast blocks for its dwell,
# so keep them short. The completion toast at the end keeps the longer default.
$DetectDwellMs = 2500

#region profiles ------------------------------------------------------------

# StillExt  -- files we try to read EXIF from
# OtherExt  -- carried along, dated from sidecars or the file clock
# Mirror    -- the card's DCIM tree is reproduced as-is under one day folder:
#              every file is taken (whatever its extension or name), nothing is
#              regrouped, split by date, or discarded. Used when a card must
#              come across 1:1 (GoPro: time-lapses, chapters, .LRV/.THM).
$script:Profiles = @(
    [pscustomobject]@{
        Name        = 'Canon'
        Root        = $CanonRoot
        MakePattern = 'canon'
        NamePattern = '^(IMG|MVI|_MG|MDG|ST[A-E]|CRW|CSI)[_-]?\d+$'
        StillExt    = @('.jpg', '.jpeg', '.cr2', '.cr3', '.crw', '.heic', '.heif', '.tif', '.tiff')
        OtherExt    = @('.mp4', '.mov', '.avi', '.thm', '.wav')
        Mirror      = $false
    }
    [pscustomobject]@{
        Name        = 'GoPro'
        Root        = $GoProRoot
        MakePattern = 'gopro'
        NamePattern = '^(GOPR\d{4}|G[PXHSBL0]\d{6}|GS__\d{4})$'
        StillExt    = @('.jpg', '.jpeg', '.gpr', '.heic')
        OtherExt    = @('.mp4', '.mov', '.360', '.wav', '.lrv', '.thm')
        Mirror      = $true
    }
)

#endregion

#region logging -------------------------------------------------------------

function Write-Log {
    param([string] $Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string] $Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $written = Write-LogLine -Path $LogPath -Line $line
    if ($written -ne 'ok' -and -not $script:LogDivertWarned) {
        $script:LogDivertWarned = $true
        Write-Warning ("log '{0}' is locked by another process -- entries are going to '{0}.locked'" -f $LogPath)
    }
    if (-not $Quiet) {
        switch ($Level) {
            'WARN' { Write-Host $line -ForegroundColor Yellow }
            'ERROR' { Write-Host $line -ForegroundColor Red }
            default { Write-Host $line }
        }
    }
}

# Show-Toast now lives in MediaLib.ps1, so the watcher can raise toasts too.

#endregion

#region scan ----------------------------------------------------------------

function Get-CandidateFile {
    <#
        On a card whose root marks it as a mirrored vendor (GoPro) every file
        under DCIM is a candidate -- an unfamiliar extension must not leave a
        file behind on a card we are about to treat as fully imported. Other
        cards are filtered to the known media extensions.
    #>
    param([string] $Root, [string] $CardVendor)
    $dcim = Join-Path $Root 'DCIM'
    if (-not (Test-Path -LiteralPath $dcim)) { return @() }
    $mirrorCard = $false
    foreach ($p in $script:Profiles) { if ($p.Mirror -and $p.Name -eq $CardVendor) { $mirrorCard = $true } }
    $keep = @()
    foreach ($p in $script:Profiles) { $keep += $p.StillExt + $p.OtherExt }
    $keep = $keep | Sort-Object -Unique
    Get-ChildItem -LiteralPath $dcim -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object {
        ($mirrorCard -or $keep -contains $_.Extension.ToLowerInvariant()) -and
        -not $_.Name.StartsWith('._') -and              # macOS resource forks
        $_.Name -ne '.DS_Store'
    }
}

function Resolve-Profile {
    <# Decides which vendor owns a file. EXIF beats the card's root markers. #>
    param($File, $Meta, $CardVendor, [hashtable] $DirVendor)

    $ext = $File.Extension.ToLowerInvariant()
    $base = [IO.Path]::GetFileNameWithoutExtension($File.Name)

    # 1. EXIF Make is authoritative.
    if ($Meta -and $Meta.Make) {
        foreach ($p in $script:Profiles) {
            if ($Meta.Make -match $p.MakePattern) { return $p }
        }
        return $null            # a real camera, but not one we handle
    }

    # 2. A vendor string found inside the file (CR3 boxes, MP4 moov).
    if ($Meta -and $Meta.VendorHint) {
        foreach ($p in $script:Profiles) {
            if ($p.Name -eq $Meta.VendorHint) { return $p }
        }
    }

    # 3. Otherwise inherit from confirmed siblings, then from the card itself,
    #    but only when the filename matches that vendor's convention.
    $inherited = $null
    if ($DirVendor.ContainsKey($File.DirectoryName)) { $inherited = $DirVendor[$File.DirectoryName] }
    elseif ($CardVendor) { $inherited = $CardVendor }
    if ($inherited) {
        foreach ($p in $script:Profiles) {
            if ($p.Name -ne $inherited) { continue }
            # A mirrored card is taken whole, so a renamed file still belongs to it.
            if ($p.Mirror -or $base -match $p.NamePattern) { return $p }
        }
    }
    return $null
}

#endregion

#region import --------------------------------------------------------------

function Find-DuplicateInScope {
    <#
        Looks for a byte-identical copy already in the library, searching the day
        folder AND one level of set subfolders beneath it.

        Checking only the exact destination path is not enough: whether a file
        lands in a set subfolder depends on how many of its set-mates are present
        in that import, so the same photo can legitimately target
        'Sep-06\G001\X.JPG' on one run and 'Sep-06\X.JPG' on another. A path-scoped
        check misses that and silently writes a second copy.

        Length is compared first so only real candidates are hashed.
    #>
    param([string] $ScopeDir, [string] $Name, [long] $Length, [string] $Hash)

    if (-not (Test-Path -LiteralPath $ScopeDir)) { return $null }

    $candidates = @(Get-ChildItem -LiteralPath $ScopeDir -Filter $Name -File -Force -ErrorAction SilentlyContinue)
    foreach ($d in @(Get-ChildItem -LiteralPath $ScopeDir -Directory -Force -ErrorAction SilentlyContinue)) {
        $candidates += @(Get-ChildItem -LiteralPath $d.FullName -Filter $Name -File -Force -ErrorAction SilentlyContinue)
    }

    foreach ($c in $candidates) {
        if ($c.Length -ne $Length) { continue }
        if ((Get-FileHash -LiteralPath $c.FullName -Algorithm SHA256).Hash -eq $Hash) { return $c.FullName }
    }
    return $null
}

function Import-FromDrive {
    param([string] $Root, [string] $VolumeName)

    $Root = $Root.TrimEnd('\') + '\'
    $result = [pscustomobject]@{
        Drive = $Root; Camera = $null; Imported = 0; Duplicates = 0
        Skipped = 0; Errors = 0; Bytes = [long] 0
        Folders = @(); ByProfile = @{}
    }

    # Identity first: it decides whether the scan takes every file (mirrored
    # vendors) or only the known media extensions.
    $card = Get-CardIdentity -Root $Root -VolumeName $VolumeName

    $files = @(Get-CandidateFile -Root $Root -CardVendor $card.Vendor)
    if ($files.Count -eq 0) {
        # A DCIM folder but nothing in it we recognise -- still nothing to do.
        # The card and the library are both left untouched.
        Write-Log "$Root holds no camera media -- ignoring."
        Show-Toast -Title 'No camera media' -Text ("{0}`nnothing to import." -f $Root) `
            -DwellMs $DetectDwellMs -Quiet:$Quiet
        return $null
    }

    if ($card.Vendor) {
        $desc = $card.Vendor
        if ($card.Model) { $desc += " $($card.Model)" }
        if ($card.Firmware) { $desc += " (fw $($card.Firmware))" }
        $result.Camera = $desc
        Write-Log ("$Root identified as {0} via {1}" -f $desc, ($card.Evidence -join ', '))
    }
    else {
        Write-Log "$Root -- no vendor markers in root; relying on per-file metadata."
    }

    # Announce the import only now that the scan has proved there is one. The
    # vendor here is still the root-marker prior -- per-file EXIF may yet file
    # some of these elsewhere -- but the file count is real.
    $found = [math]::Round((($files | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
    Show-Toast -Title $(if ($card.Vendor) { "$($card.Vendor) card" } else { 'Camera card' }) `
        -Text ("{0}`nimporting {1} file(s), {2} MB..." -f $Root, $files.Count, $found) `
        -DwellMs $DetectDwellMs -Quiet:$Quiet

    # --- pass 1: read metadata, learn which folders belong to which vendor ---
    $meta = @{}
    $dirVendor = @{}
    foreach ($f in $files) {
        $ext = $f.Extension.ToLowerInvariant()
        $m = $null
        $isStill = $false
        foreach ($p in $script:Profiles) { if ($p.StillExt -contains $ext) { $isStill = $true } }
        if ($isStill) { $m = Get-PhotoMeta $f.FullName }
        elseif ($ext -eq '.mp4' -or $ext -eq '.mov' -or $ext -eq '.360') {
            $v = Get-Mp4Info $f.FullName
            $m = [pscustomobject]@{
                Make = $null; Model = $v.Model; DateTaken = $v.CreationTime; VendorHint = $v.Vendor
            }
        }
        $meta[$f.FullName] = $m
        if ($m -and $m.Make) {
            foreach ($p in $script:Profiles) {
                if ($m.Make -match $p.MakePattern) { $dirVendor[$f.DirectoryName] = $p.Name }
            }
        }
    }

    # --- pass 2: assign profile, resolve capture date, build the plan --------
    $plan = New-Object Collections.ArrayList
    $inv = [Globalization.CultureInfo]::InvariantCulture

    foreach ($f in $files) {
        $m = $meta[$f.FullName]
        $ext = $f.Extension.ToLowerInvariant()
        $prof = Resolve-Profile -File $f -Meta $m -CardVendor $card.Vendor -DirVendor $dirVendor

        if (-not $prof) {
            $result.Skipped++
            $who = 'unknown'
            if ($m -and $m.Make) { $who = $m.Make }
            Write-Log ("skip ({0}) {1}" -f $who, $f.FullName)
            continue
        }

        $taken = $null
        if ($m) { $taken = $m.DateTaken }
        if (-not $taken) {
            # A movie's .THM sidecar carries the EXIF the movie itself lacks.
            $thm = Join-Path $f.DirectoryName ([IO.Path]::GetFileNameWithoutExtension($f.Name) + '.THM')
            if (Test-Path -LiteralPath $thm) {
                $tm = Get-PhotoMeta $thm
                if ($tm.DateTaken) { $taken = $tm.DateTaken }
            }
        }
        if (-not $taken) { $taken = $f.LastWriteTime }

        $dir = Join-Path (Join-Path $prof.Root $taken.ToString('yyyy', $inv)) $taken.ToString('MMM-dd', $inv)
        # Mirrored files keep their place in the card's tree (DCIM\100GOPRO\...);
        # the day folder is fixed below, once the whole card has been seen.
        $rel = $null
        if ($prof.Mirror) { $rel = $f.DirectoryName.Substring($Root.TrimEnd('\').Length).TrimStart('\') }
        [void] $plan.Add([pscustomobject]@{
                File = $f; Profile = $prof; DestDir = $dir; ScopeDir = $dir; Rel = $rel; Taken = $taken
            })
    }

    if ($plan.Count -eq 0) {
        Write-Log "$Root -- no files from a supported camera; nothing done." 'WARN'
        return $result
    }

    # A mirrored card lands under ONE day folder -- the day of its earliest file
    # -- so a time-lapse that runs past midnight is not cut in two. The card's
    # own folder names and file names are reproduced untouched beneath it.
    foreach ($prof in @($plan | Where-Object { $_.Profile.Mirror } | ForEach-Object { $_.Profile } | Sort-Object Name -Unique)) {
        $mine = @($plan | Where-Object { $_.Profile.Name -eq $prof.Name })
        $first = ($mine | ForEach-Object { $_.Taken } | Sort-Object | Select-Object -First 1)
        $day = Join-Path (Join-Path $prof.Root $first.ToString('yyyy', $inv)) $first.ToString('MMM-dd', $inv)
        foreach ($i in $mine) {
            $i.DestDir = if ($i.Rel) { Join-Path $day $i.Rel } else { $day }
            $i.ScopeDir = $i.DestDir      # same card path => same place; no day-wide search needed
        }
    }

    $mb = [math]::Round((($plan | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum) / 1MB, 1)
    $dirs = @($plan | ForEach-Object { $_.DestDir } | Sort-Object -Unique).Count
    Write-Log ("{0} -- {1} file(s), {2} MB, into {3} folder(s)." -f $Root, $plan.Count, $mb, $dirs)

    # --- pass 3: copy, verify, then delete the source -----------------------
    foreach ($item in $plan) {
        $f = $item.File
        $destDir = $item.DestDir
        $action = 'Move'
        if ($KeepOriginals) { $action = 'Copy' }
        if (-not $PSCmdlet.ShouldProcess((Join-Path $destDir $f.Name), $action)) { continue }

        try {
            if (-not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                Write-Log "created $destDir"
            }
            if ($result.Folders -notcontains $destDir) { $result.Folders += $destDir }

            $tmp = Join-Path $destDir ('.{0}.cimport' -f [guid]::NewGuid().ToString('N'))
            $srcHash = Copy-WithHash $f.FullName $tmp
            $tmpHash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash

            if ($tmpHash -ne $srcHash) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                $result.Errors++
                Write-Log ("VERIFY FAILED, card left untouched: {0}" -f $f.FullName) 'ERROR'
                continue
            }

            $existing = Find-DuplicateInScope -ScopeDir $item.ScopeDir -Name $f.Name `
                -Length $f.Length -Hash $tmpHash
            if ($existing) {
                Remove-Item -LiteralPath $tmp -Force
                if (-not $KeepOriginals) { Remove-SourceFile $f.FullName }
                $result.Duplicates++
                Write-Log ("duplicate of {0}" -f $existing)
                continue
            }

            $target = Join-Path $destDir $f.Name
            if (Test-Path -LiteralPath $target) {
                # Same name, different bytes -- keep both.
                $target = Get-FreeName $destDir $f.Name
                Write-Log ("name clash, saving as {0}" -f (Split-Path -Leaf $target)) 'WARN'
            }

            Move-Item -LiteralPath $tmp -Destination $target -Force
            $o = New-Object IO.FileInfo $target
            $o.CreationTime = $f.CreationTime
            $o.LastWriteTime = $f.LastWriteTime

            if (-not $KeepOriginals) { Remove-SourceFile $f.FullName }

            $result.Imported++
            $result.Bytes += $f.Length
            $n = $item.Profile.Name
            if ($result.ByProfile.ContainsKey($n)) { $result.ByProfile[$n]++ } else { $result.ByProfile[$n] = 1 }
        }
        catch {
            $result.Errors++
            Write-Log ("{0}: {1}" -f $f.FullName, $_.Exception.Message) 'ERROR'
        }
    }

    return $result
}

function Invoke-Eject {
    param([string] $Root)
    try {
        $letter = $Root.Substring(0, 2)
        $shell = New-Object -ComObject Shell.Application
        $item = $shell.Namespace(17).ParseName($letter)
        if ($item) { $item.InvokeVerb('Eject'); Write-Log "ejected $letter" }
    }
    catch { Write-Log ("eject failed: {0}" -f $_.Exception.Message) 'WARN' }
}

#endregion

#region main ----------------------------------------------------------------

$targets = @()
if ($Drive -and $Drive.Count -gt 0) {
    foreach ($d in $Drive) { $targets += [pscustomobject]@{ Root = $d; VolumeName = '' } }
}
else {
    foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 2' -ErrorAction SilentlyContinue)) {
        $targets += [pscustomobject]@{ Root = $d.DeviceID; VolumeName = $d.VolumeName }
    }
}
if ($targets.Count -eq 0) {
    Write-Log 'No removable drives present.' 'WARN'
    return
}

$summaries = @()
foreach ($t in $targets) {
    $root = $t.Root
    if ($root -notmatch '\\$') { $root += '\' }
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Log "$root is not accessible." 'WARN'
        continue
    }
    $r = Import-FromDrive -Root $root -VolumeName $t.VolumeName
    if ($r) {
        $summaries += $r
        if ($Eject -and $r.Errors -eq 0 -and $r.Imported -gt 0) { Invoke-Eject $root }
    }
}

foreach ($s in $summaries) {
    $mb = [math]::Round($s.Bytes / 1MB, 1)
    $by = ($s.ByProfile.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', '
    if (-not $by) { $by = 'none' }
    Write-Log ("{0} done: {1} imported ({2}), {3} duplicate, {4} skipped, {5} error(s) -- {6} MB" -f `
            $s.Drive, $s.Imported, $by, $s.Duplicates, $s.Skipped, $s.Errors, $mb)

    if ($s.Imported -gt 0 -or $s.Errors -gt 0) {
        $title = 'Camera import'
        if ($s.Camera) { $title = $s.Camera }
        $where = ($s.Folders | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object -Unique) -join ', '
        Show-Toast -Title $title -Text ("{0} file(s), {1} MB`n{2}" -f $s.Imported, $mb, $where) -Quiet:$Quiet
    }
}

$summaries

#endregion
