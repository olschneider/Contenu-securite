<#
.SYNOPSIS
    Vérifie et corrige l'état des services Windows par rapport à une liste définie dans un fichier texte.
.DESCRIPTION
    Ce script lit un fichier texte contenant une liste de services et leur état souhaité (activé/désactivé).
    Il vérifie l'état actuel de chaque service, enregistre les résultats dans un fichier de log,
    puis propose à l'utilisateur d'appliquer les corrections nécessaires.
.NOTES
    Auteur: Olivier SCHNEIDER
    Date: 03/02/2026
#>

# Chemin du fichier contenant la liste des services et leur état souhaité
$inputFile = "services.txt"

# Chemin du fichier de log pour enregistrer les résultats
$logFile = "service_check_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

# Fonction pour vérifier l'état d'un service
function Test-ServiceState {
    param (
        [string]$ServiceName,
        [string]$DesiredState
    )

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if ($service -eq $null) {
        return @{ Message = "Service '$ServiceName' introuvable."; NeedsFix = $false }
    }

    $currentStatus = $service.Status
    $currentStartupType = $service.StartType

    $isCorrect = $false
    $message = ""
    $needsFix = $false

    if ($DesiredState -eq "activé") {
        if ($currentStartupType -eq "Automatic" -or $currentStartupType -eq "DelayedStart") {
            $isCorrect = $true
            $message = "OK: '$ServiceName' est configuré pour être activé ($currentStartupType)."
        } else {
            $message = "ERREUR: '$ServiceName' devrait être activé, mais son type de démarrage est '$currentStartupType'."
            $needsFix = $true
        }
    } elseif ($DesiredState -eq "désactivé") {
        if ($currentStartupType -eq "Disabled") {
            $isCorrect = $true
            $message = "OK: '$ServiceName' est configuré pour être désactivé."
        } else {
            $message = "ERREUR: '$ServiceName' devrait être désactivé, mais son type de démarrage est '$currentStartupType'."
            $needsFix = $true
        }
    }

    return @{ Message = $message; NeedsFix = $needsFix; ServiceName = $ServiceName; DesiredState = $DesiredState }
}

# Fonction pour corriger l'état d'un service
function Fix-ServiceState {
    param (
        [string]$ServiceName,
        [string]$DesiredState
    )

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if ($service -eq $null) {
        return "Service '$ServiceName' introuvable. Impossible de corriger."
    }

    if ($DesiredState -eq "activé") {
        Set-Service -Name $ServiceName -StartupType Automatic
        return "CORRIGÉ: '$ServiceName' est maintenant configuré pour être activé (Automatic)."
    } elseif ($DesiredState -eq "désactivé") {
        Set-Service -Name $ServiceName -StartupType Disabled
        return "CORRIGÉ: '$ServiceName' est maintenant configuré pour être désactivé."
    }
}

# Vérification de l'existence du fichier d'entrée
if (-not (Test-Path -Path $inputFile)) {
    Write-Error "Le fichier '$inputFile' est introuvable."
    exit 1
}

# Lecture du fichier d'entrée
$services = Get-Content -Path $inputFile

# Initialisation du fichier de log
"Date: $(Get-Date)" | Out-File -FilePath $logFile -Encoding utf8
"Vérification des services..." | Out-File -FilePath $logFile -Append -Encoding utf8
"----------------------------------------" | Out-File -FilePath $logFile -Append -Encoding utf8

# Liste des services nécessitant une correction
$servicesToFix = @()

# Vérification de chaque service
foreach ($line in $services) {
    if ($line.Trim() -ne "") {
        $parts = $line -split ","
        $serviceName = $parts[0]
        $desiredState = $parts[1]

        $result = Test-ServiceState -ServiceName $serviceName -DesiredState $desiredState
        $result.Message | Out-File -FilePath $logFile -Append -Encoding utf8

        if ($result.NeedsFix) {
            $servicesToFix += $result
        }
    }
}

"----------------------------------------" | Out-File -FilePath $logFile -Append -Encoding utf8
"Vérification terminée." | Out-File -FilePath $logFile -Append -Encoding utf8

Write-Host "Vérification terminée. Les résultats ont été enregistrés dans '$logFile'."
Write-Host ""

# Affichage des services nécessitant une correction
if ($servicesToFix.Count -gt 0) {
    Write-Host "Les services suivants nécessitent une correction :"
    foreach ($service in $servicesToFix) {
        Write-Host "- $($service.ServiceName) (doit être $($service.DesiredState))"
    }
    Write-Host ""

    # Demande à l'utilisateur s'il souhaite appliquer les corrections
    $response = Read-Host "Souhaitez-vous appliquer les corrections nécessaires ? (O/N)"

    if ($response -eq "O" -or $response -eq "o") {
        Write-Host "Application des corrections..."
        foreach ($service in $servicesToFix) {
            $fixResult = Fix-ServiceState -ServiceName $service.ServiceName -DesiredState $service.DesiredState
            $fixResult | Out-File -FilePath $logFile -Append -Encoding utf8
            Write-Host $fixResult
        }
        Write-Host "Corrections appliquées avec succès."
    } else {
        Write-Host "Aucune correction appliquée."
    }
} else {
    Write-Host "Tous les services sont déjà conformes au fichier d'entrée."
}
