$f="C:\Users\olivi\OneDrive\Documents\Théorie_Musicale_1.pdf"
$bytes = [System.IO.File]::ReadAllBytes($f)
function Split-ByteArrayByCrLf {
    param(
        [byte[]]$Bytes
    )

    $lines    = @()
    $current  = [System.Collections.Generic.List[byte]]::new()

    $i = 0
    while ($i -lt $Bytes.Length) {
        if ($i + 1 -lt $Bytes.Length -and $Bytes[$i] -eq 13 -and $Bytes[$i+1] -eq 10) {
            $lines += ,@($current.ToArray())
            $current.Clear()
            $i += 2
        } else {
            $current.Add($Bytes[$i])
            $i++
        }
    }

    if ($current.Count -gt 0) {
        $lines += ,@($current.ToArray())
    }

    return $lines
}

function Convert-ByteArrayToString {
    param(
        [byte[]]$Bytes
    )

    return [System.Text.Encoding]::ASCII.GetString($Bytes)
}
function Check-EOF {
    param(
        [String]$line
    )

    return $line -eq "%%EOF"
}
function Read-XRef {
    param(
        [System.Object[]]$lines
    )
    $tag = Convert-ByteArrayToString -Bytes $lines[-3]
    if ($tag -ne "startxref") {
        Write-Output "XRef not found"
        return $null
    }
    else {
        $xrefLines = Convert-ByteArrayToString -Bytes $lines[-2]

    }
    return $xrefLines
}
$arrlines = Split-ByteArrayByCrLf -Bytes $bytes
$ver = Convert-ByteArrayToString -Bytes $arrlines[1]
$eof = Convert-ByteArrayToString -Bytes $arrlines[-1]

if (Check-EOF -line $eof) {
    Write-Output "EOF found"
} else {
    Write-Output "EOF not found"
}
$xref = Read-XRef -lines $arrlines
if ($null -ne $xref) {
    Write-Output "XRef found: $xref"
} else {
    Write-Output "XRef not found"
}

