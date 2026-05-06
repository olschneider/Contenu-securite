<#
.SYNOPSIS
    PDF Forensic Analyzer - Extrait actions de demarrage, JavaScript,
    fichiers incorpores et metadonnees. Compatible PDF 1.4 a 2.0.

.PARAMETER Path
    Chemin vers le fichier PDF a analyser.

.PARAMETER ExportJS
    Si specifie, exporte les scripts JavaScript trouves dans un dossier.

.PARAMETER ExportFiles
    Si specifie, extrait les fichiers incorpores dans un dossier.

.PARAMETER OutputDir
    Dossier de sortie pour les exports (defaut : repertoire du PDF).

.EXAMPLE
    .\Analyze-PDF.ps1 -Path "document.pdf"
    .\Analyze-PDF.ps1 -Path "suspect.pdf" -ExportJS -ExportFiles -OutputDir "C:\Analyse"
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,
    [switch]$ExportJS,
    [switch]$ExportFiles,
    [string]$OutputDir = ''
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# --------------------------- Globals ------------------------------------------
$script:Bytes       = $null       # [byte[]] contenu brut du fichier
$script:XrefMap     = @{}         # objNum -> @{Offset;Gen;InObjStm;ObjStmNum;Index}
$script:ObjCache    = @{}         # objNum -> objet parse
$script:TrailerDict = $null       # dictionnaire trailer
$script:PdfVersion  = ''
$script:JSSnippets  = [System.Collections.Generic.List[hashtable]]::new()

# ----------------------- Helpers bas niveau -----------------------------------

function script:GetASCII([int]$start, [int]$len) {
    $len = [Math]::Min($len, $script:Bytes.Length - $start)
    if ($len -le 0) { return '' }
    [System.Text.Encoding]::ASCII.GetString($script:Bytes, $start, $len)
}

function script:IsWS([byte]$b) {
    $b -in 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20
}

function script:IsDelim([byte]$b) {
    # ( ) < > [ ] { } / %
    $b -in 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25
}

function script:SkipWS([ref]$p) {
    while ($p.Value -lt $script:Bytes.Length) {
        $b = $script:Bytes[$p.Value]
        if ($b -eq 0x25) {          # commentaire %
            while ($p.Value -lt $script:Bytes.Length -and
                   $script:Bytes[$p.Value] -notin 0x0A, 0x0D) { $p.Value++ }
        } elseif (script:IsWS $b) { $p.Value++ }
        else { break }
    }
}

function script:ReadInt([byte[]]$buf, [int]$off, [int]$w) {
    $v = 0
    for ($k = 0; $k -lt $w; $k++) { $v = ($v -shl 8) -bor $buf[$off + $k] }
    $v
}

# ----------------------- Decompression ----------------------------------------

function script:FlateDecode([byte[]]$data) {
    if ($null -eq $data -or $data.Length -eq 0) { return $null }
    try {
        # Detection en-tete zlib (CMF/FLG)
        $skip = 0
        if ($data.Length -ge 2 -and ($data[0] -band 0x0F) -eq 8) { $skip = 2 }
        $ms = [System.IO.MemoryStream]::new($data, $skip, $data.Length - $skip)
        $ds = [System.IO.Compression.DeflateStream]::new(
                $ms, [System.IO.Compression.CompressionMode]::Decompress)
        $out = [System.IO.MemoryStream]::new()
        $ds.CopyTo($out)
        $ds.Dispose(); $ms.Dispose()
        $out.ToArray()
    } catch { $null }
}

