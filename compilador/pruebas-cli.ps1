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
    $salida = & $Alma @Argumentos 2>&1
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
funcion doble(n: entero) -> entero
    retornar n * 2
fin
'@)
$principal = Guardar 'principal.alma' @'
importar doble desde "operaciones"
funcion principal()
    imprimir(doble(21))
    a = 9007199254740992
    b = 9007199254740993
    imprimir(a == b, a != b, a < b, b > a, b <= a, a >= b)
    imprimir(-b < -a, -b == -a)
fin
'@
$interpretado = Invocar @('ejecutar', $principal)
Comprobar ($interpretado.Codigo -eq 0) $interpretado.Texto
$esperado = "42`nfalso verdadero verdadero verdadero falso falso`nverdadero falso"
Comprobar ($interpretado.Texto.Replace("`r`n", "`n") -eq $esperado) 'Resultado interpretado incorrecto'
$r = Invocar @('compilar', $principal)
Comprobar ($r.Codigo -eq 0) $r.Texto
$nativo = Join-Path $casos 'principal.exe'
$salidaNativa = (& $nativo | Out-String).Trim()
Comprobar ($LASTEXITCODE -eq 0) 'Falló el ejecutable nativo'
Comprobar ($salidaNativa.Replace("`r`n", "`n") -eq $esperado) 'El resultado nativo difiere del intérprete'

$sinZig = Guardar 'sin-zig.alma' "funcion principal()`n    imprimir(42)`nfin`n"
$rutaAnterior = $env:PATH
try {
    $env:PATH = $casos
    $r = Invocar @('compilar', $sinZig)
    Comprobar ($r.Codigo -ne 0) 'Compilar sin Zig devuelve éxito'
    Comprobar (Test-Path (Join-Path $casos 'sin-zig.c')) 'No se conservó el C cuando faltó Zig'
} finally {
    $env:PATH = $rutaAnterior
}
Write-Output "$script:comprobaciones comprobaciones CLI correctas."
