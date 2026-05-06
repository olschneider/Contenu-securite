#Requires -Version 5.1
<#
.SYNOPSIS
    Lit plusieurs fichiers Excel, effectue une jointure sur des clés configurées,
    et génère un fichier HTML avec tableau filtrable et triable.

.DESCRIPTION
    Le script lit un fichier de configuration JSON décrivant les sources Excel
    (fichier, onglet, colonne de clé), effectue la jointure, et produit un rapport
    HTML autonome (self-contained) sans dépendance externe.

.PARAMETER ConfigFile
    Chemin vers le fichier de configuration JSON (défaut : config.json)

.PARAMETER OutputFile
    Surcharge le fichier de sortie défini dans la configuration.

.PARAMETER JoinType
    Surcharge le type de jointure : inner | left | full  (défaut : left)

.EXAMPLE
    .\Excel-Join-To-HTML.ps1
    .\Excel-Join-To-HTML.ps1 -ConfigFile "mon_config.json" -JoinType full
    .\Excel-Join-To-HTML.ps1 -OutputFile "rapport_2026.html"

.NOTES
    Prérequis : Microsoft Excel doit être installé (utilise COM Automation).
    Alternative sans Excel : installer le module ImportExcel via
    Install-Module -Name ImportExcel -Scope CurrentUser
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "config.json",

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "",

    [Parameter(Mandatory = $false)]
    [ValidateSet("inner", "left", "full")]
    [string]$JoinType = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 
