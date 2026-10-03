param(
    [string]$Alma = (Join-Path $PSScriptRoot 'zig-out/bin/alma.exe'),
    [string]$Seccion = 'todo'
)
$ErrorActionPreference = 'Stop'
$Alma = (Resolve-Path -LiteralPath $Alma).Path
$casos = Join-Path $PSScriptRoot '.zig-cache/pruebas-limites'
[void][IO.Directory]::CreateDirectory($casos)
$script:comprobaciones = 0

function Guardar([string]$Nombre, [string]$Fuente) {
    $ruta = Join-Path $casos $Nombre
    [IO.File]::WriteAllText($ruta, $Fuente, [Text.UTF8Encoding]::new($false))
    return $ruta
}
function Comprobar([bool]$Condicion, [string]$Mensaje) {
    if (-not $Condicion) { throw $Mensaje }
    $script:comprobaciones++
}
function Ejecutar([string]$Binario, [string[]]$Argumentos) {
    $inicio = [Diagnostics.ProcessStartInfo]::new($Binario)
    $inicio.UseShellExecute = $false
    $inicio.CreateNoWindow = $true
    $inicio.RedirectStandardOutput = $true
    $inicio.RedirectStandardError = $true
    $inicio.StandardOutputEncoding = [Text.Encoding]::UTF8
    $inicio.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($arg in $Argumentos) { [void]$inicio.ArgumentList.Add($arg) }
    $proceso = [Diagnostics.Process]::Start($inicio)
    try {
        $salida = $proceso.StandardOutput.ReadToEndAsync()
        $errorTexto = $proceso.StandardError.ReadToEndAsync()
        if (-not $proceso.WaitForExit(30000)) {
            $proceso.Kill($true)
            $proceso.WaitForExit()
            throw "Timeout: $Binario $Argumentos"
        }
        return @{ Codigo = $proceso.ExitCode; Salida = $salida.GetAwaiter().GetResult(); Error = $errorTexto.GetAwaiter().GetResult() }
    } finally { $proceso.Dispose() }
}

if ($Seccion -in @('todo', 'parser')) {
    $archivo = Guardar 'parentesis.alma' (('(' * 200000) + '1' + (')' * 200000) + "`n")
    foreach ($comando in @('analizar', 'ejecutar', 'compilar', 'ast')) {
        $r = Ejecutar $Alma @($comando, $archivo)
        Comprobar ($r.Codigo -eq 1 -and $r.Error.Contains('parentesis.alma:1:65:') -and $r.Error.Contains('límite de profundidad sintáctica excedido')) "Parser/$comando : $($r.Codigo) $($r.Error)"
    }
}

Write-Output "$script:comprobaciones comprobaciones de límites correctas ($Seccion)."
