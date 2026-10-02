# Instalador de Alma para Windows (por usuario, sin admin).
# Uso: colocá este script junto al binario descargado y ejecutá:
#   powershell -ExecutionPolicy Bypass -File .\instalar.ps1
$ErrorActionPreference = "Stop"

$destino = Join-Path $env:LOCALAPPDATA "Programs\Alma"

# Busca el binario junto a este script.
$origen = $null
foreach ($n in @("alma.exe", "alma-windows-x64.exe")) {
    $candidato = Join-Path $PSScriptRoot $n
    if (Test-Path $candidato) { $origen = $candidato; break }
}
if (-not $origen) {
    Write-Error "No encontré 'alma.exe' ni 'alma-windows-x64.exe' junto a este script."
    exit 1
}

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
