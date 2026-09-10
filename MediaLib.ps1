<#
    MediaLib.ps1 -- metadata readers and verified-copy helpers shared by the
    camera import tools. Dot-source it; it defines functions and nothing else.

    Why hand-rolled parsers: System.Drawing cannot open CR2/CR3, the Windows
    property system needs a per-model raw codec installed, and neither can tell
    you the vendor of an MP4. Everything here is bounds-checked and returns
    $null rather than throwing on malformed input.
#>

#region byte helpers --------------------------------------------------------

function Get-U16 {
    param([byte[]] $B, [int] $O, [bool] $LE)
    if ($O -lt 0 -or ($O + 2) -gt $B.Length) { return $null }
    if ($LE) { return [BitConverter]::ToUInt16($B, $O) }
    return [uint16](([int] $B[$O] -shl 8) -bor [int] $B[$O + 1])
}

function Get-U32 {
    param([byte[]] $B, [int] $O, [bool] $LE)
    if ($O -lt 0 -or ($O + 4) -gt $B.Length) { return $null }
    if ($LE) { return [BitConverter]::ToUInt32($B, $O) }
    return [uint32](([uint32] $B[$O] -shl 24) -bor ([uint32] $B[$O + 1] -shl 16) -bor
        ([uint32] $B[$O + 2] -shl 8) -bor [uint32] $B[$O + 3])
}

function Get-BE64 {
    param([byte[]] $B, [int] $O)
    if ($O -lt 0 -or ($O + 8) -gt $B.Length) { return $null }
    $v = [uint64] 0
    for ($i = 0; $i -lt 8; $i++) { $v = ($v -shl 8) -bor [uint64] $B[$O + $i] }
    return $v
}

function Find-Ascii {
    param([byte[]] $B, [string] $S, [int] $Limit = 65536)
    $n = [Math]::Min($B.Length, $Limit)
    if ($n -le 0) { return -1 }
    # Latin-1 maps bytes 1:1 to chars, so IndexOf is an exact byte search.
    return [Text.Encoding]::GetEncoding(28591).GetString($B, 0, $n).IndexOf($S, [StringComparison]::Ordinal)
}

function Read-Exact {
    param([IO.Stream] $Stream, [byte[]] $Buffer, [int] $Count)
    $got = 0
    while ($got -lt $Count) {
        $r = $Stream.Read($Buffer, $got, $Count - $got)
        if ($r -le 0) { break }
        $got += $r
    }
    return $got
}

#endregion

#region EXIF ----------------------------------------------------------------

function Read-Ifd {
    param([byte[]] $B, [int] $TiffStart, [int] $IfdOff, [bool] $LE)
    $entries = @{}
    $count = Get-U16 $B $IfdOff $LE
    if ($null -eq $count -or $count -eq 0 -or $count -gt 512) { return $entries }
    $sizes = @(0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8)   # indexed by TIFF type 1..12
    for ($i = 0; $i -lt $count; $i++) {
        $e = $IfdOff + 2 + ($i * 12)
        if (($e + 12) -gt $B.Length) { break }
        $tag = Get-U16 $B $e $LE
        $type = Get-U16 $B ($e + 2) $LE
        $cnt = Get-U32 $B ($e + 4) $LE
        if ($null -eq $tag -or $null -eq $type -or $null -eq $cnt) { continue }
        if ($type -lt 1 -or $type -gt 12) { continue }
        $total = [long] $sizes[$type] * [long] $cnt
        if ($total -le 0 -or $total -gt 65536) { continue }
        if ($total -gt 4) {
            $ptr = Get-U32 $B ($e + 8) $LE
            if ($null -eq $ptr) { continue }
            $dataOff = $TiffStart + [int] $ptr
        }
        else { $dataOff = $e + 8 }
        if ($dataOff -lt 0 -or ($dataOff + $total) -gt $B.Length) { continue }
        $entries[[int] $tag] = @{ Type = [int] $type; Count = [int] $cnt; Offset = [int] $dataOff }
    }
    return $entries
}

function Get-IfdAscii {
    param([byte[]] $B, $Entry)
    if ($null -eq $Entry) { return $null }
    $s = [Text.Encoding]::ASCII.GetString($B, $Entry.Offset, $Entry.Count).Trim([char] 0).Trim()
    if ($s.Length -eq 0) { return $null }
    return $s
}

