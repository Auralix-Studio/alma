# Instalador de Alma para Windows x64 (por usuario, sin permisos de administrador).
#
# En un comando (descarga la última versión publicada):
#   irm https://github.com/Auralix-Studio/alma/releases/latest/download/instalar.ps1 | iex
# Una versión concreta: define $env:ALMA_VERSION = "v0.1.0" antes de ejecutarlo.
#
# Sin conexión: coloca este script junto a alma-windows-x64.exe (o alma.exe) y a
# SHA256SUMS.txt, y ejecuta:
#   powershell -ExecutionPolicy Bypass -File .\instalar.ps1
#
# La instalación se aborta si falta SHA256SUMS.txt, si el binario no figura en él
# con su nombre exacto o si el hash SHA-256 no coincide.

function Instalar-Alma {
    $ErrorActionPreference = "Stop"
    $repositorio = "Auralix-Studio/alma"
    $destino = Join-Path $env:LOCALAPPDATA "Programs\Alma"

    # 1. Origen: binario local junto al script o descarga de GitHub Releases.
    $carpeta = $PSScriptRoot
    $origen = $null
    $nombre = $null
    if ($carpeta) {
        foreach ($n in @("alma-windows-x64.exe", "alma.exe")) {
            $candidato = Join-Path $carpeta $n
            if (Test-Path -LiteralPath $candidato) { $origen = $candidato; $nombre = $n; break }
        }
    }
    $temporal = $null
    if (-not $origen) {
        if (-not [Environment]::Is64BitOperatingSystem) { throw "Alma solo publica binarios para Windows x64." }
        $version = if ($env:ALMA_VERSION) { "download/$($env:ALMA_VERSION)" } else { "latest/download" }
        $base = "https://github.com/$repositorio/releases/$version"
        $temporal = Join-Path ([IO.Path]::GetTempPath()) ("alma-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $temporal | Out-Null
        $nombre = "alma-windows-x64.exe"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Host "Descargando $base/$nombre"
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$nombre" -OutFile (Join-Path $temporal $nombre)
        Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS.txt" -OutFile (Join-Path $temporal "SHA256SUMS.txt")
        $carpeta = $temporal
        $origen = Join-Path $temporal $nombre
    }

    try {
        # 2. Verificación SHA-256 obligatoria.
        $sumas = Join-Path $carpeta "SHA256SUMS.txt"
        if (-not (Test-Path -LiteralPath $sumas)) { throw "Falta SHA256SUMS.txt junto al binario; no se puede verificar $nombre." }
        $esperado = $null
        foreach ($linea in Get-Content -LiteralPath $sumas) {
            $partes = $linea.Trim() -split '\s+', 2
            if ($partes.Count -eq 2 -and $partes[1].TrimStart('*') -ceq $nombre -and $partes[0] -match '^[0-9a-fA-F]{64}$') {
                $esperado = $partes[0].ToLower()
                break
            }
        }
        if (-not $esperado) { throw "$nombre no figura en SHA256SUMS.txt." }
        $obtenido = (Get-FileHash -LiteralPath $origen -Algorithm SHA256).Hash.ToLower()
        if ($obtenido -ne $esperado) { throw "El hash SHA-256 de $nombre no coincide: no se instala." }
        Write-Host "Hash SHA-256 verificado: $nombre"

        # 3. Instalación.
        New-Item -ItemType Directory -Force -Path $destino | Out-Null
        Copy-Item -LiteralPath $origen -Destination (Join-Path $destino "alma.exe") -Force
    } finally {
        if ($temporal) { Remove-Item -LiteralPath $temporal -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # 4. PATH del usuario (persistente) y de esta sesión.
    $rutaUsuario = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($null -eq $rutaUsuario) { $rutaUsuario = "" }
    if (($rutaUsuario -split ';') -notcontains $destino) {
        $nueva = if ($rutaUsuario.TrimEnd(';') -eq "") { $destino } else { $rutaUsuario.TrimEnd(';') + ";" + $destino }
        [Environment]::SetEnvironmentVariable("Path", $nueva, "User")
        Write-Host "Se agregó '$destino' al PATH del usuario."
    }
    if (($env:Path -split ';') -notcontains $destino) { $env:Path = $env:Path.TrimEnd(';') + ";" + $destino }

    Write-Host ""
    Write-Host "Alma instalado en: $destino\alma.exe"
    & (Join-Path $destino "alma.exe") version
    Write-Host "Prueba:  alma ejecutar hola.alma   (en otras terminales, ábrelas de nuevo)"
}

Instalar-Alma
