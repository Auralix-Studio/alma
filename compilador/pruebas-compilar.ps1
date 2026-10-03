param([string]$Alma = (Join-Path $PSScriptRoot 'zig-out/bin/alma.exe'))
$ErrorActionPreference = 'Stop'
$Alma = (Resolve-Path -LiteralPath $Alma).Path
$casos = Join-Path $PSScriptRoot ('.zig-cache/pruebas-compilar/' + [guid]::NewGuid().ToString('N'))
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

$fuente = Guardar 'programa' "funcion principal()`n    imprimir(42)`nfin`n"
$cAjeno = [IO.Path]::ChangeExtension($fuente, '.c')
[IO.File]::WriteAllText($cAjeno, 'C AJENO')
$r = Ejecutar $Alma @('compilar', $fuente)
Comprobar ($r.Codigo -eq 0 -and [IO.File]::ReadAllText($cAjeno) -eq 'C AJENO') "Se sobrescribió C ajeno: $($r.Error)"
Comprobar (@(Get-ChildItem $casos -Directory -Filter '.alma-tmp-*').Count -eq 0) 'Residuos temporales tras compilar'
foreach ($backend in @('c', 'propio')) {
    $salida = Join-Path $casos "salida $backend.exe"
    [IO.File]::WriteAllText($salida, 'BINARIO AJENO')
    $r = Ejecutar $Alma @('compilar', $fuente, '-o', $salida, "--backend=$backend")
    Comprobar ($r.Codigo -eq 1 -and [IO.File]::ReadAllText($salida) -eq 'BINARIO AJENO' -and $r.Error.Contains('--sobrescribir')) "Protección $backend : $($r.Error)"
    $r = Ejecutar $Alma @('compilar', '-o', $salida, '--sobrescribir', $fuente, "--backend=$backend")
    Comprobar ($r.Codigo -eq 0) "Sobrescritura explícita $backend : $($r.Error)"
    $r = Ejecutar $salida @()
    Comprobar ($r.Codigo -eq 0 -and $r.Salida -eq "42`n") "Salida con espacios $backend : $($r.Error)"
}
$r = Ejecutar $Alma @('compilar', $fuente, '-o', $fuente, '--sobrescribir')
Comprobar ($r.Codigo -eq 1 -and [IO.File]::ReadAllText($fuente).StartsWith('funcion principal')) 'Se destruyó el fuente'
$conservar = Join-Path $casos 'conservar.exe'
$r = Ejecutar $Alma @('compilar', $fuente, '-o', $conservar, '--conservar-c')
Comprobar ($r.Codigo -eq 0 -and $r.Salida -match '(?m)^C conservado: (.+)$') "Conservar C: $($r.Error) $($r.Salida)"
$cConservado = $Matches[1].Trim()
Comprobar ((Test-Path -LiteralPath $cConservado) -and [IO.File]::ReadAllText($cConservado).Contains('ALMA_LIMITE_LLAMADAS')) 'No se conservó el C generado'
$antes = @(Get-ChildItem $casos -Directory -Filter '.alma-tmp-*').Count
$pathOriginal = $env:PATH
try {
    $env:PATH = $casos
    $salida = Join-Path $casos 'fallo.exe'
    [IO.File]::WriteAllText($salida, 'INTACTO')
    $r = Ejecutar $Alma @('compilar', $fuente, '-o', $salida, '--sobrescribir')
    Comprobar ($r.Codigo -eq 1 -and [IO.File]::ReadAllText($salida) -eq 'INTACTO') 'La compilación fallida modificó la salida'
    Comprobar (@(Get-ChildItem $casos -Directory -Filter '.alma-tmp-*').Count -eq $antes) 'Residuos tras fallo de Zig'
    $r = Ejecutar $Alma @('compilar', $fuente, '-o', $salida, '--sobrescribir', '--conservar-c')
    Comprobar ($r.Codigo -eq 1 -and $r.Salida -match '(?m)^C conservado: (.+)$') 'No se conservó el C solicitado tras fallo'
    Comprobar (Test-Path -LiteralPath $Matches[1].Trim()) 'C conservado ausente tras fallo'
} finally { $env:PATH = $pathOriginal }
foreach ($extras in @(@('-o'), @('--desconocido'), @('--backend=propio', '--conservar-c'))) {
    $r = Ejecutar $Alma (@('compilar', $fuente) + $extras)
    Comprobar ($r.Codigo -eq 1) "Opciones inválidas aceptadas: $extras"
}
Write-Output "$script:cuenta comprobaciones de compilación segura correctas."