function ConvertFrom-ExifDate {
    param([string] $S)
    if ([string]::IsNullOrWhiteSpace($S)) { return $null }
    $S = $S.Trim()
    if ($S -like '0000*') { return $null }
    $d = [datetime]::MinValue
    foreach ($f in @('yyyy:MM:dd HH:mm:ss', 'yyyy-MM-dd HH:mm:ss', 'yyyy:MM:dd')) {
        if ([datetime]::TryParseExact($S, $f, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref] $d)) {
            return $d
        }
    }
    return $null
}

function Read-ExifAt {
    param([byte[]] $B, [int] $TiffStart)
    $out = @{ Make = $null; Model = $null; DateTaken = $null }
    if ($TiffStart -lt 0 -or ($TiffStart + 8) -gt $B.Length) { return $out }

    $bo = [Text.Encoding]::ASCII.GetString($B, $TiffStart, 2)
    if ($bo -eq 'II') { $LE = $true } elseif ($bo -eq 'MM') { $LE = $false } else { return $out }
    if ((Get-U16 $B ($TiffStart + 2) $LE) -ne 42) { return $out }

    $ifd0Ptr = Get-U32 $B ($TiffStart + 4) $LE
    if ($null -eq $ifd0Ptr) { return $out }
    $ifd0 = Read-Ifd $B $TiffStart ($TiffStart + [int] $ifd0Ptr) $LE

    $out.Make = Get-IfdAscii $B $ifd0[0x010F]
    $out.Model = Get-IfdAscii $B $ifd0[0x0110]
    $dateStr = Get-IfdAscii $B $ifd0[0x0132]          # ModifyDate -- weakest source

    if ($ifd0.ContainsKey(0x8769)) {
        $exifPtr = Get-U32 $B $ifd0[0x8769].Offset $LE
        if ($null -ne $exifPtr) {
            $exif = Read-Ifd $B $TiffStart ($TiffStart + [int] $exifPtr) $LE
            foreach ($tag in @(0x9003, 0x9004)) {      # DateTimeOriginal, then CreateDate
                $v = Get-IfdAscii $B $exif[$tag]
                if ($v) { $dateStr = $v; break }
            }
        }
    }

    $out.DateTaken = ConvertFrom-ExifDate $dateStr
    return $out
}

function Get-PhotoMeta {
    <# Make / Model / DateTaken for a still. Handles JPEG, TIFF/CR2, CR3/HEIF. #>
    param([string] $Path, [int] $HeaderBytes = 262144)

    $meta = [pscustomobject]@{ Make = $null; Model = $null; DateTaken = $null; VendorHint = $null }
    try {
        $fi = New-Object IO.FileInfo $Path
        $len = [int][Math]::Min([long] $HeaderBytes, $fi.Length)
        if ($len -lt 16) { return $meta }

        $B = New-Object byte[] $len
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { [void](Read-Exact $fs $B $len) } finally { $fs.Dispose() }

        $tiff = -1
        if ($B[0] -eq 0xFF -and $B[1] -eq 0xD8) {
            # JPEG: walk marker segments looking for APP1/Exif.
            $p = 2
            while (($p + 4) -lt $B.Length) {
                if ($B[$p] -ne 0xFF) { break }
                $m = $B[$p + 1]
                if ($m -eq 0xD8 -or $m -eq 0x01 -or ($m -ge 0xD0 -and $m -le 0xD7)) { $p += 2; continue }
                if ($m -eq 0xDA -or $m -eq 0xD9) { break }        # start of scan / end of image
                $segLen = Get-U16 $B ($p + 2) $false               # segment lengths are big-endian
                if ($null -eq $segLen -or $segLen -lt 2) { break }
                if ($m -eq 0xE1 -and ($p + 10) -lt $B.Length -and
                    [Text.Encoding]::ASCII.GetString($B, $p + 4, 4) -eq 'Exif') {
                    $tiff = $p + 10
                    break
                }
                $p += 2 + [int] $segLen
            }
        }
        elseif (($B[0] -eq 0x49 -and $B[1] -eq 0x49) -or ($B[0] -eq 0x4D -and $B[1] -eq 0x4D)) {
            $tiff = 0                                              # TIFF / CR2 / GPR(DNG)
        }
        else {
            $idx = Find-Ascii $B 'CMT1' 262144                     # CR3 / HEIF keep EXIF in a CMT1 box
            if ($idx -ge 0) { $tiff = $idx + 4 }
        }

        if ($tiff -ge 0) {
            $e = Read-ExifAt $B $tiff
            $meta.Make = $e.Make
            $meta.Model = $e.Model
            $meta.DateTaken = $e.DateTaken
        }
        if (-not $meta.Make) {
            foreach ($v in @('GoPro', 'Canon')) {
                if ((Find-Ascii $B $v) -ge 0) { $meta.VendorHint = $v; break }
            }
        }
    }
    catch { Write-Verbose ("still metadata failed for {0}: {1}" -f $Path, $_.Exception.Message) }
    return $meta
}