function script:DecodeStream([byte[]]$raw, $filterTok, $decodeParmsTok) {
    if ($null -eq $filterTok -or $null -eq $raw) { return $raw }
    $filters = @()
    if ($filterTok.Type -eq 'Name') { $filters = @($filterTok.Value) }
    elseif ($filterTok.Type -eq 'Array') {
        $filterTok.Value | ForEach-Object { if ($_.Type -eq 'Name') { $filters += $_.Value } }
    }
    $data = $raw
    foreach ($f in $filters) {
        $data = switch ($f) {
            { $_ -in 'FlateDecode','Fl' } { script:FlateDecode $data }
            'ASCIIHexDecode' {
                $hex = ([System.Text.Encoding]::ASCII.GetString($data)) `
                        -replace '\s','' -replace '>',''
                if ($hex.Length % 2) { $hex += '0' }
                $out = [byte[]]::new($hex.Length / 2)
                for ($i = 0; $i -lt $hex.Length; $i += 2) {
                    $out[$i/2] = [Convert]::ToByte($hex.Substring($i,2),16)
                }
                $out
            }
            'ASCII85Decode' {
                # Decodage ASCII85 / Base85
                $s = ([System.Text.Encoding]::ASCII.GetString($data)) -replace '\s',''
                $s = $s -replace '~>$',''
                $out = [System.Collections.Generic.List[byte]]::new()
                $i = 0
                while ($i -lt $s.Length) {
                    if ($s[$i] -eq 'z') { $out.AddRange([byte[]](0,0,0,0)); $i++; continue }
                    $chunk = $s.Substring($i, [Math]::Min(5, $s.Length - $i))
                    while ($chunk.Length -lt 5) { $chunk += 'u' }
                    $v = 0L
                    for ($k = 0; $k -lt 5; $k++) { $v = $v * 85 + ([byte][char]$chunk[$k] - 33) }
                    $bytes = 4 - (5 - [Math]::Min(5, $s.Length - $i + ([Math]::Min(5,$s.Length-$i)-$chunk.TrimEnd('u').Length)))
                    for ($k = 3; $k -ge 0; $k--) {
                        if (($k -lt [Math]::Min(5,$s.Length-$i)-1) -or ($chunk.Length -eq 5)) {
                            $out.Add([byte](($v -shr ($k*8)) -band 0xFF))
                        }
                    }
                    $i += [Math]::Min(5, $s.Length - $i)
                }
                $out.ToArray()
            }
            default { $data }  # filtre non supporte - donnees brutes
        }
        if ($null -eq $data) { return $null }
    }
    $data
}

# ----------------------- Tokenizer PDF ----------------------------------------

function script:ReadToken([ref]$p) {
    script:SkipWS $p
    if ($p.Value -ge $script:Bytes.Length) { return $null }
    $b = $script:Bytes[$p.Value]

    # -- Nom /Name --------------------------------------------------------------
    if ($b -eq 0x2F) {
        $p.Value++
        $nb = [System.Collections.Generic.List[byte]]::new()
        while ($p.Value -lt $script:Bytes.Length) {
            $c = $script:Bytes[$p.Value]
            if ((script:IsWS $c) -or (script:IsDelim $c)) { break }
            if ($c -eq 0x23 -and $p.Value + 2 -lt $script:Bytes.Length) {
                $h = script:GetASCII ($p.Value+1) 2
                $nb.Add([Convert]::ToByte($h,16)); $p.Value += 3
            } else { $nb.Add($c); $p.Value++ }
        }
        return @{ Type='Name'; Value=[System.Text.Encoding]::Latin1.GetString($nb.ToArray()) }
    }

    # -- Dictionnaire << --------------------------------------------------------
    if ($b -eq 0x3C -and ($p.Value+1) -lt $script:Bytes.Length -and $script:Bytes[$p.Value+1] -eq 0x3C) {
        $p.Value += 2
        $dict = @{}
        while ($true) {
            script:SkipWS $p
            if ($p.Value -ge $script:Bytes.Length) { break }
            if ($script:Bytes[$p.Value] -eq 0x3E -and ($p.Value+1) -lt $script:Bytes.Length -and $script:Bytes[$p.Value+1] -eq 0x3E) {
                $p.Value += 2; break
            }
            $k = script:ReadToken $p
            if ($null -eq $k -or $k.Type -ne 'Name') { break }
            $v = script:ReadObject $p
            if ($null -ne $v) { $dict[$k.Value] = $v }
        }
        return @{ Type='Dict'; Value=$dict }
    }

    # -- Chaine hex <...> -------------------------------------------------------
    if ($b -eq 0x3C) {
        $p.Value++
        $sb = [System.Text.StringBuilder]::new()
        while ($p.Value -lt $script:Bytes.Length -and $script:Bytes[$p.Value] -ne 0x3E) {
            $c = $script:Bytes[$p.Value]
            if (-not (script:IsWS $c)) { [void]$sb.Append([char]$c) }
            $p.Value++
        }
        $p.Value++
        $hex = $sb.ToString(); if ($hex.Length % 2) { $hex += '0' }
        $hb  = [byte[]]::new($hex.Length/2)
        for ($i=0; $i -lt $hex.Length; $i+=2) { $hb[$i/2]=[Convert]::ToByte($hex.Substring($i,2),16) }
        return @{ Type='HexString'; Value=$hb
                  StringValue = $(
                    if ($hb.Length -ge 2 -and $hb[0] -eq 0xFE -and $hb[1] -eq 0xFF) {
                        [System.Text.Encoding]::BigEndianUnicode.GetString($hb,2,$hb.Length-2)
                    } elseif ($hb.Length -ge 2 -and $hb[0] -eq 0xFF -and $hb[1] -eq 0xFE) {
                        [System.Text.Encoding]::Unicode.GetString($hb,2,$hb.Length-2)
                    } else { [System.Text.Encoding]::Latin1.GetString($hb) }
                  ) }
    }

    # -- Tableau [...] ----------------------------------------------------------
    if ($b -eq 0x5B) {
        $p.Value++
        $arr = [System.Collections.Generic.List[object]]::new()
        while ($true) {
            script:SkipWS $p
            if ($p.Value -ge $script:Bytes.Length) { break }
            if ($script:Bytes[$p.Value] -eq 0x5D) { $p.Value++; break }
            $item = script:ReadObject $p
            if ($null -ne $item) { $arr.Add($item) }
        }
        return @{ Type='Array'; Value=$arr }
    }

    # -- Chaine litterale (...) -------------------------------------------------
    if ($b -eq 0x28) {
        $p.Value++
        $sb  = [System.Collections.Generic.List[byte]]::new()
        $dep = 1
        while ($p.Value -lt $script:Bytes.Length -and $dep -gt 0) {
            $c = $script:Bytes[$p.Value]
            if ($c -eq 0x5C) {
                $p.Value++
                if ($p.Value -ge $script:Bytes.Length) { break }
                $e = $script:Bytes[$p.Value]
                switch ($e) {
                    0x6E { $sb.Add(0x0A) }
                    0x72 { $sb.Add(0x0D) }
                    0x74 { $sb.Add(0x09) }
                    0x62 { $sb.Add(0x08) }
                    0x66 { $sb.Add(0x0C) }
                    0x28 { $sb.Add(0x28) }
                    0x29 { $sb.Add(0x29) }
                    0x5C { $sb.Add(0x5C) }
                    0x0D { if (($p.Value+1) -lt $script:Bytes.Length -and $script:Bytes[$p.Value+1] -eq 0x0A) { $p.Value++ } }
                    0x0A { }
                    default {
                        if ($e -ge 0x30 -and $e -le 0x37) {
                            $oct = [int][char]$e - 48
                            for ($oi=0; $oi -lt 2; $oi++) {
                                if (($p.Value+1) -lt $script:Bytes.Length) {
                                    $nx=$script:Bytes[$p.Value+1]
                                    if ($nx -ge 0x30 -and $nx -le 0x37) { $oct=$oct*8+([int][char]$nx-48); $p.Value++ }
                                    else { break }
                                }
                            }
                            $sb.Add([byte]($oct -band 0xFF))
                        } else { $sb.Add($e) }
                    }
                }
            } elseif ($c -eq 0x28) { $dep++; $sb.Add($c) }
            elseif ($c -eq 0x29) { $dep--; if ($dep -gt 0) { $sb.Add($c) } }
            else { $sb.Add($c) }
            $p.Value++
        }
        $rb = $sb.ToArray()
        $sv = if ($rb.Length -ge 2 -and $rb[0] -eq 0xFE -and $rb[1] -eq 0xFF) {
                [System.Text.Encoding]::BigEndianUnicode.GetString($rb,2,$rb.Length-2)
              } elseif ($rb.Length -ge 2 -and $rb[0] -eq 0xFF -and $rb[1] -eq 0xFE) {
                [System.Text.Encoding]::Unicode.GetString($rb,2,$rb.Length-2)
              } else { [System.Text.Encoding]::Latin1.GetString($rb) }
        return @{ Type='String'; Value=$sv; RawBytes=$rb }
    }

    # -- Mots-cles et booleens -------------------------------------------------
    $kws = 'startxref','endstream','endobj','trailer','stream','false','null','true','xref','obj','R','f','n'
    foreach ($kw in $kws) {
        $kl = $kw.Length
        if ($p.Value + $kl -gt $script:Bytes.Length) { continue }
        $match = $true
        $kb = [System.Text.Encoding]::ASCII.GetBytes($kw)
        for ($ki=0; $ki -lt $kl; $ki++) {
            if ($script:Bytes[$p.Value+$ki] -ne $kb[$ki]) { $match=$false; break }
        }
        if ($match) {
            $after = $p.Value + $kl
            if ($after -ge $script:Bytes.Length -or (script:IsWS $script:Bytes[$after]) -or (script:IsDelim $script:Bytes[$after])) {
                $p.Value += $kl
                return @{ Type='Keyword'; Value=$kw }
            }
        }
    }

    # -- Nombre ----------------------------------------------------------------
    if (($b -ge 0x30 -and $b -le 0x39) -or $b -in 0x2B,0x2D,0x2E) {
        $sb = [System.Text.StringBuilder]::new()
        $isR = $false
        if ($b -in 0x2B,0x2D) { [void]$sb.Append([char]$b); $p.Value++ }
        while ($p.Value -lt $script:Bytes.Length) {
            $c = $script:Bytes[$p.Value]
            if ($c -ge 0x30 -and $c -le 0x39) { [void]$sb.Append([char]$c); $p.Value++ }
            elseif ($c -eq 0x2E)               { [void]$sb.Append('.'); $isR=$true; $p.Value++ }
            else { break }
        }
        if ($sb.Length -gt 0) {
            $str = $sb.ToString()
            if ($isR) { return @{ Type='Real';    Value=[double]$str  } }
            else       { return @{ Type='Integer'; Value=[int64]$str   } }
        }
    }

    # Caractere inconnu - on avance
    $p.Value++
    return $null
}

# Lit un objet PDF complet (avec resolution des references N G R)
function script:ReadObject([ref]$p) {
    $t1 = script:ReadToken $p
    if ($null -eq $t1) { return $null }

    if ($t1.Type -eq 'Integer') {
        $save = $p.Value
        script:SkipWS $p
        $t2 = script:ReadToken $p
        if ($null -ne $t2 -and $t2.Type -eq 'Integer') {
            script:SkipWS $p
            $t3 = script:ReadToken $p
            if ($null -ne $t3 -and $t3.Type -eq 'Keyword' -and $t3.Value -eq 'R') {
                return @{ Type='Ref'; ObjNum=[int]$t1.Value; Gen=[int]$t2.Value }
            }
        }
        $p.Value = $save
    }
    return $t1
}

# ----------------------- XRef -------------------------------------------------

function script:FindStartXref {
    $win   = [Math]::Min(2048, $script:Bytes.Length)
    $start = $script:Bytes.Length - $win
    $pat   = [System.Text.Encoding]::ASCII.GetBytes('startxref')
    $last  = -1
    for ($i=$start; $i -le $script:Bytes.Length - $pat.Length; $i++) {
        $ok = $true
        for ($j=0; $j -lt $pat.Length; $j++) { if ($script:Bytes[$i+$j] -ne $pat[$j]) { $ok=$false; break } }
        if ($ok) { $last=$i }
    }
    if ($last -lt 0) { throw 'startxref introuvable - fichier PDF corrompu ?' }
    $p = [ref]($last + 9)
    script:SkipWS $p
    $t = script:ReadToken $p
    return [int]$t.Value
}

function script:ParseXrefTable([int]$off) {
    $p = [ref]$off
    script:SkipWS $p
    $null = script:ReadToken $p   # 'xref'

    while ($true) {
        script:SkipWS $p
        if ($p.Value -ge $script:Bytes.Length) { break }
        $peek = script:GetASCII $p.Value 7
        if ($peek.StartsWith('trailer')) { break }

        $ts = script:ReadToken $p; if ($null -eq $ts -or $ts.Type -ne 'Integer') { break }
        $tc = script:ReadToken $p; if ($null -eq $tc -or $tc.Type -ne 'Integer') { break }
        $startObj = [int]$ts.Value; $count = [int]$tc.Value

        # Sauter EOL apres la paire d'entiers
        while ($p.Value -lt $script:Bytes.Length -and $script:Bytes[$p.Value] -in 0x0D,0x0A,0x20) { $p.Value++ }

        for ($i=0; $i -lt $count; $i++) {
            if ($p.Value + 20 -gt $script:Bytes.Length) { break }
            $entry  = script:GetASCII $p.Value 20
            $objOff = [int64]$entry.Substring(0,10).Trim()
            $gen    = [int]$entry.Substring(11,5).Trim()
            $type   = $entry[17]
            $num    = $startObj + $i
            if ($type -eq 'n' -and -not $script:XrefMap.ContainsKey($num)) {
                $script:XrefMap[$num] = @{ Offset=[int]$objOff; Gen=$gen; InObjStm=$false }
            }
            $p.Value += 20
        }
    }

    script:SkipWS $p
    $null = script:ReadToken $p   # 'trailer'
    script:SkipWS $p
    $td = script:ReadToken $p
    if ($null -ne $td -and $td.Type -eq 'Dict') {
        if ($null -eq $script:TrailerDict) { $script:TrailerDict = $td.Value }
        if ($td.Value.ContainsKey('Prev')) {
            $null = script:ParseXrefSection ([int]$td.Value['Prev'].Value)
        }
    }
}

function script:ParseXrefStream([int]$off) {
    $p = [ref]$off
    $null = script:ReadToken $p; $null = script:ReadToken $p; $null = script:ReadToken $p  # N G obj
    script:SkipWS $p
    $dt = script:ReadToken $p
    if ($null -eq $dt -or $dt.Type -ne 'Dict') { return }
    $dict = $dt.Value
    if ($null -eq $script:TrailerDict) { $script:TrailerDict = $dict }

    # Sauter 'stream' + EOL
    script:SkipWS $p
    $null = script:ReadToken $p  # 'stream'
    if ($p.Value -lt $script:Bytes.Length -and $script:Bytes[$p.Value] -eq 0x0D) { $p.Value++ }
    if ($p.Value -lt $script:Bytes.Length -and $script:Bytes[$p.Value] -eq 0x0A) { $p.Value++ }

    $lenTok = if ($dict.ContainsKey('Length')) { $dict['Length'] } else { $null }
    $sLen   = 0
    if ($null -ne $lenTok) {
        if ($lenTok.Type -eq 'Integer') { $sLen = [int]$lenTok.Value }
        elseif ($lenTok.Type -eq 'Ref')  {
            $lo = try { script:GetPdfObject $lenTok.ObjNum } catch { $null }
            if ($null -ne $lo -and $lo.Type -eq 'Integer') { $sLen = [int]$lo.Value }
        }
    }
    # Fallback : scanner 'endstream' si longueur inconnue
    if ($sLen -le 0) {
        $esPat = [System.Text.Encoding]::ASCII.GetBytes('endstream')
        for ($ei = $p.Value; $ei -le $script:Bytes.Length - $esPat.Length; $ei++) {
            $ok2 = $true
            for ($ej=0; $ej -lt $esPat.Length; $ej++) {
                if ($script:Bytes[$ei+$ej] -ne $esPat[$ej]) { $ok2=$false; break }
            }
            if ($ok2) { $sLen = $ei - $p.Value; break }
        }
    }
    if ($sLen -le 0) { return }
    $raw    = $script:Bytes[$p.Value..($p.Value+$sLen-1)]
    $fTok   = if ($dict.ContainsKey('Filter')) { $dict['Filter'] } else { $null }
    $dec    = script:DecodeStream $raw $fTok $null
    if ($null -eq $dec) { return }

    # W : largeurs de champs
    $W = @()
    if ($dict.ContainsKey('W') -and $dict['W'].Type -eq 'Array') {
        $dict['W'].Value | ForEach-Object { $W += [int]$_.Value }
    }
    if ($W.Count -ne 3) { return }

    # Index
    $idx = @()
    if ($dict.ContainsKey('Index') -and $dict['Index'].Type -eq 'Array') {
        $dict['Index'].Value | ForEach-Object { $idx += [int]$_.Value }
    } else {
        $sz = if ($dict.ContainsKey('Size')) { [int]$dict['Size'].Value } else { 0 }
        $idx = @(0, $sz)
    }

    $rowSz = $W[0]+$W[1]+$W[2]
    $dPos  = 0
    for ($xi=0; $xi -lt $idx.Count-1; $xi+=2) {
        $so=$idx[$xi]; $cnt=$idx[$xi+1]
        for ($i=0; $i -lt $cnt; $i++) {
            if ($dPos + $rowSz -gt $dec.Length) { break }
            $f0 = if ($W[0] -gt 0) { script:ReadInt $dec $dPos $W[0] } else { 1 }
            $f1 = script:ReadInt $dec ($dPos+$W[0]) $W[1]
            $f2 = script:ReadInt $dec ($dPos+$W[0]+$W[1]) $W[2]
            $num = $so + $i
            if (-not $script:XrefMap.ContainsKey($num)) {
                switch ($f0) {
                    1 { $script:XrefMap[$num]=@{ Offset=$f1; Gen=$f2; InObjStm=$false } }
                    2 { $script:XrefMap[$num]=@{ Offset=0;  Gen=0;   InObjStm=$true; ObjStmNum=$f1; Index=$f2 } }
                }
            }
            $dPos += $rowSz
        }
    }

    if ($dict.ContainsKey('Prev')) {
        $null = script:ParseXrefSection ([int]$dict['Prev'].Value)
    }
}

function script:ParseXrefSection([int]$off) {
    if ($off -lt 0 -or $off -ge $script:Bytes.Length) { return }
    $peek = script:GetASCII $off ([Math]::Min(10,$script:Bytes.Length-$off))
    if ($peek.TrimStart().StartsWith('xref')) { script:ParseXrefTable $off }
    else                                       { script:ParseXrefStream $off }
}

# ----------------------- Chargement d'objets ----------------------------------

function script:LoadObjStm([int]$stmNum) {
    if (-not $script:XrefMap.ContainsKey($stmNum)) { return }
    $xr = $script:XrefMap[$stmNum]
    if ($xr.InObjStm) { return }

    $p = [ref]([int]$xr.Offset)
    $null = script:ReadToken $p; $null = script:ReadToken $p
    $kw = script:ReadToken $p
    if ($null -eq $kw -or $kw.Value -ne 'obj') { return }
    script:SkipWS $p
    $dt = script:ReadToken $p
    if ($null -eq $dt -or $dt.Type -ne 'Dict') { return }
    $dict = $dt.Value

    script:SkipWS $p
    $null = script:ReadToken $p  # 'stream'
    if ($p.Value -lt $script:Bytes.Length -and $script:Bytes[$p.Value] -eq 0x0D) { $p.Value++ }
    if ($p.Value -lt $script:Bytes.Length -and $script:Bytes[$p.Value] -eq 0x0A) { $p.Value++ }

    $sLen = if ($dict.ContainsKey('Length') -and $dict['Length'].Type -eq 'Integer') { [int]$dict['Length'].Value } else { 0 }
    $raw  = $script:Bytes[$p.Value..($p.Value+$sLen-1)]
    $fTok = if ($dict.ContainsKey('Filter')) { $dict['Filter'] } else { $null }
    $dec  = script:DecodeStream $raw $fTok $null
    if ($null -eq $dec) { return }

    $N     = if ($dict.ContainsKey('N'))     { [int]$dict['N'].Value }     else { 0 }
    $first = if ($dict.ContainsKey('First')) { [int]$dict['First'].Value } else { 0 }

    # Parser l'en-tete (paires objNum offset)
    $oldBytes = $script:Bytes
    $script:Bytes = $dec[0..($first-1)]
    $hp = [ref]0
    $entries = @()
    for ($i=0; $i -lt $N; $i++) {
        $nt = script:ReadToken $hp; $ot = script:ReadToken $hp
        if ($null -ne $nt -and $null -ne $ot) {
            $entries += @{ ObjNum=[int]$nt.Value; Off=[int]$ot.Value }
        }
    }

    # Parser chaque objet
    $body = $dec[$first..($dec.Length-1)]
    $script:Bytes = $body
    foreach ($e in $entries) {
        if (-not $script:ObjCache.ContainsKey($e.ObjNum)) {
            $op = [ref]$e.Off
            $obj = script:ReadToken $op
            if ($null -ne $obj) { $script:ObjCache[$e.ObjNum] = $obj }
        }
    }
    $script:Bytes = $oldBytes
}

function script:LoadObjectDirect([int]$n) {
    $xr = $script:XrefMap[$n]
    if ($xr.InObjStm) { return $null }

    $p = [ref]([int]$xr.Offset)
    $null = script:ReadToken $p; $null = script:ReadToken $p  # N G
    $kw = script:ReadToken $p
    if ($null -eq $kw -or $kw.Value -ne 'obj') { return $null }
    script:SkipWS $p
    $obj = script:ReadToken $p
    if ($null -eq $obj) { return $null }

    # Verification stream
    script:SkipWS $p
    if ($p.Value -lt $script:Bytes.Length -and $obj.Type -eq 'Dict') {
        $peek = script:GetASCII $p.Value ([Math]::Min(6,$script:Bytes.Length-$p.Value))
        if ($peek.StartsWith('stream')) {
            $null = $null  # stream keyword already consumed via peek
            $p.Value += 6
            if ($p.Value -lt $script:Bytes.Length -and $script:Bytes[$p.Value] -eq 0x0D) { $p.Value++ }
            if ($p.Value -lt $script:Bytes.Length -and $script:Bytes[$p.Value] -eq 0x0A) { $p.Value++ }

            $dict  = $obj.Value
            $lenTok = if ($dict.ContainsKey('Length')) { $dict['Length'] } else { $null }
            $sLen  = 0
            if ($null -ne $lenTok) {
                if ($lenTok.Type -eq 'Integer') { $sLen = [int]$lenTok.Value }
                elseif ($lenTok.Type -eq 'Ref') {
                    $lo = script:GetPdfObject $lenTok.ObjNum
                    if ($null -ne $lo -and $lo.Type -eq 'Integer') { $sLen = [int]$lo.Value }
                }
            }
            if ($sLen -gt 0 -and $p.Value + $sLen -le $script:Bytes.Length) {
                $raw  = $script:Bytes[$p.Value..($p.Value+$sLen-1)]
                $fTok = if ($dict.ContainsKey('Filter')) { $dict['Filter'] } else { $null }
                $dec  = script:DecodeStream $raw $fTok $null
                return @{ Type='Stream'; Dict=$dict; RawData=$raw; Data=$dec }
            }
            return @{ Type='Stream'; Dict=$dict; RawData=$null; Data=$null }
        }
    }
    return $obj
}

function script:GetPdfObject([int]$n) {
    if ($script:ObjCache.ContainsKey($n)) { return $script:ObjCache[$n] }
    if (-not $script:XrefMap.ContainsKey($n)) { return $null }
    $xr = $script:XrefMap[$n]
    $obj = $null
    if ($xr.InObjStm) {
        $null = script:LoadObjStm $xr.ObjStmNum
        $obj = if ($script:ObjCache.ContainsKey($n)) { $script:ObjCache[$n] } else { $null }
    } else {
        try { $obj = script:LoadObjectDirect $n } catch { $obj = $null }
    }
    if ($null -ne $obj) { $script:ObjCache[$n] = $obj }
    return $obj
}

function script:Resolve($tok) {
    if ($null -eq $tok) { return $null }
    if ($tok.Type -eq 'Ref') { return script:GetPdfObject $tok.ObjNum }
    return $tok
}

function script:GetStr($tok) {
    $t = script:Resolve $tok
    if ($null -eq $t) { return $null }
    switch ($t.Type) {
        'String'    { return $t.Value }
        'HexString' { return $t.StringValue }
        'Stream'    { if ($null -ne $t.Data) { return [System.Text.Encoding]::Latin1.GetString($t.Data) } }
        'Name'      { return $t.Value }
    }
    return $null
}

function script:GetDict($tok) {
    $t = script:Resolve $tok
    if ($null -eq $t) { return $null }
    if ($t.Type -eq 'Dict')   { return $t.Value }
    if ($t.Type -eq 'Stream') { return $t.Dict  }
    return $null
}

# ----------------------- Arbre de noms ----------------------------------------

function script:WalkNameTree($nodeTok, [System.Collections.Generic.List[hashtable]]$out) {
    $node = script:Resolve $nodeTok
    if ($null -eq $node) { return }
    $dict = script:GetDict $node
    if ($null -eq $dict) { return }

    if ($dict.ContainsKey('Names')) {
        $na = script:Resolve $dict['Names']
        if ($null -ne $na -and $na.Type -eq 'Array') {
            $items = $na.Value
            for ($i=0; $i+1 -lt $items.Count; $i+=2) {
                $out.Add(@{ Name=(script:GetStr $items[$i]); Value=$items[$i+1] })
            }
        }
    }
    if ($dict.ContainsKey('Kids')) {
        $kids = script:Resolve $dict['Kids']
        if ($null -ne $kids -and $kids.Type -eq 'Array') {
            $kids.Value | ForEach-Object { $null = script:WalkNameTree $_ $out }
        }
    }
}

# ----------------------- Catalogue --------------------------------------------

function script:GetCatalog {
    # Methode 1 : via /Root du trailer
    if ($null -ne $script:TrailerDict -and $script:TrailerDict.ContainsKey('Root')) {
        $r = script:Resolve $script:TrailerDict['Root']
        $d = script:GetDict $r
        if ($null -ne $d) { return $d }
    }
    # Methode 2 : scan du trailer dans le fichier
    if ($null -eq $script:TrailerDict) {
        $tPat = [System.Text.Encoding]::ASCII.GetBytes('trailer')
        for ($ti = $script:Bytes.Length - 7; $ti -ge 0; $ti--) {
            $ok3 = $true
            for ($tj=0; $tj -lt 7; $tj++) { if ($script:Bytes[$ti+$tj] -ne $tPat[$tj]) { $ok3=$false; break } }
            if ($ok3) {
                $tp = [ref]($ti + 7); script:SkipWS $tp
                $td2 = script:ReadToken $tp
                if ($null -ne $td2 -and $td2.Type -eq 'Dict') {
                    $script:TrailerDict = $td2.Value
                    if ($script:TrailerDict.ContainsKey('Root')) {
                        $r2 = script:Resolve $script:TrailerDict['Root']
                        $d2 = script:GetDict $r2
                        if ($null -ne $d2) { return $d2 }
                    }
                    break
                }
            }
        }
    }
    # Methode 3 : scan lineaire de tous les objets charges
    foreach ($n in ($script:XrefMap.Keys | Sort-Object)) {
        try {
            $obj = script:GetPdfObject $n
            $dict = script:GetDict $obj
            if ($null -ne $dict -and $dict.ContainsKey('Type') -and $dict['Type'].Value -eq 'Catalog') {
                Write-Host "  [fallback] Catalogue trouve dans objet #$n" -ForegroundColor Yellow
                return $dict
            }
        } catch { }
    }
    return $null
}

# ----------------------- Extracteurs ------------------------------------------

# --- Affichage + collecte JS d'une action
function script:DescribeAction($tok, [int]$depth=0, [string]$label='Action') {
    $t = script:Resolve $tok
    if ($null -eq $t) { return }
    $dict = script:GetDict $t
    if ($null -eq $dict) { return }

    $ind = '  ' * $depth
    $sType = if ($dict.ContainsKey('S')) { $dict['S'].Value } else { '?' }
    Write-Host "$ind+- " -NoNewline -ForegroundColor DarkGray
    Write-Host "[$label] " -NoNewline -ForegroundColor Cyan
    Write-Host "Type : " -NoNewline -ForegroundColor DarkCyan
    $typeColor = switch ($sType) {
        'JavaScript' { 'Yellow' } 'Launch' { 'Red' } 'ImportData' { 'Red' } default { 'White' }
    }
    Write-Host $sType -ForegroundColor $typeColor

    switch ($sType) {
        'JavaScript' {
            $js = script:GetStr (if ($dict.ContainsKey('JS')) { $dict['JS'] } else { $null })
            if ($null -ne $js) {
                $script:JSSnippets.Add(@{ Source="Action/$label(depth=$depth)"; Code=$js.Trim() })
                Write-Host "$ind|  -> JavaScript : $($js.Length) caracteres" -ForegroundColor Yellow
            }
        }
        'URI'    { Write-Host "$ind|  -> URI : $(script:GetStr $dict['URI'])" -ForegroundColor Gray }
        'GoTo'   { Write-Host "$ind|  -> Destination interne" -ForegroundColor Gray }
        'GoToR'  { Write-Host "$ind|  -> Fichier ext. : $(script:GetStr $dict['F'])" -ForegroundColor Gray }
        'Launch' { Write-Host "$ind|  [!]  Lancement : $(script:GetStr $dict['F'])" -ForegroundColor Red }
        'Named'  { Write-Host "$ind|  -> Nom : $($dict['N'].Value)" -ForegroundColor Gray }
        'SubmitForm' { Write-Host "$ind|  -> URL formulaire : $(script:GetStr $dict['F'])" -ForegroundColor Gray }
        'ImportData' { Write-Host "$ind|  [!]  Import donnees" -ForegroundColor Red }
        'SetOCGState'{ Write-Host "$ind|  -> Gestion couche OCG" -ForegroundColor Gray }
        'Rendition'  { Write-Host "$ind|  -> Action multimedia/rendition" -ForegroundColor Gray }
        'Trans'      { Write-Host "$ind|  -> Transition de page" -ForegroundColor Gray }
        'ResetForm'  { Write-Host "$ind|  -> Remise a zero de formulaire" -ForegroundColor Gray }
        'Hide'       { Write-Host "$ind|  -> Masquage de champ" -ForegroundColor Gray }
    }

    # Actions chainees /Next
    if ($dict.ContainsKey('Next')) {
        $nx = script:Resolve $dict['Next']
        if ($null -ne $nx) {
            if ($nx.Type -eq 'Array') {
                $nx.Value | ForEach-Object { $null = script:DescribeAction $_ ($depth+1) 'Next' }
            } else {
                $null = script:DescribeAction $dict['Next'] ($depth+1) 'Next'
            }
        }
    }
}

# --- Actions de demarrage
function script:ExtractOpenActions($cat) {
    $found = $false

    if ($cat.ContainsKey('OpenAction')) {
        $found = $true
        Write-Host '  >> /OpenAction' -ForegroundColor Cyan
        $null = script:DescribeAction $cat['OpenAction'] 1 'OpenAction'
    }

    if ($cat.ContainsKey('AA')) {
        $aa = script:GetDict (script:Resolve $cat['AA'])
        if ($null -ne $aa -and $aa -is [System.Collections.IDictionary]) {
            $found = $true
            $aaLabels = @{ WC='WillClose'; WS='WillSave'; DS='DidSave'; WP='WillPrint'; DP='DidPrint' }
            Write-Host '  >> /AA - Actions additionnelles (catalogue)' -ForegroundColor Cyan
            foreach ($k in $aa.Keys) {
                $lbl = if ($aaLabels.ContainsKey($k)) { $aaLabels[$k] } else { $k }
                $null = script:DescribeAction $aa[$k] 1 $lbl
            }
        }
    }

    if (-not $found) {
        Write-Host '  Aucune action de demarrage detectee' -ForegroundColor DarkGray
    }
    return $found
}

# --- JavaScript via /Names/JavaScript
function script:ExtractJSFromNames($cat) {
    if (-not $cat.ContainsKey('Names')) { return }
    $namesDict = script:GetDict (script:Resolve $cat['Names'])
    if ($null -eq $namesDict -or -not $namesDict.ContainsKey('JavaScript')) { return }

    $list = [System.Collections.Generic.List[hashtable]]::new()
    $null = script:WalkNameTree $namesDict['JavaScript'] $list

    foreach ($e in $list) {
        $aDict = script:GetDict (script:Resolve $e.Value)
        if ($null -ne $aDict -and $aDict.ContainsKey('JS')) {
            $js = script:GetStr $aDict['JS']
            if ($null -ne $js) {
                $already = $false
                $script:JSSnippets | ForEach-Object { if ($_.Code -eq $js.Trim()) { $already=$true } }
                if (-not $already) {
                    $script:JSSnippets.Add(@{ Source="/Names/JavaScript: $($e.Name)"; Code=$js.Trim() })
                }
            }
        }
    }
}

# --- Scan general de tous les objets pour detecter JS cache
function script:ScanAllJS {
    foreach ($n in $script:XrefMap.Keys) {
        try {
            $obj = script:GetPdfObject $n
            if ($null -eq $obj) { continue }
            $dict = script:GetDict $obj
            if ($null -eq $dict) { continue }
            $sType = if ($dict.ContainsKey('S')) { $dict['S'].Value } else { '' }
            if ($sType -eq 'JavaScript' -and $dict.ContainsKey('JS')) {
                $js = script:GetStr $dict['JS']
                if ($null -ne $js) {
                    $already = $false
                    $script:JSSnippets | ForEach-Object { if ($_.Code -eq $js.Trim()) { $already=$true } }
                    if (-not $already) {
                        $script:JSSnippets.Add(@{ Source="Objet #$n (scan global)"; Code=$js.Trim() })
                    }
                }
            }
        } catch { }
    }
}

# --- Fichiers incorpores
function script:ExtractEmbeddedFiles($cat) {
    $files = [System.Collections.Generic.List[hashtable]]::new()
    if (-not $cat.ContainsKey('Names')) { return $files }
    $namesDict = script:GetDict (script:Resolve $cat['Names'])
    if ($null -eq $namesDict -or -not $namesDict.ContainsKey('EmbeddedFiles')) { return $files }

    $list = [System.Collections.Generic.List[hashtable]]::new()
    $null = script:WalkNameTree $namesDict['EmbeddedFiles'] $list

    foreach ($e in $list) {
        $fsDict = script:GetDict (script:Resolve $e.Value)
        if ($null -eq $fsDict) { continue }

        $filename = if ($fsDict.ContainsKey('UF')) { script:GetStr $fsDict['UF'] }
                    elseif ($fsDict.ContainsKey('F')) { script:GetStr $fsDict['F'] }
                    else { $e.Name }
        $desc   = if ($fsDict.ContainsKey('Desc')) { script:GetStr $fsDict['Desc'] } else { '' }
        $size   = '?'; $mime=''; $modDate=''

        if ($fsDict.ContainsKey('EF')) {
            $efDict = script:GetDict (script:Resolve $fsDict['EF'])
            if ($null -ne $efDict) {
                $streamKey = if ($efDict.ContainsKey('UF')) { 'UF' } elseif ($efDict.ContainsKey('F')) { 'F' } else { $null }
                if ($null -ne $streamKey) {
                    $fs = script:Resolve $efDict[$streamKey]
                    if ($null -ne $fs -and $fs.Type -eq 'Stream') {
                        $size = if ($null -ne $fs.Data) { "$($fs.Data.Length) octets" } else { '? (non decode)' }
                        if ($fs.Dict.ContainsKey('Subtype')) { $mime = $fs.Dict['Subtype'].Value }
                        if ($fs.Dict.ContainsKey('Params')) {
                            $prm = script:GetDict (script:Resolve $fs.Dict['Params'])
                            if ($null -ne $prm) {
                                if ($prm.ContainsKey('Size'))    { $size    = "$([int]$prm['Size'].Value) octets" }
                                if ($prm.ContainsKey('ModDate')) { $modDate = script:GetStr $prm['ModDate'] }
                                if ($prm.ContainsKey('MIMEType')){ $mime    = script:GetStr $prm['MIMEType'] }
                            }
                        }
                        $files.Add(@{
                            Name=$filename; Desc=$desc; Size=$size
                            MimeType=$mime; ModDate=$modDate
                            Stream=$fs
                        })
                        continue
                    }
                }
            }
        }
        $files.Add(@{ Name=$filename; Desc=$desc; Size=$size; MimeType=$mime; ModDate=$modDate; Stream=$null })
    }
    return $files
}

# --- Metadonnees /Info
function script:ExtractInfoMeta {
    $meta = @{}
    if ($null -eq $script:TrailerDict -or -not $script:TrailerDict.ContainsKey('Info')) { return $meta }
    $infoDict = script:GetDict (script:Resolve $script:TrailerDict['Info'])
    if ($null -eq $infoDict -or $infoDict -isnot [System.Collections.IDictionary]) { return $meta }
    foreach ($k in $infoDict.Keys) {
        $v = script:GetStr $infoDict[$k]
        if ($null -ne $v) { $meta[$k] = $v }
    }
    return $meta
}

# ----------------------- Affichage --------------------------------------------

function script:WriteBanner {
    Write-Host ''
    Write-Host '+==================================================================+' -ForegroundColor Cyan
    Write-Host '|         PDF Forensic Analyzer - PowerShell Edition              |' -ForegroundColor Cyan
    Write-Host '|    Actions - JavaScript - Fichiers incorpores - Metadonnees     |' -ForegroundColor Cyan
    Write-Host '+==================================================================+' -ForegroundColor Cyan
}

function script:WriteSection([string]$title) {
    $line = '-' * ([Math]::Max(0, 66 - $title.Length - 4))
    Write-Host ''
    Write-Host "+- " -NoNewline -ForegroundColor DarkGray
    Write-Host $title -NoNewline -ForegroundColor Magenta
    Write-Host " $line" -ForegroundColor DarkGray
}

# ----------------------- Main -------------------------------------------------

script:WriteBanner

# Validation du chemin
$resolved = Resolve-Path $Path -ErrorAction SilentlyContinue
if ($null -eq $resolved) { Write-Host "ERREUR : Fichier introuvable : $Path" -ForegroundColor Red; exit 1 }
$fullPath = $resolved.Path
$fileInfo = Get-Item $fullPath
Write-Host "`n  Fichier : $fullPath" -ForegroundColor Gray
Write-Host "  Taille  : $([math]::Round($fileInfo.Length/1KB, 2)) Ko   |   Modifie : $($fileInfo.LastWriteTime)" -ForegroundColor Gray

# Lecture du fichier
$script:Bytes = [System.IO.File]::ReadAllBytes($fullPath)

# Verification en-tete PDF
if ($script:Bytes.Length -lt 8) { Write-Host 'ERREUR : Fichier trop court' -ForegroundColor Red; exit 1 }
$hdr = script:GetASCII 0 8
if (-not $hdr.StartsWith('%PDF-')) { Write-Host 'ERREUR : Signature PDF invalide' -ForegroundColor Red; exit 1 }
$script:PdfVersion = ($hdr.Substring(5)).Trim()
Write-Host "  Version : PDF $script:PdfVersion" -ForegroundColor Green

# Detection chiffrement
$encPat = [System.Text.Encoding]::ASCII.GetBytes('/Encrypt')
$isEncrypted = $false
for ($ei=0; $ei -lt $script:Bytes.Length - $encPat.Length; $ei++) {
    $ok=$true; for ($ej=0; $ej -lt $encPat.Length; $ej++) { if ($script:Bytes[$ei+$ej] -ne $encPat[$ej]) { $ok=$false; break } }
    if ($ok) { $isEncrypted=$true; break }
}
if ($isEncrypted) { Write-Host '  [!]  Document chiffre - certaines donnees peuvent etre inaccessibles' -ForegroundColor Yellow }

# Construction de la XRef
Write-Host '  Analyse XRef...' -ForegroundColor DarkGray
$sxOff = script:FindStartXref
$null = script:ParseXrefSection $sxOff
# Fallback : scan lineaire si XRef vide ou trop petit
if ($script:XrefMap.Count -lt 2) {
    Write-Host '  [fallback] XRef insuffisant - scan lineaire du fichier...' -ForegroundColor Yellow
    $objKw = [System.Text.Encoding]::ASCII.GetBytes('obj')
    for ($li = 4; $li -lt $script:Bytes.Length - 4; $li++) {
        if ($script:Bytes[$li]   -eq 0x6F -and
            $script:Bytes[$li+1] -eq 0x62 -and
            $script:Bytes[$li+2] -eq 0x6A -and
            (script:IsWS $script:Bytes[$li+3])) {
            $lj = $li - 1
            while ($lj -ge 0 -and (script:IsWS $script:Bytes[$lj])) { $lj-- }
            if ($lj -lt 0 -or $script:Bytes[$lj] -lt 0x30 -or $script:Bytes[$lj] -gt 0x39) { continue }
            $gE = $lj
            while ($lj -ge 0 -and $script:Bytes[$lj] -ge 0x30 -and $script:Bytes[$lj] -le 0x39) { $lj-- }
            $gen2 = [int]([System.Text.Encoding]::ASCII.GetString($script:Bytes, $lj+1, $gE-$lj))
            $lj--
            while ($lj -ge 0 -and (script:IsWS $script:Bytes[$lj])) { $lj-- }
            if ($lj -lt 0 -or $script:Bytes[$lj] -lt 0x30 -or $script:Bytes[$lj] -gt 0x39) { continue }
            $nE = $lj
            while ($lj -ge 0 -and $script:Bytes[$lj] -ge 0x30 -and $script:Bytes[$lj] -le 0x39) { $lj-- }
            if ($lj -ge 0 -and -not (script:IsWS $script:Bytes[$lj])) { continue }
            $oNum = [int]([System.Text.Encoding]::ASCII.GetString($script:Bytes, $lj+1, $nE-$lj))
            if ($oNum -gt 0 -and -not $script:XrefMap.ContainsKey($oNum)) {
                $script:XrefMap[$oNum] = @{ Offset=($lj+1); Gen=$gen2; InObjStm=$false }
            }
        }
    }
}
Write-Host "  Objets XRef indexes : $($script:XrefMap.Count)" -ForegroundColor DarkGray

# Catalogue
$cat = script:GetCatalog
if ($null -eq $cat) { Write-Host 'ERREUR : Catalogue PDF introuvable' -ForegroundColor Red; exit 1 }

# ========================================================================
#  1. METADONNEES
# ========================================================================
script:WriteSection 'METADONNEES'
$meta = script:ExtractInfoMeta

$fields = @{
    Title='Titre'; Author='Auteur'; Subject='Sujet'; Keywords='Mots-cles'
    Creator='Createur'; Producer='Producteur'
    CreationDate='Cree le'; ModDate='Modifie le'; Trapped='Piege'
}
if ($meta.Count -eq 0) {
    Write-Host '  Aucune metadonnee /Info' -ForegroundColor DarkGray
} else {
    foreach ($k in $fields.Keys) {
        if ($meta.ContainsKey($k)) {
            Write-Host "  $($fields[$k].PadRight(12)): " -NoNewline -ForegroundColor Cyan
            Write-Host $meta[$k] -ForegroundColor White
        }
    }
    foreach ($k in ($meta.Keys | Where-Object { -not $fields.ContainsKey($_) })) {
        Write-Host "  $($k.PadRight(12)): " -NoNewline -ForegroundColor DarkCyan
        Write-Host $meta[$k] -ForegroundColor White
    }
}

# Nombre de pages
if ($cat.ContainsKey('Pages')) {
    $pages = script:GetDict (script:Resolve $cat['Pages'])
    if ($null -ne $pages -and $pages.ContainsKey('Count')) {
        Write-Host "  $('Pages'.PadRight(12)): " -NoNewline -ForegroundColor Cyan
        Write-Host $pages['Count'].Value -ForegroundColor White
    }
}

# Version dans le catalogue (PDF 1.4+ peut surcharger l'en-tete)
if ($cat.ContainsKey('Version')) {
    Write-Host "  $('Version cat.'.PadRight(12)): " -NoNewline -ForegroundColor DarkCyan
    Write-Host $cat['Version'].Value -ForegroundColor White
}

# XMP
if ($cat.ContainsKey('Metadata')) {
    $xmpStream = script:Resolve $cat['Metadata']
    if ($null -ne $xmpStream -and $xmpStream.Type -eq 'Stream' -and $null -ne $xmpStream.Data) {
        $xmpText = [System.Text.Encoding]::UTF8.GetString($xmpStream.Data)
        Write-Host "  $('XMP'.PadRight(12)): " -NoNewline -ForegroundColor DarkCyan
        Write-Host "$($xmpText.Length) octets presents" -ForegroundColor Gray
        $xmpPairs = @{
            'dc:title'       ='Titre XMP'
            'dc:creator'     ='Auteur XMP'
            'xmp:CreateDate' ='Cree (XMP)'
            'xmp:ModifyDate' ='Modifie (XMP)'
            'pdf:Producer'   ='Producteur XMP'
        }
        foreach ($xk in $xmpPairs.Keys) {
            if ($xmpText -match "<$xk[^>]*>(?:<[^>]+>)?([^<]+)") {
                Write-Host "  $($xmpPairs[$xk].PadRight(12)): " -NoNewline -ForegroundColor DarkCyan
                Write-Host $Matches[1].Trim() -ForegroundColor Gray
            }
        }
    }
}

# ========================================================================
#  2. ACTIONS DE DEMARRAGE
# ========================================================================
script:WriteSection 'ACTIONS DE DEMARRAGE'
$hasActions = script:ExtractOpenActions $cat

# ========================================================================
#  3. JAVASCRIPT
# ========================================================================
script:WriteSection 'JAVASCRIPT'
$null = script:ExtractJSFromNames $cat
$null = script:ScanAllJS

if ($script:JSSnippets.Count -eq 0) {
    Write-Host '  Aucun JavaScript detecte' -ForegroundColor DarkGray
} else {
    Write-Host "  $($script:JSSnippets.Count) script(s) JavaScript trouve(s)" -ForegroundColor Yellow
    for ($si=0; $si -lt $script:JSSnippets.Count; $si++) {
        $js = $script:JSSnippets[$si]
        Write-Host "`n  +- Script #$($si+1) - $($js.Source)" -ForegroundColor Yellow
        $lines = $js.Code -split "`r?`n"
        $max   = 60
        $shown = [Math]::Min($lines.Count, $max)
        for ($li=0; $li -lt $shown; $li++) {
            Write-Host "  |  $($lines[$li])" -ForegroundColor White
        }
        if ($lines.Count -gt $max) {
            Write-Host "  |  ... ($($lines.Count - $max) ligne(s) supplementaire(s))" -ForegroundColor DarkGray
        }
        Write-Host "  +- Total : $($js.Code.Length) caracteres" -ForegroundColor DarkGray

        if ($ExportJS -and $OutputDir -ne '') {
            $jsFile = Join-Path $OutputDir "script_$($si+1).js"
            $js.Code | Set-Content -Path $jsFile -Encoding UTF8
            Write-Host "     Exporte -> $jsFile" -ForegroundColor Green
        }
    }
}

# ========================================================================
#  4. FICHIERS INCORPORES
# ========================================================================
script:WriteSection 'FICHIERS INCORPORES'
$embedded = script:ExtractEmbeddedFiles $cat
# Garantir que $embedded est bien une List/collection avec .Count
if ($embedded -isnot [System.Collections.ICollection]) {
    $embedded = [System.Collections.Generic.List[hashtable]]::new()
}

if ($embedded.Count -eq 0) {
    Write-Host '  Aucun fichier incorpore' -ForegroundColor DarkGray
} else {
    Write-Host "  $($embedded.Count) fichier(s) incorpore(s) :" -ForegroundColor Green
    foreach ($ef in $embedded) {
        Write-Host ''
        Write-Host "  +- Nom      : " -NoNewline -ForegroundColor Cyan
        Write-Host $ef.Name -ForegroundColor White
        if ($ef.Desc)     { Write-Host "  |  Desc     : $($ef.Desc)"     -ForegroundColor Gray }
        if ($ef.MimeType) { Write-Host "  |  Type     : $($ef.MimeType)" -ForegroundColor Gray }
        Write-Host "  |  Taille   : $($ef.Size)" -ForegroundColor Gray
        if ($ef.ModDate)  { Write-Host "  +- Modifie  : $($ef.ModDate)"  -ForegroundColor Gray }
        else              { Write-Host "  +-" -ForegroundColor DarkGray }

        if ($ExportFiles -and $OutputDir -ne '' -and $null -ne $ef.Stream -and $null -ne $ef.Stream.Data) {
            $safeName = $ef.Name
            foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
                $safeName = $safeName.Replace([string]$c, '_')
            }
            $outFile  = Join-Path $OutputDir $safeName
            [System.IO.File]::WriteAllBytes($outFile, $ef.Stream.Data)
            Write-Host "     Exporte -> $outFile" -ForegroundColor Green
        }
    }
}

# ========================================================================
#  RESUME
# ========================================================================
script:WriteSection 'RESUME'

$riskScore = 0
if ($hasActions)                    { $riskScore++ }
if ($script:JSSnippets.Count -gt 0) { $riskScore++ }
if ($embedded.Count -gt 0)          { $riskScore++ }
if ($isEncrypted)                    { $riskScore++ }

$riskLabel = switch ($riskScore) { 0 { 'FAIBLE' } 1 { 'FAIBLE' } 2 { 'MODERE' } 3 { 'ELEVE' } default { 'TRES ELEVE' } }
$riskColor = switch ($riskScore) { 0 { 'Green'  } 1 { 'Green'  } 2 { 'Yellow' } 3 { 'Red'   } default { 'Magenta'   } }

$yn = { param($v) if ($v) { 'Oui' } else { 'Non' } }
$col= { param($v) if ($v) { 'Yellow' } else { 'Green' } }

Write-Host "  Version PDF      : $script:PdfVersion" -ForegroundColor White
Write-Host "  Pages            : $(if($null -ne $pages -and $pages.ContainsKey('Count')){$pages['Count'].Value}else{'?'})" -ForegroundColor White
Write-Host "  Actions demarr.  : $(& $yn $hasActions)" -ForegroundColor (& $col $hasActions)
Write-Host "  Scripts JS       : $($script:JSSnippets.Count)" -ForegroundColor (& $col ($script:JSSnippets.Count -gt 0))
Write-Host "  Fichiers incorp. : $($embedded.Count)" -ForegroundColor (& $col ($embedded.Count -gt 0))
Write-Host "  Chiffre          : $(& $yn $isEncrypted)" -ForegroundColor (& $col $isEncrypted)
Write-Host "  Champs /Info     : $($meta.Count)" -ForegroundColor White
Write-Host ''
Write-Host "  >> Niveau de risque : " -NoNewline -ForegroundColor White
Write-Host $riskLabel -ForegroundColor $riskColor
Write-Host ''
