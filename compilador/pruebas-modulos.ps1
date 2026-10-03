param([string]$Alma = (Join-Path $PSScriptRoot 'zig-out/bin/alma.exe'))
$ErrorActionPreference = 'Stop'
$Alma = (Resolve-Path -LiteralPath $Alma).Path
$casos = Join-Path $PSScriptRoot ('.zig-cache/pruebas-modulos/' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($casos)
$script:cuenta = 0
function Guardar([string]$Nombre, [string]$Fuente) {
    $ruta = Join-Path $casos ($Nombre + '.alma')
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ruta))
    [IO.File]::WriteAllText($ruta, $Fuente, [Text.UTF8Encoding]::new($false))
    return $ruta
}
function Ejecutar([string]$Binario, [string[]]$Argumentos) {
    $info = [Diagnostics.ProcessStartInfo]::new($Binario)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($arg in $Argumentos) { [void]$info.ArgumentList.Add($arg) }
    $p = [Diagnostics.Process]::Start($info)
    try {
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(30000)) { $p.Kill($true); $p.WaitForExit(); throw 'Timeout' }
        return @{ Codigo = $p.ExitCode; Salida = $out.GetAwaiter().GetResult().Replace("`r`n", "`n"); Error = $err.GetAwaiter().GetResult() }
    } finally { $p.Dispose() }
}
function Comprobar([bool]$Valor, [string]$Mensaje) {
    if (-not $Valor) { throw $Mensaje }
    $script:cuenta++
}
function ErrorAlma([string]$Ruta, [string]$Mensaje) {
    foreach ($cmd in @('analizar', 'ejecutar', 'compilar')) {
        $r = Ejecutar $Alma @($cmd, $Ruta)
        Comprobar ($r.Codigo -eq 1 -and $r.Error.Contains($Mensaje)) "$cmd esperaba '$Mensaje': $($r.Codigo) $($r.Error)"
    }
}

$entrada = Guardar 'ciclo' "importar f desde `"ciclo-b`"`nexportar funcion principal()`n    retornar 0`nfin`n"
[void](Guardar 'ciclo-b' "importar principal desde `"ciclo`"`nexportar funcion f()`n    retornar 0`nfin`n")
ErrorAlma $entrada 'ciclo de importación:'
$r = Ejecutar $Alma @('analizar', $entrada)
Comprobar ($r.Error.Contains('ciclo-b.alma:1:1:') -and $r.Error.Contains(' -> ')) 'Ciclo sin cadena o posición'
$directo = Guardar 'directo' "importar f desde `"directo`"`nexportar funcion f()`n    retornar 0`nfin`n"
ErrorAlma $directo 'ciclo de importación:'
[void](Guardar 'sub/x' "exportar funcion f()`n    retornar 42`nfin`n")
$alias = Guardar 'alias' "importar f desde `"sub/x`"`nimportar f desde `"sub/../sub/x`"`nfuncion principal()`n    imprimir(f())`nfin`n"
$r = Ejecutar $Alma @('ejecutar', $alias)
Comprobar ($r.Codigo -eq 0 -and $r.Salida -eq "42`n") "Alias de ruta: $($r.Error)"
Write-Output "$script:cuenta comprobaciones de módulos correctas."