#endregion

#region MP4 / ISO-BMFF ------------------------------------------------------

function Get-Mp4Info {
    <#
        Walks the top-level box list to find 'moov', then reads 'mvhd' for the
        creation time and scans the moov payload for a vendor string.

        Box headers are only 8 bytes, so this seeks rather than reads: it works
        whether the camera puts moov at the front or (as GoPro does) at the very
        end of a multi-gigabyte file.
    #>
    param([string] $Path, [int] $MaxMoov = 4194304)

    $out = [pscustomobject]@{ Brand = $null; CreationTime = $null; Vendor = $null; Model = $null }
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            $hdr = New-Object byte[] 16
            $pos = [long] 0
            $moovOff = [long] -1
            $moovSize = [long] 0

            while ($pos -lt $len) {
                $fs.Position = $pos
                if ((Read-Exact $fs $hdr 8) -lt 8) { break }
                $size = [long](Get-U32 $hdr 0 $false)
                $type = [Text.Encoding]::ASCII.GetString($hdr, 4, 4)
                $hdrSize = 8
                if ($size -eq 1) {
                    if ((Read-Exact $fs $hdr 8) -lt 8) { break }   # 64-bit largesize follows
                    $big = Get-BE64 $hdr 0
                    if ($null -eq $big) { break }
                    $size = [long] $big
                    $hdrSize = 16
                }
                elseif ($size -eq 0) { $size = $len - $pos }        # box runs to end of file
                if ($size -lt $hdrSize) { break }

                if ($type -eq 'ftyp') {
                    $b = New-Object byte[] 4
                    $fs.Position = $pos + $hdrSize
                    if ((Read-Exact $fs $b 4) -eq 4) {
                        $out.Brand = [Text.Encoding]::ASCII.GetString($b, 0, 4).Trim()
                    }
                }
                elseif ($type -eq 'moov') {
                    $moovOff = $pos + $hdrSize
                    $moovSize = $size - $hdrSize
                    break
                }
                $pos += $size
            }

            if ($moovOff -ge 0 -and $moovSize -gt 0) {
                $read = [int][Math]::Min([long] $MaxMoov, $moovSize)
                $moov = New-Object byte[] $read
                $fs.Position = $moovOff
                [void](Read-Exact $fs $moov $read)

                # mvhd is a direct child of moov.
                $o = 0
                while (($o + 8) -le $moov.Length) {
                    $sz = [long](Get-U32 $moov $o $false)
                    $ty = [Text.Encoding]::ASCII.GetString($moov, $o + 4, 4)
                    if ($sz -lt 8) { break }
                    if ($ty -eq 'mvhd') {
                        $p = $o + 8
                        if ($p -lt $moov.Length) {
                            $ver = $moov[$p]
                            $secs = $null
                            if ($ver -eq 0) { $secs = Get-U32 $moov ($p + 4) $false }
                            elseif ($ver -eq 1) { $secs = Get-BE64 $moov ($p + 4) }
                            if ($null -ne $secs -and $secs -gt 0) {
                                # QuickTime epoch is 1904-01-01.
                                $epoch = New-Object datetime 1904, 1, 1, 0, 0, 0
                                $out.CreationTime = $epoch.AddSeconds([double] $secs)
                            }
                        }
                        break
                    }
                    $o += [int] $sz
                }

                foreach ($v in @('GoPro', 'Canon')) {
                    if ((Find-Ascii $moov $v $moov.Length) -ge 0) { $out.Vendor = $v; break }
                }
                if ($moov -and (Find-Ascii $moov 'HERO' $moov.Length) -ge 0) {
                    $s = [Text.Encoding]::GetEncoding(28591).GetString($moov)
                    if ($s -match '(HERO\d*\s*\w*)') { $out.Model = $Matches[1].Trim() }
                }
            }
        }
        finally { $fs.Dispose() }
    }
    catch { Write-Verbose ("mp4 parse failed for {0}: {1}" -f $Path, $_.Exception.Message) }
    return $out
}

