# Instalador de Alma para Windows (por usuario, sin admin).
# Uso: colocá este script junto al binario descargado y ejecutá:
#   powershell -ExecutionPolicy Bypass -File .\instalar.ps1
$ErrorActionPreference = "Stop"

$destino = Join-Path $env:LOCALAPPDATA "Programs\Alma"

# Busca el binario junto a este script.
$origen = $null
$candidatoName = $null
foreach ($n in @("alma.exe", "alma-windows-x64.exe")) {
    $candidato = Join-Path $PSScriptRoot $n
    if (Test-Path $candidato) { $origen = $candidato; $candidatoName = $n; break }
}
if (-not $origen) {
    Write-Error "No encontré 'alma.exe' ni 'alma-windows-x64.exe' junto a este script."
    exit 1
}

# La instalación se aborta si falta SHA256SUMS.txt, si el binario no figura en
# él (coincidencia exacta de nombre) o si el hash no coincide.
$shaFile = Join-Path $PSScriptRoot "SHA256SUMS.txt"
if (-not (Test-Path -LiteralPath $shaFile)) {
    Write-Error "Falta SHA256SUMS.txt junto al binario; no se puede verificar $candidatoName. Abortando."
    exit 1
}
$expectedHash = $null
foreach ($linea in Get-Content -LiteralPath $shaFile) {
    $partes = $linea.Trim() -split '\s+', 2
    if ($partes.Count -eq 2 -and $partes[1].TrimStart('*') -ceq $candidatoName -and $partes[0] -match '^[0-9a-fA-F]{64}$') {
        $expectedHash = $partes[0].ToLower()
        break
    }
}
if (-not $expectedHash) {
    Write-Error "$candidatoName no figura en SHA256SUMS.txt. Abortando."
    exit 1
}
$actualHash = (Get-FileHash -LiteralPath $origen -Algorithm SHA256).Hash.ToLower()
if ($actualHash -ne $expectedHash) {
    Write-Error "El hash SHA256 de $candidatoName no coincide. Abortando instalación."
    exit 1
}
Write-Host "Hash SHA256 verificado: $candidatoName"

New-Item -ItemType Directory -Force -Path $destino | Out-Null
Copy-Item $origen (Join-Path $destino "alma.exe") -Force

# Agrega la carpeta al PATH del usuario si aún no está.
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($null -eq $userPath) { $userPath = "" }
if (($userPath -split ';') -notcontains $destino) {
    $nuevo = if ($userPath.TrimEnd(';') -eq "") { $destino } else { $userPath.TrimEnd(';') + ";" + $destino }
    [Environment]::SetEnvironmentVariable("Path", $nuevo, "User")
    Write-Host "Se agregó '$destino' al PATH del usuario."
}

Write-Host ""
Write-Host "Alma instalado en: $destino\alma.exe"
Write-Host "Abrí una terminal NUEVA y probá:  alma version"