# FONCTIONS UTILITAIRES
# 

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "Cyan" }
        "SUCCESS" { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Test-ExcelInstalled {
    try {
        $excel = New-Object -ComObject Excel.Application -ErrorAction Stop
        $excel.Quit()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Test-ImportExcelModule {
    return (Get-Module -ListAvailable -Name ImportExcel) -ne $null
}

# 
# LECTURE EXCEL VIA COM (Microsoft Excel requis)
# 

function Read-ExcelViaComObject {
    param(
        [string]$FilePath,
        [string]$SheetName,
        [string[]]$Columns,       # Noms des colonnes à extraire (vide = toutes)
        [string]$KeyColumn,
        [bool]$HasHeaderRow = $true
    )

    $excel = $null
    $workbook = $null

    try {
        Write-Log "Ouverture COM : $FilePath [$SheetName]"
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $excel.ScreenUpdating = $false

        $workbook = $excel.Workbooks.Open(
            $FilePath,
            $false,   # UpdateLinks
            $true,    # ReadOnly
            5,        # Format
            "",       # Password
            "",       # WriteResPassword
            $true,    # IgnoreReadOnlyRecommended
            2,        # Origin
            "",       # Delimiter
            $false,   # Editable
            $false,   # Notify
            0,        # Converter
            $false    # AddToMru
        )

        $sheet = $null
        foreach ($ws in $workbook.Worksheets) {
            if ($ws.Name -eq $SheetName) { $sheet = $ws; break }
        }
        if ($null -eq $sheet) {
            throw "Onglet '$SheetName' introuvable dans '$FilePath'. Onglets disponibles : $(($workbook.Worksheets | ForEach-Object { $_.Name }) -join ', ')"
        }

        $usedRange = $sheet.UsedRange
        $rowCount  = $usedRange.Rows.Count
        $colCount  = $usedRange.Columns.Count
        $startRow  = $usedRange.Row
        $startCol  = $usedRange.Column

        # Lecture des en-têtes
        $headers = @()
        if ($HasHeaderRow) {
            for ($c = 1; $c -le $colCount; $c++) {
                $val = $sheet.Cells($startRow, $startCol + $c - 1).Text
                $headers += [string]$val
            }
            $dataStartRow = $startRow + 1
        } else {
            for ($c = 1; $c -le $colCount; $c++) { $headers += "Col$c" }
            $dataStartRow = $startRow
        }

        # Déterminer les colonnes à extraire
        $targetCols = if ($Columns -and $Columns.Count -gt 0) { $Columns } else { $headers }

        # Vérification colonne de clé
        if ($KeyColumn -and $headers -notcontains $KeyColumn) {
            throw "Colonne de clé '$KeyColumn' introuvable dans '$FilePath[$SheetName]'. Colonnes : $($headers -join ', ')"
        }

        # Mapping nom → index (1-based relatif à usedRange)
        $headerIndex = @{}
        for ($i = 0; $i -lt $headers.Count; $i++) {
            $headerIndex[$headers[$i]] = $i + 1
        }

        # Lecture des données
        $rows = [System.Collections.Generic.List[hashtable]]::new()
        $dataRowCount = $rowCount - ($dataStartRow - $startRow)

        for ($r = 0; $r -lt $dataRowCount; $r++) {
            $rowIndex = $dataStartRow + $r
            $record = [ordered]@{}
            $isEmpty = $true

            foreach ($col in $targetCols) {
                if ($headerIndex.ContainsKey($col)) {
                    $cell    = $sheet.Cells($rowIndex, $startCol + $headerIndex[$col] - 1)
                    $rawVal  = $cell.Value   # .Value : DateTime pour dates, Double pour nombres, String pour texte
                    $cellVal = if ($null -eq $rawVal -or $rawVal -is [System.DBNull]) {
                        ""
                    } elseif ($rawVal -is [datetime]) {
                        $rawVal.ToString("dd/MM/yyyy")
                    } elseif ($rawVal -is [double] -or $rawVal -is [int] -or $rawVal -is [long]) {
                        [string]$rawVal   # nombre pur, pas de formatage local
                    } else {
                        # Nettoyer les caractères de contrôle et espaces insécables éventuels
                        ([string]$rawVal).Trim() -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\u00A0]', ''
                    }
                    $record[$col] = $cellVal
                    if ($cellVal -ne "") { $isEmpty = $false }
                } else {
                    $record[$col] = ""
                }
            }

            if (-not $isEmpty) { $rows.Add($record) }
        }

        Write-Log "$($rows.Count) lignes lues depuis $FilePath[$SheetName]" "SUCCESS"
        return @{ Headers = $targetCols; Rows = $rows }

    } finally {
        if ($workbook) {
            try { $workbook.Close($false) } catch {}
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook) | Out-Null
        }
        if ($excel) {
            try { $excel.Quit() } catch {}
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

# 
# LECTURE EXCEL VIA ImportExcel (fallback sans Excel installé)
# 

function Read-ExcelViaImportExcel {
    param(
        [string]$FilePath,
        [string]$SheetName,
        [string[]]$Columns,
        [string]$KeyColumn
    )

    Write-Log "Lecture ImportExcel : $FilePath [$SheetName]"
    Import-Module ImportExcel -ErrorAction Stop

    $data = Import-Excel -Path $FilePath -WorksheetName $SheetName -ErrorAction Stop

    if ($data.Count -eq 0) {
        return @{ Headers = @(); Rows = [System.Collections.Generic.List[hashtable]]::new() }
    }

    $allHeaders = $data[0].PSObject.Properties.Name
    $targetCols = if ($Columns -and $Columns.Count -gt 0) { $Columns } else { $allHeaders }

    if ($KeyColumn -and $allHeaders -notcontains $KeyColumn) {
        throw "Colonne de clé '$KeyColumn' introuvable dans '$FilePath[$SheetName]'. Colonnes : $($allHeaders -join ', ')"
    }

    $rows = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($item in $data) {
        $record = [ordered]@{}
        foreach ($col in $targetCols) {
            $record[$col] = [string]($item.$col)
        }
        $rows.Add($record)
    }

    Write-Log "$($rows.Count) lignes lues depuis $FilePath[$SheetName]" "SUCCESS"
    return @{ Headers = $targetCols; Rows = $rows }
}

# 
# DISPATCHER LECTURE EXCEL
# 

function Read-ExcelSource {
    param(
        [hashtable]$SourceConfig,
        [string]$BaseDir,
        [string]$ReaderMode  # "com" | "importexcel"
    )

    $filePath = if ([System.IO.Path]::IsPathRooted($SourceConfig.file)) {
        $SourceConfig.file
    } else {
        Join-Path $BaseDir $SourceConfig.file
    }

    if (-not (Test-Path $filePath)) {
        throw "Fichier Excel introuvable : $filePath"
    }

    $absPath = (Resolve-Path $filePath).Path
    $cols    = if ($SourceConfig.columns) { [string[]]$SourceConfig.columns } else { @() }

    if ($ReaderMode -eq "com") {
        return Read-ExcelViaComObject `
            -FilePath  $absPath `
            -SheetName $SourceConfig.sheet `
            -Columns   $cols `
            -KeyColumn $SourceConfig.keyColumn
    } else {
        return Read-ExcelViaImportExcel `
            -FilePath  $absPath `
            -SheetName $SourceConfig.sheet `
            -Columns   $cols `
            -KeyColumn $SourceConfig.keyColumn
    }
}

# 
# LOGIQUE DE JOINTURE
# 

function Invoke-DataJoin {
    param(
        [array]$Sources,      # tableau de @{Config; Data}
        [string]$JoinType     # inner | left | full
    )

    if ($Sources.Count -eq 0) { return @() }
    if ($Sources.Count -eq 1) {
        return $Sources[0].Data.Rows
    }

    Write-Log "Jointure '$JoinType' sur $($Sources.Count) sources..."

    # Résultat initial = copie de la source gauche (source 0)
    $result = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($row in $Sources[0].Data.Rows) {
        $newRow = [ordered]@{}
        foreach ($k in $row.Keys) { $newRow[$k] = $row[$k] }
        $newRow["__matched__"] = $false
        $result.Add($newRow)
    }

    # Jointure séquentielle avec chaque source suivante
    for ($s = 1; $s -lt $Sources.Count; $s++) {
        $rightSource = $Sources[$s]
        $rightKey    = $rightSource.Config.keyColumn

        # Clé dans le résultat accumulé (gauche) :
        #   - leftKeyColumn si explicitement défini dans la config de cette source
        #   - sinon même nom que rightKey (comportement historique)
        $leftKey = if ($rightSource.Config.ContainsKey("leftKeyColumn") -and $rightSource.Config.leftKeyColumn) {
            $rightSource.Config.leftKeyColumn
        } else {
            $rightKey
        }

        # Vérifier que la colonne gauche existe dans le résultat courant
        if ($result.Count -gt 0 -and -not $result[0].Contains($leftKey)) {
            $available = ($result[0].Keys | Where-Object { $_ -ne "__matched__" }) -join ", "
            throw "leftKeyColumn '$leftKey' introuvable dans le résultat accumulé pour la source '$($rightSource.Config.file)'.`nColonnes disponibles : $available"
        }

        Write-Log "Source $($s+1) '$($rightSource.Config.file)' : jointure sur [$leftKey] = [$rightKey]"

        # Construire un index par clé sur la source droite (clés vides exclues)
        $rightIndex = @{}
        foreach ($rightRow in $rightSource.Data.Rows) {
            $keyVal = [string]$rightRow[$rightKey]
            if ([string]::IsNullOrWhiteSpace($keyVal)) { continue }
            if (-not $rightIndex.ContainsKey($keyVal)) {
                $rightIndex[$keyVal] = [System.Collections.Generic.List[hashtable]]::new()
            }
            $rightIndex[$keyVal].Add($rightRow)
        }

        $newResult = [System.Collections.Generic.List[hashtable]]::new()
        $matchedRightKeys = [System.Collections.Generic.HashSet[string]]::new()

        foreach ($leftRow in $result) {
            $keyVal = [string]$leftRow[$leftKey]
            # Clé gauche vide : pas de jointure possible, conserver la ligne telle quelle (LEFT/FULL)
            if ([string]::IsNullOrWhiteSpace($keyVal)) {
                if ($JoinType -ne "inner") {
                    $merged = [ordered]@{}
                    foreach ($k in $leftRow.Keys) {
                        if ($k -ne "__matched__") { $merged[$k] = $leftRow[$k] }
                    }
                    foreach ($col in $rightSource.Data.Headers) {
                        if (-not $merged.Contains($col)) { $merged[$col] = "" }
                    }
                    $merged["__matched__"] = $false
                    $newResult.Add($merged)
                }
                continue
            }
            $rightMatches = if ($rightIndex.ContainsKey($keyVal)) { $rightIndex[$keyVal] } else { $null }

            if ($rightMatches -and $rightMatches.Count -gt 0) {
                foreach ($rightRow in $rightMatches) {
                    $merged = [ordered]@{}
                    foreach ($k in $leftRow.Keys) {
                        if ($k -ne "__matched__") { $merged[$k] = $leftRow[$k] }
                    }
                    foreach ($k in $rightRow.Keys) {
                        if ($k -ne $rightKey -or -not $merged.Contains($k)) {
                            $merged[$k] = $rightRow[$k]
                        }
                    }
                    $merged["__matched__"] = $true
                    $newResult.Add($merged)
                    [void]$matchedRightKeys.Add($keyVal)
                }
            } else {
                # Pas de correspondance côté droit
                if ($JoinType -ne "inner") {
                    # LEFT ou FULL : conserver la ligne gauche avec colonnes droites vides
                    $merged = [ordered]@{}
                    foreach ($k in $leftRow.Keys) {
                        if ($k -ne "__matched__") { $merged[$k] = $leftRow[$k] }
                    }
                    foreach ($col in $rightSource.Data.Headers) {
                        if (-not $merged.Contains($col)) { $merged[$col] = "" }
                    }
                    $merged["__matched__"] = $false
                    $newResult.Add($merged)
                }
                # INNER : on ignore cette ligne
            }
        }

        # FULL OUTER : ajouter les lignes droites sans correspondance gauche
        if ($JoinType -eq "full") {
            foreach ($rightRow in $rightSource.Data.Rows) {
                $keyVal = $rightRow[$rightKey]
                if (-not $matchedRightKeys.Contains($keyVal)) {
                    $merged = [ordered]@{}
                    # Colonnes gauches vides
                    $leftCols = if ($result.Count -gt 0) { $result[0].Keys } else { @() }
                    foreach ($k in $leftCols) {
                        if ($k -ne "__matched__") { $merged[$k] = "" }
                    }
                    foreach ($k in $rightRow.Keys) { $merged[$k] = $rightRow[$k] }
                    $merged["__matched__"] = $false
                    $newResult.Add($merged)
                }
            }
        }

        $result = $newResult
        Write-Log "Après jointure source $($s+1) : $($result.Count) lignes"
    }

    # Nettoyer la clé interne "__matched__"
    $cleanResult = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($row in $result) {
        $clean = [ordered]@{}
        foreach ($k in $row.Keys) {
            if ($k -ne "__matched__") { $clean[$k] = $row[$k] }
        }
        $cleanResult.Add($clean)
    }

    Write-Log "Jointure terminée : $($cleanResult.Count) lignes résultantes" "SUCCESS"
    return $cleanResult
}

# 
# APPLICATION DES ALIAS DE COLONNES
# 

function Apply-ColumnAliases {
    param(
        [System.Collections.Generic.List[hashtable]]$Rows,
        [hashtable]$Aliases   # @{ "OldName" = "NewName" }
    )

    if (-not $Aliases -or $Aliases.Count -eq 0) { return $Rows }

    $renamed = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($row in $Rows) {
        $newRow = [ordered]@{}
        foreach ($k in $row.Keys) {
            $displayName = if ($Aliases.ContainsKey($k)) { $Aliases[$k] } else { $k }
            $newRow[$displayName] = $row[$k]
        }
        $renamed.Add($newRow)
    }
    return $renamed
}

# 
# SÉRIALISATION JSON MINIMALISTE (sans dépendance externe)
# 

function ConvertTo-SafeJson {
    param([object]$InputObject)

    # Utiliser ConvertTo-Json natif PS puis compresser
    $json = $InputObject | ConvertTo-Json -Depth 10 -Compress
    return $json
}

# 
# GÉNÉRATION DU FICHIER HTML
# 

function New-HtmlReport {
    param(
        [string]$Title,
        [string]$Subtitle,
        [array]$Rows,
        [string[]]$ColumnOrder,   # ordre optionnel des colonnes
        [string[]]$HiddenColumns, # colonnes à masquer
        [string]$OutputPath,
        [hashtable]$Config
    )

    if ($Rows.Count -eq 0) {
        Write-Log "Aucune ligne de données à exporter." "WARN"
        $columns = @()
    } else {
        $allCols = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $Rows[0].Keys) { $allCols.Add($k) }

        if ($ColumnOrder -and $ColumnOrder.Count -gt 0) {
            $columns = $ColumnOrder | Where-Object { $allCols -contains $_ }
            foreach ($c in $allCols) { if ($columns -notcontains $c) { $columns += $c } }
        } else {
            $columns = $allCols
        }

        if ($HiddenColumns -and $HiddenColumns.Count -gt 0) {
            $columns = $columns | Where-Object { $HiddenColumns -notcontains $_ }
        }
    }

    # Sérialiser les données pour injection JS
    $rowsForJs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($row in $Rows) {
        $jsRow = [ordered]@{}
        foreach ($col in $columns) {
            $jsRow[$col] = if ($row.Contains($col)) { $row[$col] } else { "" }
        }
        $rowsForJs.Add($jsRow)
    }

    $jsonData    = ConvertTo-SafeJson -InputObject @($rowsForJs)
    $jsonColumns = ConvertTo-SafeJson -InputObject @($columns)

    $generatedAt = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
    $sourceInfo  = ($Config.sources | ForEach-Object { "$($_.file) [$($_.sheet)]" }) -join ", "
    $joinTypeLabel = $Config.joinType.ToUpper()
    $totalRows   = $Rows.Count

    $html = @"
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$Title</title>
<style>
  /*  Reset & Base  */
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --bg:         #0d1117;
    --surface:    #161b22;
    --surface2:   #1c2330;
    --border:     #30363d;
    --accent:     #58a6ff;
    --accent2:    #3fb950;
    --accent3:    #f78166;
    --text:       #e6edf3;
    --text-muted: #8b949e;
    --highlight:  rgba(88,166,255,.12);
    --hover-row:  rgba(88,166,255,.06);
    --sort-asc:   #3fb950;
    --sort-desc:  #f78166;
    --shadow:     0 4px 24px rgba(0,0,0,.5);
    --radius:     6px;
    --font-mono:  'JetBrains Mono', 'Cascadia Code', 'Fira Code', monospace;
    --font-sans:  'Segoe UI', system-ui, sans-serif;
  }

  html, body {
    background: var(--bg);
    color: var(--text);
    font-family: var(--font-sans);
    font-size: 14px;
    line-height: 1.5;
    min-height: 100vh;
  }

  /*  Layout  */
  .app { display: flex; flex-direction: column; min-height: 100vh; }

  header {
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    padding: 20px 28px 16px;
    position: sticky; top: 0; z-index: 100;
    box-shadow: var(--shadow);
  }

  .header-top {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 16px;
    flex-wrap: wrap;
  }

  .header-title h1 {
    font-size: 20px;
    font-weight: 600;
    color: var(--text);
    letter-spacing: -0.3px;
  }

  .header-title p {
    font-size: 12px;
    color: var(--text-muted);
    margin-top: 2px;
    font-family: var(--font-mono);
  }

  .header-badges {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
    align-items: center;
    margin-top: 4px;
  }

  .badge {
    display: inline-flex; align-items: center; gap: 5px;
    padding: 3px 10px;
    border-radius: 20px;
    font-size: 11px;
    font-family: var(--font-mono);
    font-weight: 500;
    border: 1px solid;
  }
  .badge-blue   { color: var(--accent);  border-color: rgba(88,166,255,.3);  background: rgba(88,166,255,.08); }
  .badge-green  { color: var(--accent2); border-color: rgba(63,185,80,.3);   background: rgba(63,185,80,.08); }
  .badge-red    { color: var(--accent3); border-color: rgba(247,129,102,.3); background: rgba(247,129,102,.08); }
  .badge-gray   { color: var(--text-muted); border-color: var(--border); background: var(--surface2); }

  /*  Toolbar  */
  .toolbar {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-top: 14px;
    flex-wrap: wrap;
  }

  .search-wrap {
    position: relative;
    flex: 1;
    min-width: 200px;
    max-width: 400px;
  }

  #globalSearch {
    width: 100%;
    padding: 7px 12px 7px 34px;
    background: var(--surface2);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    color: var(--text);
    font-size: 13px;
    font-family: var(--font-sans);
    transition: border-color .2s;
    outline: none;
  }
  #globalSearch:focus { border-color: var(--accent); }
  #globalSearch::placeholder { color: var(--text-muted); }

  .toolbar-btn {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 7px 14px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--surface2);
    color: var(--text-muted);
    font-size: 12px;
    font-family: var(--font-sans);
    cursor: pointer;
    transition: all .15s;
    white-space: nowrap;
  }
  .toolbar-btn:hover { border-color: var(--accent); color: var(--accent); background: var(--highlight); }
  .toolbar-btn.active { border-color: var(--accent); color: var(--accent); background: var(--highlight); }

  .counter {
    margin-left: auto;
    font-family: var(--font-mono);
    font-size: 12px;
    color: var(--text-muted);
    white-space: nowrap;
  }
  .counter span { color: var(--accent); font-weight: 600; }

  /*  Column Filters  */
  .filter-row-container {
    display: none;
    padding: 8px 0 2px;
    border-top: 1px solid var(--border);
    margin-top: 10px;
  }
  .filter-row-container.visible { display: block; }

  .filter-scroll { overflow-x: auto; }

  .filter-row {
    display: flex;
    gap: 6px;
    min-width: max-content;
    padding-bottom: 4px;
  }

  .filter-cell {
    display: flex;
    flex-direction: column;
    gap: 3px;
    flex-shrink: 0;
  }
  .filter-cell label {
    font-size: 10px;
    color: var(--text-muted);
    font-family: var(--font-mono);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .filter-cell input {
    padding: 4px 8px;
    background: var(--surface2);
    border: 1px solid var(--border);
    border-radius: 4px;
    color: var(--text);
    font-size: 12px;
    outline: none;
    transition: border-color .15s;
  }
  .filter-cell input:focus { border-color: var(--accent); }
  .filter-cell input::placeholder { color: var(--text-muted); opacity: .6; }

  /*  Table Container  */
  main {
    flex: 1;
    padding: 16px 28px 32px;
    overflow-x: auto;
  }

  .table-wrap {
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow: hidden;
    box-shadow: var(--shadow);
  }

  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
  }

  /*  Table Head  */
  thead { background: var(--surface); }

  th {
    padding: 10px 14px;
    text-align: left;
    font-weight: 600;
    font-size: 12px;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: .5px;
    border-bottom: 1px solid var(--border);
    white-space: nowrap;
    cursor: pointer;
    user-select: none;
    position: relative;
    transition: color .15s, background .15s;
  }
  th:hover { color: var(--text); background: var(--surface2); }
  th.sort-asc  { color: var(--sort-asc); }
  th.sort-desc { color: var(--sort-desc); }

  .sort-icon {
    display: inline-flex;
    flex-direction: column;
    margin-left: 5px;
    vertical-align: middle;
    gap: 1px;
    opacity: .35;
    transition: opacity .15s;
  }
  th:hover .sort-icon,
  th.sort-asc .sort-icon,
  th.sort-desc .sort-icon { opacity: 1; }

  th.sort-asc  .sort-icon .arrow-up   { color: var(--sort-asc);  }
  th.sort-desc .sort-icon .arrow-down { color: var(--sort-desc); }

  /*  Table Body  */
  tbody tr {
    border-bottom: 1px solid var(--border);
    transition: background .1s;
  }
  tbody tr:last-child { border-bottom: none; }
  tbody tr:hover { background: var(--hover-row); }
  tbody tr:nth-child(even) { background: rgba(255,255,255,.015); }
  tbody tr:nth-child(even):hover { background: var(--hover-row); }

  td {
    padding: 9px 14px;
    color: var(--text);
    max-width: 280px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  td:first-child { font-family: var(--font-mono); color: var(--accent); font-size: 12px; }

  .cell-empty { color: var(--text-muted); font-style: italic; font-size: 11px; }

  mark {
    background: rgba(255,214,0,.25);
    color: #ffd600;
    border-radius: 2px;
    padding: 0 1px;
  }

  /*  Empty State  */
  .empty-state {
    display: none;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 64px 32px;
    color: var(--text-muted);
    gap: 12px;
  }
  .empty-state.visible { display: flex; }
  .empty-state p { font-size: 15px; }
  .empty-state small { font-size: 12px; font-family: var(--font-mono); }

  /*  Footer  */
  footer {
    text-align: center;
    padding: 12px 28px;
    font-size: 11px;
    color: var(--text-muted);
    border-top: 1px solid var(--border);
    font-family: var(--font-mono);
  }

  /*  Scrollbar  */
  ::-webkit-scrollbar { width: 8px; height: 8px; }
  ::-webkit-scrollbar-track { background: var(--surface); }
  ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 4px; }
  ::-webkit-scrollbar-thumb:hover { background: #444c56; }
</style>
</head>
<body>
<div class="app">

<!--  HEADER  -->
<header>
  <div class="header-top">
    <div class="header-title">
      <h1>$Title</h1>
      <p>$Subtitle</p>
    </div>
    <div>
      <div class="header-badges">
        <span class="badge badge-green" title="Sources de données">
          $($Config.sources.Count) source(s)
        </span>
        <span class="badge badge-blue" title="Type de jointure">JOIN $joinTypeLabel</span>
        <span class="badge badge-gray" id="totalBadge">$totalRows lignes</span>
      </div>
    </div>
  </div>

  <!-- Toolbar -->
  <div class="toolbar">
    <div class="search-wrap">
      <input type="text" id="globalSearch" placeholder="Rechercher dans toutes les colonnes..." autocomplete="off">
    </div>

    <button class="toolbar-btn" id="btnFilters" onclick="toggleFilters()">
      Filtres colonnes
    </button>

    <button class="toolbar-btn" onclick="clearAllFilters()">
      Réinitialiser
    </button>

    <button class="toolbar-btn" onclick="exportCsv()">
      Export CSV
    </button>

    <div class="counter">
      Affichage : <span id="visibleCount">$totalRows</span> / <span id="totalCount">$totalRows</span>
    </div>
  </div>

  <!-- Filtres par colonne -->
  <div class="filter-row-container" id="filterRowContainer">
    <div class="filter-scroll">
      <div class="filter-row" id="filterRow"></div>
    </div>
  </div>
</header>

<!--  MAIN  -->
<main>
  <div class="table-wrap">
    <table id="dataTable">
      <thead><tr id="headerRow"></tr></thead>
      <tbody id="tableBody"></tbody>
    </table>
    <div class="empty-state" id="emptyState">
      <p>Aucun résultat trouvé</p>
      <small id="emptyHint">Essayez de modifier vos critères de recherche</small>
    </div>
  </div>
</main>

<!--  FOOTER  -->
<footer>
  Généré le $generatedAt · Sources : $sourceInfo · PowerShell Excel Join Reporter
</footer>

</div><!-- /.app -->

<script>
//  DATA 
const RAW_DATA    = $jsonData;
const COLUMNS     = $jsonColumns;
const TOTAL_ROWS  = RAW_DATA.length;

//  STATE 
let globalQuery   = "";
let colFilters    = {};
let sortCol       = null;
let sortDir       = "asc"; // "asc" | "desc"
let filtersVisible = false;

//  INIT 
function init() {
  buildHeader();
  buildFilterInputs();
  render();

  document.getElementById("globalSearch").addEventListener("input", e => {
    globalQuery = e.target.value.trim().toLowerCase();
    render();
  });
}

//  HEADER 
function buildHeader() {
  const tr = document.getElementById("headerRow");
  COLUMNS.forEach((col, i) => {
    const th = document.createElement("th");
    th.dataset.col = col;
    th.innerHTML = escapeHtml(col) + '<span class="sort-icon">↕</span>';
    th.addEventListener("click", () => handleSort(col, th));
    tr.appendChild(th);
  });
}

//  FILTER INPUTS 
function buildFilterInputs() {
  const fr = document.getElementById("filterRow");
  const colWidths = computeColWidths();

  COLUMNS.forEach(col => {
    const cell = document.createElement("div");
    cell.className = "filter-cell";
    cell.style.width = (colWidths[col] || 120) + "px";

    const label = document.createElement("label");
    label.textContent = col;
    label.title = col;

    const input = document.createElement("input");
    input.type = "text";
    input.placeholder = "Filtrer...";
    input.dataset.col = col;
    input.addEventListener("input", e => {
      colFilters[col] = e.target.value.trim().toLowerCase();
      render();
    });

    cell.appendChild(label);
    cell.appendChild(input);
    fr.appendChild(cell);
  });
}

function computeColWidths() {
  // Largeur basée sur le nom de colonne + data sample
  const widths = {};
  COLUMNS.forEach(col => {
    let max = col.length * 9 + 24;
    RAW_DATA.slice(0, 50).forEach(row => {
      const len = String(row[col] || "").length * 8;
      if (len > max) max = len;
    });
    widths[col] = Math.min(Math.max(max, 100), 260);
  });
  return widths;
}

//  SORT 
function handleSort(col, th) {
  const ths = document.querySelectorAll("th");
  ths.forEach(h => h.classList.remove("sort-asc", "sort-desc"));

  if (sortCol === col) {
    sortDir = sortDir === "asc" ? "desc" : "asc";
  } else {
    sortCol = col;
    sortDir = "asc";
  }
  th.classList.add(sortDir === "asc" ? "sort-asc" : "sort-desc");
  render();
}

//  FILTER 
function getFilteredData() {
  return RAW_DATA.filter(row => {
    // Filtre global
    if (globalQuery) {
      const haystack = COLUMNS.map(c => String(row[c] || "").toLowerCase()).join(" ");
      if (!haystack.includes(globalQuery)) return false;
    }
    // Filtres par colonne
    for (const [col, val] of Object.entries(colFilters)) {
      if (!val) continue;
      if (!String(row[col] || "").toLowerCase().includes(val)) return false;
    }
    return true;
  });
}

function getSortedData(data) {
  if (!sortCol) return data;
  return [...data].sort((a, b) => {
    const va = String(a[sortCol] || "");
    const vb = String(b[sortCol] || "");
    // Tri numérique si possible
    const na = parseFloat(va.replace(/[, ]/g, ""));
    const nb = parseFloat(vb.replace(/[, ]/g, ""));
    let cmp;
    if (!isNaN(na) && !isNaN(nb)) {
      cmp = na - nb;
    } else {
      cmp = va.localeCompare(vb, "fr", { sensitivity: "base" });
    }
    return sortDir === "asc" ? cmp : -cmp;
  });
}

//  HIGHLIGHT 
function highlightText(text, query) {
  if (!query) return escapeHtml(text);
  const escaped = escapeHtml(text);
  const escapedQ = escapeHtml(query).replace(/[-[\]{}()*+?.,\\^`$|#\s]/g, "\\`$&`");
  return escaped.replace(new RegExp("(" + escapedQ + ")", "gi"), "<mark>`$1`</mark>");
}

//  RENDER 
function render() {
  const filtered = getFilteredData();
  const sorted   = getSortedData(filtered);
  const tbody    = document.getElementById("tableBody");
  const empty    = document.getElementById("emptyState");
  const tableWrap = document.querySelector(".table-wrap");

  tbody.innerHTML = "";

  document.getElementById("visibleCount").textContent = sorted.length;
  document.getElementById("totalCount").textContent   = TOTAL_ROWS;

  if (sorted.length === 0) {
    empty.classList.add("visible");
    return;
  }
  empty.classList.remove("visible");

  const frag = document.createDocumentFragment();
  sorted.forEach(row => {
    const tr = document.createElement("tr");
    COLUMNS.forEach(col => {
      const td = document.createElement("td");
      const val = String(row[col] || "");
      if (val === "" || val === "null" || val === "undefined") {
        td.innerHTML = '<span class="cell-empty">—</span>';
      } else {
        td.innerHTML = highlightText(val, globalQuery);
        td.title = val;
      }
      tr.appendChild(td);
    });
    frag.appendChild(tr);
  });
  tbody.appendChild(frag);
}

//  TOGGLE FILTERS 
function toggleFilters() {
  filtersVisible = !filtersVisible;
  const container = document.getElementById("filterRowContainer");
  const btn       = document.getElementById("btnFilters");
  container.classList.toggle("visible", filtersVisible);
  btn.classList.toggle("active", filtersVisible);
}

//  CLEAR 
function clearAllFilters() {
  globalQuery = "";
  colFilters  = {};
  sortCol     = null;
  sortDir     = "asc";
  document.getElementById("globalSearch").value = "";
  document.querySelectorAll(".filter-cell input").forEach(i => i.value = "");
  document.querySelectorAll("th").forEach(h => h.classList.remove("sort-asc", "sort-desc"));
  render();
}

//  EXPORT CSV 
function exportCsv() {
  const filtered = getSortedData(getFilteredData());
  const BOM = "\uFEFF"; // UTF-8 BOM pour Excel
  const header = COLUMNS.map(csvEscape).join(";");
  const rows   = filtered.map(row =>
    COLUMNS.map(col => csvEscape(String(row[col] || ""))).join(";")
  );
  const csv = BOM + [header, ...rows].join("\r\n");

  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement("a");
  a.href     = url;
  a.download = "export_" + new Date().toISOString().slice(0,10) + ".csv";
  a.click();
  URL.revokeObjectURL(url);
}

function csvEscape(v) {
  if (v.includes(";") || v.includes('"') || v.includes("\n")) {
    return '"' + v.replace(/"/g, '""') + '"';
  }
  return v;
}

//  UTILS 
function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

//  BOOT 
document.addEventListener("DOMContentLoaded", init);
</script>
</body>
</html>
"@

    [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.Encoding]::new('UTF-8', $false))
    Write-Log "Fichier HTML généré : $OutputPath" "SUCCESS"
}

# 
# POINT D'ENTRÉE PRINCIPAL
# 

function Main {
    Write-Log "=== Excel Join to HTML Reporter ===" "INFO"
    Write-Log "Config : $ConfigFile"

    #  Lecture configuration 
    $configPath = if ([System.IO.Path]::IsPathRooted($ConfigFile)) {
        $ConfigFile
    } else {
        Join-Path (Get-Location) $ConfigFile
    }

    if (-not (Test-Path $configPath)) {
        throw "Fichier de configuration introuvable : $configPath"
    }

    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $baseDir = Split-Path $configPath -Parent

    # Surcharges CLI
    if ($JoinType)    { $config.joinType    = $JoinType }
    if ($OutputFile)  { $config.outputFile  = $OutputFile }

    # Valeurs par défaut
    if (-not $config.joinType)    { Add-Member -InputObject $config -NotePropertyName joinType    -NotePropertyValue "left" -Force }
    if (-not $config.title)       { Add-Member -InputObject $config -NotePropertyName title       -NotePropertyValue "Rapport de données" -Force }
    if (-not $config.outputFile)  { Add-Member -InputObject $config -NotePropertyName outputFile  -NotePropertyValue "rapport.html" -Force }
    if (-not $config.subtitle)    { Add-Member -InputObject $config -NotePropertyName subtitle    -NotePropertyValue "" -Force }

    $outputPath = if ([System.IO.Path]::IsPathRooted($config.outputFile)) {
        $config.outputFile
    } else {
        Join-Path $baseDir $config.outputFile
    }

    Write-Log "Type de jointure : $($config.joinType.ToUpper())"
    Write-Log "Sortie : $outputPath"

    #  Détection du lecteur Excel 
    $readerMode = $null
    if (Test-ExcelInstalled) {
        $readerMode = "com"
        Write-Log "Lecteur : COM (Microsoft Excel)" "SUCCESS"
    } elseif (Test-ImportExcelModule) {
        $readerMode = "importexcel"
        Write-Log "Lecteur : Module ImportExcel" "SUCCESS"
    } else {
        throw @"
Aucun lecteur Excel disponible.
Options :
  1. Installer Microsoft Excel
  2. Installer le module ImportExcel : Install-Module -Name ImportExcel -Scope CurrentUser
"@
    }

    #  Lecture de chaque source Excel 
    $sources = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($srcConfig in $config.sources) {
        $srcHashtable = @{}
        $srcConfig.PSObject.Properties | ForEach-Object { $srcHashtable[$_.Name] = $_.Value }

        $data = Read-ExcelSource -SourceConfig $srcHashtable -BaseDir $baseDir -ReaderMode $readerMode
        $sources.Add(@{ Config = $srcHashtable; Data = $data })
    }

    #  Jointure 
    $joined = Invoke-DataJoin -Sources $sources -JoinType $config.joinType

    #  Alias de colonnes 
    $aliases = @{}
    if ($config.PSObject.Properties["columnAliases"] -and $config.columnAliases) {
        $config.columnAliases.PSObject.Properties | ForEach-Object {
            $aliases[$_.Name] = $_.Value
        }
    }

    if ($aliases.Count -gt 0) {
        Write-Log "Application de $($aliases.Count) alias de colonnes..."
        $joined = Apply-ColumnAliases -Rows $joined -Aliases $aliases
    }

    #  Ordre des colonnes 
    $colOrder    = if ($config.PSObject.Properties["columnOrder"]    -and $config.columnOrder)    { [string[]]$config.columnOrder    } else { @() }
    $hiddenCols  = if ($config.PSObject.Properties["hiddenColumns"]  -and $config.hiddenColumns)  { [string[]]$config.hiddenColumns  } else { @() }

    #  Génération HTML 
    $configHt = @{
        sources  = @($config.sources | ForEach-Object {
            @{ file = $_.file; sheet = $_.sheet }
        })
        joinType = $config.joinType
    }

    New-HtmlReport `
        -Title         $config.title `
        -Subtitle      $config.subtitle `
        -Rows          $joined `
        -ColumnOrder   $colOrder `
        -HiddenColumns $hiddenCols `
        -OutputPath    $outputPath `
        -Config        $configHt

    Write-Log "Terminé ! Ouvrir : $outputPath" "SUCCESS"
    Write-Log "Total lignes exportées : $($joined.Count)"
}

# 
# EXÉCUTION
# 

try {
    Main
} catch {
    Write-Log "ERREUR : $_" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 1
}