#endregion

#region card identity -------------------------------------------------------

function Get-CardIdentity {
    <#
        Identifies the camera from files in the card root -- far cheaper than
        reading every file, and for GoPro it names the exact model.

        This is a prior, not a verdict: a card that has been through several
        cameras carries stale markers (the EOS card here still had Sony's
        MP_ROOT and AVF_INFO). Per-file EXIF always wins over this.
    #>
    param([string] $Root, [string] $VolumeName)

    $id = [pscustomobject]@{ Vendor = $null; Model = $null; Firmware = $null; Evidence = @() }

    # --- GoPro ---------------------------------------------------------
    $ev = @()
    if (Test-Path -LiteralPath (Join-Path $Root 'Get_started_with_GoPro.url')) {
        $ev += 'Get_started_with_GoPro.url'
    }
    $verFile = Join-Path $Root 'MISC\version.txt'
    if (Test-Path -LiteralPath $verFile) {
        try {
            # GoPro writes a trailing comma before the closing brace, so this is
            # not valid JSON and ConvertFrom-Json throws. Pull fields by regex.
            $raw = Get-Content -LiteralPath $verFile -Raw -ErrorAction Stop
            if ($raw -match '"camera type"\s*:\s*"([^"]+)"') {
                $id.Model = $Matches[1]
                $ev += 'MISC\version.txt'
            }
            if ($raw -match '"firmware version"\s*:\s*"([^"]+)"') { $id.Firmware = $Matches[1] }
        }
        catch { }
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'DCIM')) {
        $g = @(Get-ChildItem -LiteralPath (Join-Path $Root 'DCIM') -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'GOPRO$' })
        if ($g.Count -gt 0) { $ev += "DCIM\$($g[0].Name)" }
    }
    if ($ev.Count -gt 0) {
        $id.Vendor = 'GoPro'
        $id.Evidence = $ev
        return $id
    }

    # --- Canon ---------------------------------------------------------
    $ev = @()
    if ($VolumeName -and $VolumeName -match '^(EOS_DIGITAL|CANON)') { $ev += "label:$VolumeName" }
    if (Test-Path -LiteralPath (Join-Path $Root 'DCIM')) {
        $c = @(Get-ChildItem -LiteralPath (Join-Path $Root 'DCIM') -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(CANON|EOSMISC)' })
        if ($c.Count -gt 0) { $ev += ($c | Select-Object -First 2 | ForEach-Object { "DCIM\$($_.Name)" }) }
    }
    if ($ev.Count -gt 0) {
        $id.Vendor = 'Canon'
        $id.Evidence = $ev
        return $id
    }

    return $id
}

#endregion

#region verified copy -------------------------------------------------------

function Copy-WithHash {
    <# Copies Source to Dest, hashing the bytes as they stream past: one read of the card. #>
    param([string] $Source, [string] $Dest)
    $sha = [Security.Cryptography.SHA256]::Create()
    $in = $null
    $out = $null
    try {
        $in = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $out = [IO.File]::Open($Dest, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buf = New-Object byte[] 1048576
        while ($true) {
            $n = $in.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            [void] $sha.TransformBlock($buf, 0, $n, $null, 0)
            $out.Write($buf, 0, $n)
        }
        [void] $sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $out.Flush($true)
    }
    finally {
        if ($out) { $out.Dispose() }
        if ($in) { $in.Dispose() }
    }
    $hex = -join ($sha.Hash | ForEach-Object { $_.ToString('x2') })
    $sha.Dispose()
    return $hex.ToUpperInvariant()
}

function Get-FreeName {
    param([string] $Dir, [string] $Name)
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $ext = [IO.Path]::GetExtension($Name)
    for ($i = 1; $i -lt 10000; $i++) {
        $cand = Join-Path $Dir ('{0}_{1}{2}' -f $base, $i, $ext)
        if (-not (Test-Path -LiteralPath $cand)) { return $cand }
    }
    throw "No free filename for $Name in $Dir"
}

function Remove-SourceFile {
    param([string] $Path)
    $f = New-Object IO.FileInfo $Path
    if ($f.IsReadOnly) { $f.IsReadOnly = $false }
    Remove-Item -LiteralPath $Path -Force
}

#endregion
