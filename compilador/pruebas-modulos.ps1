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
    if ($null -ne $info.ArgumentList) { foreach ($arg in $Argumentos) { [void]$info.ArgumentList.Add($arg) } }
    else { $info.Arguments = ($Argumentos | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } }) -join ' ' }
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
[void](Guardar 'mates' @'
importar matematicas
fijo X = 3
exportar funcion calcular() -> entero
    retornar X + matematicas.piso(2.9)
fin
funcion auxiliar()
    retornar 100
fin
exportar funcion otra()
    retornar 200
fin
funcion principal()
    imprimir("NO EJECUTAR")
fin
'@)
$entrada = Guardar 'con-constante' "importar calcular desde `"mates`"`nfuncion principal()`n    imprimir(calcular())`nfin`n"
$r = Ejecutar $Alma @('ejecutar', $entrada)
Comprobar ($r.Codigo -eq 0 -and $r.Salida -eq "5`n") "Importaciones/constantes privadas: $($r.Error) $($r.Salida)"
$privado = Guardar 'privado' "importar auxiliar desde `"mates`"`n"
ErrorAlma $privado 'símbolo no exportado'
$ausente = Guardar 'ausente' "importar fantasma desde `"mates`"`n"
ErrorAlma $ausente 'símbolo no exportado'
$filtrado = Guardar 'filtrado' "importar calcular desde `"mates`"`nfuncion principal()`n    auxiliar()`nfin`n"
ErrorAlma $filtrado "nombre no definido: 'auxiliar'"
$selectivo = Guardar 'selectivo' "importar calcular desde `"mates`"`nfuncion principal()`n    otra()`nfin`n"
ErrorAlma $selectivo "nombre no definido: 'otra'"
foreach ($nombre in @('a', 'b')) {
    $n = if ($nombre -eq 'a') { 10 } else { 20 }
    [void](Guardar $nombre "funcion auxiliar()`n    retornar $n`nfin`nexportar funcion $nombre()`n    retornar auxiliar()`nfin`n")
}
$aislado = Guardar 'aislado' @'
importar a desde "a"
importar b desde "b"
funcion auxiliar()
    retornar 99
fin
funcion principal()
    imprimir(a(), b(), auxiliar())
fin
'@
$r = Ejecutar $Alma @('ejecutar', $aislado)
Comprobar ($r.Codigo -eq 0 -and $r.Salida -eq "10 20 99`n") "Aislamiento: $($r.Error)"
foreach ($backend in @('c', 'propio')) {
    $r = Ejecutar $Alma @('compilar', $aislado, "--backend=$backend", '--sobrescribir')
    Comprobar ($r.Codigo -eq 0) "Compilar $backend : $($r.Error)"
    $r = Ejecutar ([IO.Path]::ChangeExtension($aislado, '.exe')) @()
    Comprobar ($r.Codigo -eq 0 -and $r.Salida -eq "10 20 99`n") "Aislamiento $backend : $($r.Error) $($r.Salida)"
}
$colision = Guardar 'colision' "importar a desde `"a`"`nfuncion a()`n    retornar 1`nfin`n"
ErrorAlma $colision 'conflicto de nombre importado'
$reasignar = Guardar 'reasignar' "importar a desde `"a`"`na = 1`n"
ErrorAlma $reasignar 'no se puede reasignar el nombre importado'
$anidado = Guardar 'anidado' "funcion principal()`n    importar matematicas`nfin`n"
ErrorAlma $anidado 'importar solo se permite a nivel superior'
[void](Guardar 'suelto' "imprimir(99)`nexportar funcion f()`n    retornar 1`nfin`n")
$suelto = Guardar 'usa-suelto' "importar f desde `"suelto`"`n"
ErrorAlma $suelto 'sentencia de nivel superior no permitida'
[void](Guardar 'base' @'
fijo X = crear()
funcion crear()
    imprimir("inicializado")
    retornar 7
fin
exportar funcion valor()
    retornar X
fin
'@)
foreach ($nombre in @('izq', 'der')) {
    [void](Guardar $nombre "importar valor desde `"base`"`nexportar funcion $nombre()`n    retornar valor()`nfin`n")
}
$diamante = Guardar 'diamante' "importar izq desde `"izq`"`nimportar der desde `"der`"`nfuncion principal()`n    imprimir(izq(), der())`nfin`n"
$r = Ejecutar $Alma @('analizar', $diamante)
Comprobar ($r.Codigo -eq 0 -and -not $r.Salida.Contains('inicializado')) 'Analizar ejecutó inicializadores'
$r = Ejecutar $Alma @('ejecutar', $diamante)
Comprobar ($r.Codigo -eq 0 -and $r.Salida -eq "inicializado`n7 7`n") "Diamante/inicialización: $($r.Error) $($r.Salida)"
$r = Ejecutar $Alma @('compilar', $diamante)
Comprobar ($r.Codigo -eq 1 -and $r.Error.Contains('inicializadores globales')) 'C no diagnosticó el subconjunto no soportado'
[void](Guardar 'temprano' "fijo X = obtener()`nfijo Y = 3`nfuncion obtener()`n    retornar Y`nfin`nexportar funcion valor()`n    retornar X`nfin`n")
$temprano = Guardar 'usa-temprano' "importar valor desde `"temprano`"`nfuncion principal()`n    imprimir(99)`nfin`n"
$r = Ejecutar $Alma @('analizar', $temprano)
Comprobar ($r.Codigo -eq 0) "Validación anticipada de fijo: $($r.Error)"
$r = Ejecutar $Alma @('ejecutar', $temprano)
Comprobar ($r.Codigo -eq 1 -and $r.Error.Contains("variable no definida: Y") -and $r.Salida -eq '') 'No se detuvo ante constante sin inicializar'
[void](Guardar 'objeto' @'
fijo X = 9
exportar modelo Caja
    funcion valor()
        retornar X
    fin
fin
exportar estructura Punto
    x: entero
fin
'@)
$objeto = Guardar 'usa-objeto' "importar Caja desde `"objeto`"`nimportar Punto desde `"objeto`"`nfuncion principal()`n    c = Caja()`n    p = Punto(4)`n    imprimir(c.valor(), p.x)`nfin`n"
$r = Ejecutar $Alma @('ejecutar', $objeto)
Comprobar ($r.Codigo -eq 0 -and $r.Salida -eq "9 4`n") "Tipos y métodos: $($r.Error)"
# Un junction no necesita privilegio de creación de symlinks en Windows.
if ($IsWindows) {
    [void](New-Item -ItemType Junction -Path (Join-Path $casos 'enlace') -Target (Join-Path $casos 'sub'))
    $conEnlace = Guardar 'con-enlace' "importar f desde `"sub/x`"`nimportar f desde `"enlace/x`"`nimportar f desde `"SUB/X`"`nfuncion principal()`n    imprimir(f())`nfin`n"
    $r = Ejecutar $Alma @('ejecutar', $conEnlace)
    Comprobar ($r.Codigo -eq 0 -and $r.Salida -eq "42`n") "Identidad de archivo Windows: $($r.Error)"
}
Write-Output "$script:cuenta comprobaciones de módulos correctas."
