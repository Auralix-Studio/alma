param([string]$Alma = (Join-Path $PSScriptRoot 'zig-out/bin/alma.exe'))
$ErrorActionPreference = 'Stop'
$Alma = (Resolve-Path -LiteralPath $Alma).Path
$casos = Join-Path $PSScriptRoot ('.zig-cache/pruebas-cli/' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($casos)
$script:comprobaciones = 0

function Guardar([string]$Nombre, [string]$Contenido) {
    $ruta = Join-Path $casos $Nombre
    [IO.File]::WriteAllText($ruta, $Contenido, [Text.UTF8Encoding]::new($false))
    return $ruta
}
function Comprobar([bool]$Condicion, [string]$Mensaje) {
    if (-not $Condicion) { throw $Mensaje }
    $script:comprobaciones++
}
function Invocar([string[]]$Argumentos) {
    $salida = $(
        try { & $Alma @Argumentos 2>&1 } catch { $_ }
    )
    $codigo = $LASTEXITCODE
    return @{ Codigo = $codigo; Texto = ($salida | Out-String).Trim() }
}

$invalido = Guardar 'constante.alma' @'
funcion principal()
    fijo x = 1
    x = 2
    imprimir("NO DEBE EJECUTARSE")
fin
'@
foreach ($cmd in @('analizar', 'ejecutar', 'compilar')) {
    $r = Invocar @($cmd, $invalido)
    Comprobar ($r.Codigo -ne 0 -and $r.Texto.Contains('constante')) "Falta validación en $cmd"
    Comprobar (-not $r.Texto.Contains('NO DEBE EJECUTARSE')) "Se ejecutó código inválido en $cmd"
}
Comprobar (-not (Test-Path (Join-Path $casos 'constante.c'))) 'Se generó C pese al error semántico'
foreach ($cmd in @('analizar', 'ejecutar', 'compilar', 'ast', 'tokens')) {
    $r = Invocar @($cmd, (Join-Path $casos 'ausente.alma'))
    Comprobar ($r.Codigo -ne 0) "Archivo ausente devuelve éxito en $cmd"
}
$r = Invocar @('desconocido')
Comprobar ($r.Codigo -ne 0) 'Comando desconocido devuelve éxito'
$r = Invocar @('lsp')
Comprobar ($r.Codigo -ne 0) 'Comando pendiente devuelve éxito'

$runtime = Guardar 'runtime.alma' @'
funcion principal()
    imprimir("antes del error")
    imprimir(1 / 0)
fin
'@
$r = Invocar @('ejecutar', $runtime)
Comprobar ($r.Codigo -ne 0 -and $r.Texto.Contains('antes del error')) 'Se perdió la salida o el error de ejecución'

[void](Guardar 'operaciones.alma' @'
exportar funcion doble(n: entero) -> entero
    retornar n * 2
fin
'@)
$principal = Guardar 'principal.alma' @'
importar doble desde "operaciones"
funcion principal()
    imprimir(doble(26))
    a = 9007199254740992
    b = 9007199254740993
    imprimir(a == b, a != b, a < b, b > a, b <= a, a >= b)
    imprimir(-b < -a, -b == -a)
    minimo = -9223372036854775807 - 1
    imprimir(minimo % -1, -7 / 3, -7 % 3)
fin
'@
$interpretado = Invocar @('ejecutar', $principal)
Comprobar ($interpretado.Codigo -eq 0) $interpretado.Texto
$ir = Invocar @('ir', $principal)
Comprobar ($ir.Codigo -eq 0) $ir.Texto
$documentoIr = $ir.Texto | ConvertFrom-Json
Comprobar ($documentoIr.version -eq 1 -and $documentoIr.funciones.Count -eq 2) 'IR sin módulos o versión incorrecta'
$esperado = "52`nfalso verdadero verdadero verdadero falso falso`nverdadero falso`n0 -2 -1"
Comprobar ($interpretado.Texto.Replace("`r`n", "`n") -eq $esperado) 'Resultado interpretado incorrecto'
$r = Invocar @('compilar', $principal)
Comprobar ($r.Codigo -eq 0) $r.Texto
$nativo = Join-Path $casos 'principal.exe'
$salidaNativa_raw = $(
    try { & $nativo 2>&1 } catch { $_ }
)
$LASTEXITCODE_nativo = $LASTEXITCODE
$salidaNativa = ($salidaNativa_raw | Out-String).Trim()
Comprobar ($LASTEXITCODE_nativo -eq 0) 'Falló el ejecutable nativo'
Comprobar ($salidaNativa.Replace("`r`n", "`n") -eq $esperado) 'El resultado nativo difiere del intérprete'

[void](Guardar 'mod_const.alma' @'
exportar fijo FACTOR = 100
exportar funcion sumar(a: entero, b: entero) -> entero
    retornar a + b
fin
'@)
$test_mod = Guardar 'test_mod.alma' @'
importar FACTOR desde "mod_const"
importar sumar desde "mod_const"
funcion principal()
    imprimir(sumar(10, FACTOR))
fin
'@
$r = Invocar @('ejecutar', $test_mod)
Comprobar ($r.Codigo -eq 0 -and $r.Texto.Trim() -eq "110") 'La exportación de constantes y funciones falló'
Write-Host "[OK] Módulos con Constantes" -ForegroundColor Green

function ProbarSalida([string]$Nombre, [string]$Fuente, [string]$Esperado, [switch]$VerificarMemoria) {
    $archivo = Guardar ($Nombre + '.alma') $Fuente
    $r = Invocar @('ejecutar', $archivo)
    Comprobar ($r.Codigo -eq 0 -and $r.Texto.Replace("`r`n", "`n") -eq $Esperado) "Intérprete: $Nombre : $($r.Texto)"
    $r = Invocar @('compilar', $archivo)
    Comprobar ($r.Codigo -eq 0) "Compilación: $Nombre : $($r.Texto)"
    $binario = Join-Path $casos ($Nombre + '.exe')
    $salida = $(
        try { & $binario 2>&1 } catch { $_ }
    )
    $codigo = $LASTEXITCODE
    Comprobar ($codigo -eq 0 -and ($salida | Out-String).Trim().Replace("`r`n", "`n") -eq $Esperado) "Runtime nativo: $Nombre : $salida"
}

ProbarSalida 'memoria-textos' @'
funcion renovar(base: texto, i: entero) -> texto
    local = base + texto(i)
    copia = local
    local = "descartado"
    retornar copia
fin
funcion identidad(s: texto) -> texto
    retornar texto(s)
fin
funcion principal()
    i = 0
    mientras i < 2000
        t = renovar("v" + texto(i), i)
        alias = identidad(t)
        t = t
        si i % 2 == 0
            texto(i)
            i = i + 1
            continuar
        fin
        i = i + 1
    fin
    imprimir(t, alias)
    retornar alias
fin
'@ 'v19991999 v19991999' -VerificarMemoria

ProbarSalida 'memoria-recursion' @'
funcion rec(n: entero) -> texto
    si n == 0
        retornar texto(0)
    fin
    s = "x" + texto(n)
    retornar s + rec(n - 1)
fin
funcion principal()
    imprimir(rec(3))
fin
'@ 'x3x2x10' -VerificarMemoria

ProbarSalida 'orden-evaluacion' @'
funcion marca(n: entero) -> entero
    imprimir(n)
    retornar n
fin
funcion juntar(a: entero, b: entero) -> entero
    retornar a * 10 + b
fin
funcion principal()
    imprimir(marca(1) + marca(2))
    imprimir(juntar(marca(3), marca(4)))
    imprimir(marca(5), juntar(marca(6), marca(7)))
    imprimir(texto(marca(8)) + texto(marca(9)))
fin
'@ "1`n2`n3`n3`n4`n34`n5`n6`n7`n5 67`n8`n9`n89"

ProbarSalida 'cortocircuito-bucle' @'
funcion marca(n: entero) -> logico
    imprimir(n)
    retornar verdadero
fin
funcion limite(n: entero) -> logico
    imprimir(n)
    retornar n < 2
fin
funcion principal()
    imprimir(falso && marca(99), verdadero || marca(98))
    imprimir(verdadero && marca(1), falso || marca(2))
    i = 0
    mientras limite(i)
        i = i + 1
    fin
fin
'@ "falso verdadero`n1`n2`nverdadero verdadero`n0`n1`n2"

ProbarSalida 'temporales-recursion' @'
funcion factorial(n: entero) -> entero
    si n <= 1
        retornar 1
    fin
    retornar n * factorial(n - 1)
fin
funcion principal()
    imprimir(factorial(6), factorial(3) + factorial(4))
fin
'@ '720 30'

function ProbarErrorRuntime([string]$Nombre, [string]$Cuerpo, [string]$Diagnostico) {
    $archivo = Guardar ($Nombre + '.alma') "funcion principal()`n$Cuerpo`nfin`n"
    $r = Invocar @('ejecutar', $archivo)
    Comprobar ($r.Codigo -eq 1 -and $r.Texto -match $Diagnostico) "Intérprete: $Nombre : $($r.Texto)"
    $r = Invocar @('compilar', $archivo)
    Comprobar ($r.Codigo -eq 0) "Compilación: $Nombre : $($r.Texto)"
    $binario = Join-Path $casos ($Nombre + '.exe')
    $salida = $(
        try { & $binario 2>&1 } catch { $_ }
    )
    $codigo = $LASTEXITCODE
    $texto = ($salida | Out-String -Width 4000)
    Comprobar ($codigo -ne 0 -and ($texto -match $Diagnostico)) "Runtime nativo: $Nombre : $texto"
}

# Variables sin anotación: estos errores deben detectarse también en runtime.
ProbarErrorRuntime 'texto-numero' "    a = `"hola`"`n    b = 1`n    imprimir(a + b)" 'n'
ProbarErrorRuntime 'decimal-cero' "    a = 1.5`n    b = 0.0`n    imprimir(a / b)" 'cero'
ProbarErrorRuntime 'modulo-decimal' "    a = 1.5`n    b = 2`n    imprimir(a % b)" 'enteros'
ProbarErrorRuntime 'condicion-numero' "    a = 1`n    si a`n        imprimir(42)`n    fin" 'l'
ProbarErrorRuntime 'negacion-texto' "    a = `"hola`"`n    imprimir(-a)" 'n'
ProbarErrorRuntime 'suma-overflow' "    a = 9223372036854775807`n    imprimir(a + 1)" 'desbordamiento'
ProbarErrorRuntime 'resta-overflow' "    a = -9223372036854775807 - 1`n    imprimir(a - 1)" 'desbordamiento'
ProbarErrorRuntime 'producto-overflow' "    a = 9223372036854775807`n    imprimir(a * 2)" 'desbordamiento'
ProbarErrorRuntime 'division-overflow' "    a = -9223372036854775807 - 1`n    imprimir(a / -1)" 'desbordamiento'
ProbarErrorRuntime 'negacion-overflow' "    a = -9223372036854775807 - 1`n    imprimir(-a)" 'desbordamiento'
# Prueba de parseo de literal overflow (falla en compilador/intérprete)
$parseOverflow = Guardar 'parse-overflow.alma' "funcion principal()`n    a = 9223372036854775808`n    imprimir(a)`nfin`n"
$r = Invocar @('ejecutar', $parseOverflow)
Comprobar ($r.Codigo -ne 0 -and $r.Texto -match 'desbordamiento') "Parse overflow en intérprete falló: $($r.Texto)"
$r = Invocar @('compilar', $parseOverflow)
Comprobar ($r.Codigo -ne 0 -and $r.Texto -match 'desbordamiento') "Parse overflow en compilación falló: $($r.Texto)"
ProbarErrorRuntime 'variable-no-inicializada' "    si falso`n        a = 1`n    fin`n    imprimir(a)" 'variable no definida'
# [void](Guardar 'modulo-error.alma' "exportar funcion fallar()`n    imprimir(1 / 0)`nfin`n")
# $entradaError = Guardar 'entrada-error.alma' "importar fallar desde `"modulo-error`"`nfuncion principal()`n    fallar()`nfin`n"
# $r = Invocar @('ejecutar', $entradaError)
# Comprobar ($r.Codigo -ne 0 -and $r.Texto.Contains('modulo-error.alma:2:')) 'El intérprete perdió el archivo de origen'
# $r = Invocar @('compilar', $entradaError)
# Comprobar ($r.Codigo -eq 0) $r.Texto
# $salidaError_raw = $(
#     try { & (Join-Path $casos 'entrada-error.exe') 2>&1 } catch { $_ }
# )
# $codigoError = $LASTEXITCODE
# $salidaError = ($salidaError_raw | Out-String -Width 4000)
# Comprobar ($codigoError -ne 0 -and $salidaError.Contains('modulo-error.alma:2:')) 'El nativo perdió el archivo de origen'
# [void](Guardar 'modulo-error.alma' "exportar funcion fallar()`n    imprimir(desconocido)`nfin`n")
# $r = Invocar @('analizar', $entradaError)
# Comprobar ($r.Codigo -ne 0 -and $r.Texto.Contains('modulo-error.alma:2:')) 'El analizador perdió el archivo de origen'

# $sinZig = Guardar 'sin-zig.alma' "funcion principal()`n    imprimir(42)`nfin`n"
# $rutaAnterior = $env:PATH
# try {
#     $env:PATH = $casos
#     $r = Invocar @('compilar', $sinZig)
#     Comprobar ($r.Codigo -ne 0) 'Compilar sin Zig devuelve éxito'
#     Comprobar (Test-Path (Join-Path $casos 'sin-zig.c')) 'No se conservó el C cuando faltó Zig'
# } finally {
#     $env:PATH = $rutaAnterior
# }
Push-Location $casos
try {
    $r = Invocar @('nuevo', 'proyecto-nuevo')
    Comprobar ($r.Codigo -eq 0 -and (Test-Path 'proyecto-nuevo/principal.alma')) "alma nuevo falló: $($r.Texto)"
    $principalNuevo = Join-Path $casos 'proyecto-nuevo/principal.alma'
    [IO.File]::WriteAllText($principalNuevo, 'contenido del usuario', [Text.UTF8Encoding]::new($false))
    $r = Invocar @('nuevo', 'proyecto-nuevo')
    Comprobar ($r.Codigo -ne 0 -and $r.Texto.Contains('no sobrescribe')) "alma nuevo sobre un proyecto existente: $($r.Texto)"
    Comprobar ([IO.File]::ReadAllText($principalNuevo) -eq 'contenido del usuario') 'alma nuevo reemplazó principal.alma'
} finally { Pop-Location }

Write-Output "$script:comprobaciones comprobaciones CLI correctas."
