# Desinstalador de Alma para Windows.
# Uso:  powershell -ExecutionPolicy Bypass -File .\desinstalar.ps1
$ErrorActionPreference = "Stop"

$destino = Join-Path $env:LOCALAPPDATA "Programs\Alma"

if (Test-Path $destino) {
    Remove-Item -Recurse -Force $destino
    Write-Host "Se eliminó $destino"
} else {
    Write-Host "No estaba instalado en $destino (nada que borrar allí)."
}

# Quita la carpeta del PATH del usuario.
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($null -ne $userPath) {
    $nuevo = (($userPath -split ';') | Where-Object { $_ -and $_ -ne $destino }) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $nuevo, "User")
}

Write-Host "Alma desinstalado. Abrí una terminal nueva para refrescar el PATH."
