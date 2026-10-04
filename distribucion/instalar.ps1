# Instalador de Alma para Windows x64 (por usuario, sin permisos de administrador).
#
# En un comando (descarga la última versión publicada):
#   irm https://raw.githubusercontent.com/Auralix-Studio/alma/main/distribucion/instalar.ps1 | iex
# Una versión concreta: define $env:ALMA_VERSION = "v0.1.0" antes de ejecutarlo.
#
# Sin conexión: coloca este script junto a alma-windows-x64.exe (o alma.exe) y a
# SHA256SUMS.txt, y ejecuta:
#   powershell -ExecutionPolicy Bypass -File .\instalar.ps1
#
# La instalación se aborta si falta SHA256SUMS.txt, si el binario no figura en él
# con su nombre exacto o si el hash SHA-256 no coincide.
# Sin colores: define $env:NO_COLOR.

function Instalar-Alma {
    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue"
    $repositorio = "Auralix-Studio/alma"
    $destino = Join-Path $env:LOCALAPPDATA "Programs\Alma"

    # — Presentación —
    $esc = [char]27
    $color = (-not $env:NO_COLOR) -and $Host.UI.SupportsVirtualTerminal
    function Tinta([string]$texto, [string]$rgb) {
        if ($color) { return "$esc[38;2;${rgb}m$texto$esc[0m" } else { return $texto }
    }
    function Negrita([string]$texto) { if ($color) { "$esc[1m$texto$esc[0m" } else { $texto } }
    $violeta = "155;133;255"; $ambar = "255;181;71"; $verde = "80;200;120"; $rojo = "240;90;90"; $gris = "150;150;160"
    function Paso([string]$texto) { Write-Host ("  " + (Tinta "✓" $verde) + " " + $texto) }
    function Info([string]$texto) { Write-Host ("  " + (Tinta "→" $violeta) + " " + $texto) }

    Write-Host ""
    Write-Host ("     " + (Tinta ")" $violeta))
    Write-Host ("    " + (Tinta ") \" $violeta) + "      " + (Negrita "Alma"))
    Write-Host ("   " + (Tinta "/ ) (" $violeta) + "     " + (Tinta "programación en español" $gris))
    Write-Host ("   " + (Tinta "\(" $violeta) + (Tinta "_" $ambar) + (Tinta ")/" $violeta))
    Write-Host ""

    # La barra se anima solo en una terminal interactiva y para archivos grandes.
    $interactiva = $true
    try { $interactiva = -not [Console]::IsOutputRedirected } catch { }

    function Descargar([string]$url, [string]$archivo, [string]$titulo) {
        $peticion = [Net.HttpWebRequest]::Create($url)
        $peticion.UserAgent = "alma-instalador"
        $respuesta = $peticion.GetResponse()
        try {
            $total = $respuesta.ContentLength
            if (-not $interactiva -or $total -lt 512KB) { $total = -1 }
            $entrada = $respuesta.GetResponseStream()
            $salida = [IO.File]::Create($archivo)
            try {
                $bufer = New-Object byte[] 65536
                $leido = 0
                $ultimo = -1
                while (($n = $entrada.Read($bufer, 0, $bufer.Length)) -gt 0) {
                    $salida.Write($bufer, 0, $n)
                    $leido += $n
                    if ($total -gt 0) {
                        $pct = [int](100 * $leido / $total)
                        if ($pct -ne $ultimo) {
                            $ultimo = $pct
                            $llenos = [int]($pct / 5)
                            $barra = (Tinta ("█" * $llenos) $violeta) + (Tinta ("░" * (20 - $llenos)) $gris)
                            $mb = "{0:N1} / {1:N1} MB" -f ($leido / 1MB), ($total / 1MB)
                            Write-Host -NoNewline ("`r  " + (Tinta "↓" $ambar) + " $titulo  $barra $pct%  $mb   ")
                        }
                    }
                }
            } finally { $salida.Close(); $entrada.Close() }
        } finally { $respuesta.Close() }
        if ($total -gt 0) { Write-Host -NoNewline ("`r" + (" " * 78) + "`r") }
        Paso "Descargado $titulo"
    }

    try {
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
        if ($origen) {
            Info "Instalación sin conexión desde $carpeta"
        } else {
            if (-not [Environment]::Is64BitOperatingSystem) { throw "Alma solo publica binarios para Windows x64." }
            $version = if ($env:ALMA_VERSION) { "download/$($env:ALMA_VERSION)" } else { "latest/download" }
            Info ("Plataforma: Windows x64" + $(if ($env:ALMA_VERSION) { "  ·  versión $($env:ALMA_VERSION)" } else { "  ·  última versión" }))
            $base = "https://github.com/$repositorio/releases/$version"
            $temporal = Join-Path ([IO.Path]::GetTempPath()) ("alma-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $temporal | Out-Null
            $nombre = "alma-windows-x64.exe"
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Descargar "$base/$nombre" (Join-Path $temporal $nombre) $nombre
            Descargar "$base/SHA256SUMS.txt" (Join-Path $temporal "SHA256SUMS.txt") "SHA256SUMS.txt"
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
            Paso ("SHA-256 verificado " + (Tinta $obtenido.Substring(0, 12) $gris))

            # 3. Instalación.
            New-Item -ItemType Directory -Force -Path $destino | Out-Null
            Copy-Item -LiteralPath $origen -Destination (Join-Path $destino "alma.exe") -Force
            Paso "Instalado en $destino\alma.exe"
        } finally {
            if ($temporal) { Remove-Item -LiteralPath $temporal -Recurse -Force -ErrorAction SilentlyContinue }
        }

        # 4. PATH del usuario (persistente) y de esta sesión.
        $rutaUsuario = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($null -eq $rutaUsuario) { $rutaUsuario = "" }
        if (($rutaUsuario -split ';') -notcontains $destino) {
            $nueva = if ($rutaUsuario.TrimEnd(';') -eq "") { $destino } else { $rutaUsuario.TrimEnd(';') + ";" + $destino }
            [Environment]::SetEnvironmentVariable("Path", $nueva, "User")
            Paso "Añadido al PATH del usuario"
        } else {
            Paso "Ya estaba en el PATH del usuario"
        }
        if (($env:Path -split ';') -notcontains $destino) { $env:Path = $env:Path.TrimEnd(';') + ";" + $destino }
    } catch {
        Write-Host ""
        Write-Host ("  " + (Tinta "✗" $rojo) + " " + $_.Exception.Message)
        Write-Host ""
        throw
    }

    $instalada = (& (Join-Path $destino "alma.exe") version) -join ""
    Write-Host ""
    Write-Host ("  " + (Negrita (Tinta "¡Listo!" $ambar)) + " $instalada está instalado.")
    Write-Host ""
    Write-Host ("  Prueba:      " + (Tinta "alma ejecutar hola.alma" $violeta))
    Write-Host ("  Actualizar:  " + (Tinta "alma actualizar" $violeta))
    Write-Host ("  Aprende:     https://github.com/$repositorio")
    Write-Host ("  " + (Tinta "En otras terminales ya abiertas, ábrelas de nuevo para usar 'alma'." $gris))
    Write-Host ""
}

Instalar-Alma
