param([string]$Alma = (Join-Path $PSScriptRoot 'zig-out/bin/alma.exe'))
$ErrorActionPreference = 'Stop'
$Alma = (Resolve-Path -LiteralPath $Alma).Path
$casos = Join-Path $PSScriptRoot ('.zig-cache/pruebas-propio/' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($casos)
$script:cuenta = 0
function Comprobar([bool]$Condicion, [string]$Mensaje) {
    if (-not $Condicion) { throw $Mensaje }
    $script:cuenta++
}
function Invocar([string]$Binario, [string[]]$Argumentos) {
    $inicio = [Diagnostics.ProcessStartInfo]::new($Binario)
    $inicio.UseShellExecute = $false
    $inicio.CreateNoWindow = $true
    $inicio.RedirectStandardOutput = $true
    $inicio.RedirectStandardError = $true
    $inicio.StandardOutputEncoding = [Text.Encoding]::UTF8
    $inicio.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argumento in $Argumentos) { $inicio.ArgumentList.Add($argumento) }
    $proceso = [Diagnostics.Process]::new()
    $proceso.StartInfo = $inicio
    try {
        [void]$proceso.Start()
        $salida = $proceso.StandardOutput.ReadToEndAsync()
        $errores = $proceso.StandardError.ReadToEndAsync()
        if (-not $proceso.WaitForExit(15000)) { $proceso.Kill($true); throw "Tiempo excedido: $Binario" }
        return @{ Codigo = $proceso.ExitCode; Salida = $salida.GetAwaiter().GetResult().Trim().Replace("`r`n", "`n"); Error = $errores.GetAwaiter().GetResult().Trim() }
    } finally { $proceso.Dispose() }
}
function Guardar([string]$Nombre, [string]$Fuente) {
    $archivo = Join-Path $casos ($Nombre + '.alma')
    [IO.File]::WriteAllText($archivo, $Fuente, [Text.UTF8Encoding]::new($false))
    return $archivo
}
function Probar([string]$Nombre, [string]$Fuente, [string]$Esperado, [int]$Codigo = 0) {
    $archivo = Guardar $Nombre $Fuente
    $r = Invocar $Alma @('compilar', $archivo, '--backend=propio')
    Comprobar ($r.Codigo -eq 0) "Compilar $Nombre : $($r.Error)"
    Comprobar (-not (Test-Path (Join-Path $casos ($Nombre + '.c')))) "El backend propio generó C"
    $binario = Join-Path $casos ($Nombre + '.exe')
    $r = Invocar $binario @()
    $contenido = $r.Salida + $r.Error
    Comprobar ($r.Codigo -eq $Codigo) "Ejecutar $Nombre : código $($r.Codigo), $contenido"
    if ($Codigo -eq 0) {
        Comprobar ($r.Salida -eq $Esperado) "Salida $Nombre : $($r.Salida)"
        $interpretado = Invocar $Alma @('ejecutar', $archivo)
        Comprobar ($interpretado.Codigo -eq 0 -and $interpretado.Salida -eq $r.Salida) "Diferencia con intérprete: $Nombre"
    } else { Comprobar ($r.Error.Contains($Esperado)) "Diagnóstico stderr $Nombre : $contenido" }
    return $archivo
}

$pathOriginal = $env:PATH
try {
    # No hay Zig, C, ensamblador ni enlazador en el PATH durante estas pruebas.
    $env:PATH = $casos
    $basico = Probar 'basico' @'
funcion principal()
    imprimir("Hola, Alma: áéíóú", verdadero, falso, nulo)
    imprimir("a" == "a", "a" == "b", "á" != "a", nulo == falso)
fin
'@ "Hola, Alma: áéíóú verdadero falso nulo`nverdadero falso verdadero falso"
    $exeBasico = Join-Path $casos 'basico.exe'
    $hash = (Get-FileHash -LiteralPath $exeBasico -Algorithm SHA256).Hash
    $r = Invocar $Alma @('compilar', $basico, '--backend=propio')
    Comprobar ($r.Codigo -eq 0 -and (Get-FileHash -LiteralPath $exeBasico -Algorithm SHA256).Hash -eq $hash) 'La compilación no es reproducible'

    [void](Probar 'enteros' @'
funcion principal()
    minimo = -9223372036854775807 - 1
    maximo = 9223372036854775807
    imprimir(minimo, maximo, minimo % -1, -7 / 3, -7 % 3)
    imprimir(9007199254740992 < 9007199254740993, maximo > minimo)
fin
'@ "-9223372036854775808 9223372036854775807 0 -2 -1`nverdadero verdadero")

    [void](Guardar 'modulo' "exportar funcion doble(n: entero) -> entero`n    retornar n * 2`nfin`n")
    [void](Probar 'funciones' @'
importar doble desde "modulo"
funcion factorial(n: entero) -> entero
    si n <= 1
        retornar 1
    fin
    retornar n * factorial(n - 1)
fin
funcion marca(n: entero) -> entero
    imprimir(n)
    retornar n
fin
funcion principal()
    imprimir(factorial(6), doble(21), marca(1) + marca(2))
fin
'@ "1`n2`n720 42 3")

    [void](Probar 'control' @'
funcion marca() -> logico
    imprimir("NO")
    retornar verdadero
fin
funcion principal()
    imprimir(falso && marca(), verdadero || marca())
    i = 0
    mientras i < 8
        i = i + 1
        si i == 2
            continuar
        sino si i == 4
            romper
        fin
        imprimir(i)
    fin
fin
'@ "falso verdadero`n1`n3")
    [void](Probar 'overflow' "funcion principal()`n    a = 9223372036854775807`n    imprimir(a + 1)`nfin`n" 'desbordamiento' 1)
    [void](Probar 'cero' "funcion principal()`n    imprimir(1 / 0)`nfin`n" 'cero' 1)
    [void](Probar 'negacion-minimo' "funcion principal()`n    a = -9223372036854775807 - 1`n    imprimir(-a)`nfin`n" 'desbordamiento' 1)
    [void](Probar 'division-minimo' "funcion principal()`n    a = -9223372036854775807 - 1`n    imprimir(a / -1)`nfin`n" 'desbordamiento' 1)
    [void](Probar 'variable-indefinida' "funcion principal()`n    si falso`n        a = 1`n    fin`n    imprimir(a)`nfin`n" 'variable no definida' 1)
    [void](Probar 'condicion-invalida' "funcion principal()`n    a = 1`n    si a`n        imprimir(1)`n    fin`nfin`n" 'tipo incompatible' 1)
    $rechazado = Guardar 'sin-texto-dinamico' "funcion principal()`n    imprimir(texto(42))`nfin`n"
    $r = Invocar $Alma @('compilar', $rechazado, '--backend=propio')
    Comprobar ($r.Codigo -ne 0 -and $r.Error.Contains('texto()')) 'Falta rechazo explícito de texto dinámico'
    Comprobar (-not (Test-Path (Join-Path $casos 'sin-texto-dinamico.exe'))) 'Se generó un ejecutable no soportado'
    $decimal = Guardar 'decimal' "funcion principal()`n    imprimir(1.5)`nfin`n"
    $r = Invocar $Alma @('compilar', $decimal, '--backend=propio')
    Comprobar ($r.Codigo -ne 0 -and $r.Error.Contains('decimales')) 'Falta rechazo de decimales'
} finally { $env:PATH = $pathOriginal }
Write-Output "$script:cuenta comprobaciones del backend propio correctas, sin Zig en PATH."
