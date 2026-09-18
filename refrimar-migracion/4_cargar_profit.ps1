# ============================================================
# REFRIMAR -> MIGRACION A PROFIT PLUS 2KDOCE
# Paso 4 (v2): Cargador completo del catalogo en SQL Server.
# Pipeline en UNA transaccion (todo o nada):
#   1. Crea LINEAS, SUBLINEAS y CATEGORIAS faltantes.
#   2. Crea UNIDADES faltantes (uds/kg/mt).
#   3. Inserta ARTICULOS (saArticulo).
#   4. Inserta PRECIOS (saArtPrecio).
#   5. Inserta UNIDAD por articulo (saArtUnidad).
#   6. Inserta STOCK inicial (saStockAlmacen, tipo 'ACT ').
#
# ANTES DE USAR:
#   1. Completa config.json (Servidor, BaseDatos, Usuario/Password).
#   2. HAZ UN BACKUP de la base (Herramienta de Administracion,
#      o SSMS: Tasks -> Back Up...). Este paso es obligatorio.
#   3. Prueba primero en una COPIA de la base (Restore a otro
#      nombre) antes de correr en produccion.
#
# Modo seguro (solo reporta el plan):
#   powershell -ExecutionPolicy Bypass -File 4_cargar_profit.ps1
# Modo real (escribe SOLO tras revisar el plan y hacer backup):
#   powershell -ExecutionPolicy Bypass -File 4_cargar_profit.ps1 -Confirmar
#
# Salidas: salida/resultado_carga.csv, salida/log_carga.txt
# ============================================================

param([switch]$Confirmar)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$salida = Join-Path $scriptDir "salida"
$configPath = Join-Path $scriptDir "config.json"
$csvEntrada = Join-Path $salida "refrimar_normalizado.csv"

# ---------- Configuracion ----------
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Host "No existe config.json. Copia config.json.ejemplo a config.json"
    Write-Host "y completa Servidor, BaseDatos, Usuario, Password."
    exit 1
}
$cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $cfg.Profit2K.Servidor -or -not $cfg.Profit2K.BaseDatos) {
    Write-Host "config.json incompleto: faltan Servidor o BaseDatos."
    exit 1
}

$connString = ""
if ($cfg.Profit2K.Usuario) {
    $connString = "Server=$($cfg.Profit2K.Servidor);Database=$($cfg.Profit2K.BaseDatos);User Id=$($cfg.Profit2K.Usuario);Password=$($cfg.Profit2K.Password);TrustServerCertificate=True"
} else {
    $connString = "Server=$($cfg.Profit2K.Servidor);Database=$($cfg.Profit2K.BaseDatos);Integrated Security=True;TrustServerCertificate=True"
}

if (-not (Test-Path -LiteralPath $csvEntrada)) {
    Write-Host "No existe $csvEntrada. Corre antes 1_extraer_supabase.py y 2_normalizar.py"
    exit 1
}

Add-Type -AssemblyName System.Data
New-Item -ItemType Directory -Path $salida -Force | Out-Null

# ---------- Lectura del catalogo normalizado ----------
$filas = Import-Csv -LiteralPath $csvEntrada -Encoding UTF8

# ---------- Conexion ----------
try {
    $conn = New-Object System.Data.SqlClient.SqlConnection $connString
    $conn.Open()
} catch {
    Write-Host "ERROR de conexion a SQL Server: $($_.Exception.Message)"
    exit 1
}

function EjecutarEscalar($sql) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    try { return $cmd.ExecuteScalar() } catch { throw }
}

function EjecutarNoQuery($sql) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.Transaction = $script:trans
    return $cmd.ExecuteNonQuery()
}

function Rango6($codigo) {
    # Rellena a 6 caracteres con espacios a la derecha (formato Profit)
    return (($codigo -replace '\s', '') + (' ' * 6)).Substring(0, 6)
}

function FechaProfit($fecha) {
    return $fecha.ToString("yyyyMMdd HH:mm:ss")
}

function NormalizarColumnas($tabla, $obligatorias) {
    # Devuelve las columnas REALES de la tabla y verifica que existan.
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT COLUMN_NAME, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$tabla'"
    $rdr = $cmd.ExecuteReader()
    $cols = @{}
    while ($rdr.Read()) { $cols[$rdr.GetString(0).ToLower()] = $rdr.GetString(1) }
    $rdr.Close()
    foreach ($c in $obligatorias) {
        if (-not $cols.ContainsKey($c.ToLower())) {
            throw "La tabla [$tabla] no tiene la columna [$c]. Revisa el esquema real y ajusta el mapeo."
        }
    }
    return $cols
}

# ---------- Verificacion de tablas clave ----------
$tablasClave = @('saArticulo', 'saArtPrecio', 'saArtUnidad', 'saLineaArticulo', 'saSubLinea', 'saCatArticulo', 'saUnidad', 'saStockAlmacen', 'saSucursal', 'saAlmacen', 'saTipoPrecio')
foreach ($t in $tablasClave) {
    $existe = EjecutarEscalar "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$t'"
    if ([int]$existe -eq 0) { Write-Host "AVISO: no existe la tabla [$t] en esta base." }
}

$colsArticulo = NormalizarColumnas 'saArticulo' @('co_art', 'fecha_reg', 'art_des', 'tipo', 'anulado', 'co_lin', 'co_subl', 'co_cat', 'tipo_imp', 'rowguid')
$colsArtPrecio = NormalizarColumnas 'saArtPrecio' @('co_art', 'co_precio', 'monto', 'rowguid')
$colsArtUnidad = NormalizarColumnas 'saArtUnidad' @('co_art', 'co_uni', 'relacion', 'equivalencia', 'uso_venta', 'uso_compra', 'uni_principal', 'uso_principal', 'uni_secundaria', 'uso_secundaria', 'rowguid')
$colsStock = NormalizarColumnas 'saStockAlmacen' @('co_alma', 'co_art', 'tipo', 'stock')

$longArtDes = [int](EjecutarEscalar "SELECT CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='saArticulo' AND COLUMN_NAME='art_des'")
if ($longArtDes -le 0) { $longArtDes = 60 }

# ---------- Valores de referencia desde la base real ----------
$coSucuIn = "01    "
$v = EjecutarEscalar "SELECT TOP 1 co_sucu_in FROM saArticulo"
if ($v) { $coSucuIn = (Rango6 $v) }

$coUsIn = "001   "
$v = EjecutarEscalar "SELECT TOP 1 co_us_in FROM saArticulo"
if ($v) { $coUsIn = (Rango6 $v) }

$coPrecio = "01    "
$v = EjecutarEscalar "SELECT TOP 1 co_precio FROM saTipoPrecio"
if ($v) { $coPrecio = (Rango6 $v) }

$coAlma = "001   "
$v = EjecutarEscalar "SELECT TOP 1 co_alma FROM saAlmacen"
if ($v) { $coAlma = (Rango6 $v) }

$tipoImp = "1"
$v = EjecutarEscalar "SELECT TOP 1 tipo_imp FROM saArticulo WHERE tipo_imp IS NOT NULL"
if ($v) { $tipoImp = (("$v").Trim()) }

$fechaReg = (Get-Date).ToString("yyyyMMdd")
$fechaAudit = FechaProfit (Get-Date)

Write-Host ""
Write-Host "== PASO 4: Carga del catalogo (v2) =="
Write-Host ("  Base      : {0} / {1}" -f $cfg.Profit2K.Servidor, $cfg.Profit2K.BaseDatos)
Write-Host ("  Registros : {0}" -f $filas.Count)
Write-Host ("  Modo      : {0}" -f ($(if ($Confirmar) { "REAL (ESCRIBE)" } else { "SECURO / DRY-RUN" })))
Write-Host ("  Ref: co_sucu_in={0} co_us_in={1} co_precio={2} co_alma={3} tipo_imp={4}" -f $coSucuIn, $coUsIn, $coPrecio, $coAlma, $tipoImp)
Write-Host ("  Longitud art_des en BD: {0}" -f $longArtDes)

# ---------- Plan: comparar contra lo existente ----------
function ConjuntoCol($tabla, $col) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT DISTINCT LTRIM(RTRIM($col)) FROM [$tabla] WHERE $col IS NOT NULL"
    $rdr = $cmd.ExecuteReader()
    $s = @{}
    while ($rdr.Read()) { $s[$rdr.GetString(0)] = $true }
    $rdr.Close()
    return $s
}

$articulosBD = ConjuntoCol 'saArticulo' 'co_art'
$lineasBD = ConjuntoCol 'saLineaArticulo' 'co_lin'
$sublineasBD = @{}   # "lin|sub"
$cmd = $conn.CreateCommand()
$cmd.CommandText = "SELECT LTRIM(RTRIM(co_lin)), LTRIM(RTRIM(co_subl)) FROM saSubLinea"
$rdr = $cmd.ExecuteReader()
while ($rdr.Read()) { $sublineasBD["$($rdr.GetString(0))|$($rdr.GetString(1))"] = $true }
$rdr.Close()
$catBD = ConjuntoCol 'saCatArticulo' 'co_cat'
$uniBD = ConjuntoCol 'saUnidad' 'co_uni'

# Generar codigos de linea/sublinea/categoria nuevos (sin chocar con existentes)
$lineasNuevas = @()
$codigosUsados = @{}
foreach ($k in $lineasBD.Keys) { $codigosUsados[(Rango6 $k)] = $true }

$lineasPlan = @{}   # linea_canonica -> {cod, cod_sub_linea}
$subsPlan = @{}     # "linea|sublinea" -> codigo sub
$catPlan = @{}      # linea|sublinea -> co_cat

foreach ($l in $filas | Sort-Object linea, sublinea -Unique) {
    $lin = $l.linea.Trim().ToUpper()
    $sub = $l.sublinea.Trim().ToUpper()
    if (-not $lineasPlan.ContainsKey($lin)) {
        $num = 1
        $cod = Rango6 ("{0:00}" -f $num)
        while ($codigosUsados.ContainsKey($cod)) { $num++; $cod = Rango6 ("{0:00}" -f $num) }
        $codigosUsados[$cod] = $true
        $lineasPlan[$lin] = @{ cod = $cod; subs = @{} }
        $lineasNuevas += [PSCustomObject]@{ linea = $lin; co_lin = $cod.Trim() }
    }
    $clave = "$lin|$sub"
    if (-not $lineasPlan[$lin].subs.ContainsKey($clave)) {
        $n = $lineasPlan[$lin].subs.Count + 1
        $lineasPlan[$lin].subs[$clave] = @{ cod = Rango6 ("{0:00}" -f $n); cat = Rango6 (($lineasPlan[$lin].cod.Trim()) + ("{0:00}" -f $n)) }
    }
}

# Unidades requeridas
$unidadesReq = @{}
foreach ($l in $filas) {
    $u = $l.unidad.Trim()
    if ($u -eq "uds") { $u = "UNI" } elseif ($u -eq "kg") { $u = "KG" } elseif ($u -eq "mt") { $u = "MT" }
    $unidadesReq[$u] = $true
}

$aInsertar = 0; $aSaltar = 0
foreach ($f in $filas) {
    if ($articulosBD.ContainsKey($f.codigo)) { $aSaltar++ } else { $aInsertar++ }
}

Write-Host ""
Write-Host ("  Lineas nuevas     : {0}" -f $lineasNuevas.Count)
Write-Host ("  Sublineas nuevas  : {0}" -f (($lineasPlan.Values | ForEach-Object { $_.subs.Count } | Measure-Object -Sum).Sum))
Write-Host ("  Unidades a crear  : {0} ({1})" -f $unidadesReq.Count, (($unidadesReq.Keys | Sort-Object) -join ", "))
Write-Host ("  Articulos a crear : {0}  |  Ya existen: {1}" -f $aInsertar, $aSaltar)
Write-Host ""

if (-not $Confirmar) {
    Write-Host "MODO SECURO: no se escribio nada. Revisa el plan; cuando estes listo (con BACKUP hecho):"
    Write-Host "  powershell -ExecutionPolicy Bypass -File 4_cargar_profit.ps1 -Confirmar"
    $conn.Close()
    exit 0
}

# ============================================================
# CARGA REAL (transaccion unica)
# ============================================================
$log = @()
$detalle = @()
$insertados = 0; $saltados = 0; $errores = 0

$trans = $conn.BeginTransaction()
try {
    $fe = "'" + $fechaAudit + "'"
    $fecReg = "'" + $fechaReg + "'"

    # 1) LINEAS
    foreach ($lp in $lineasPlan.GetEnumerator()) {
        $cod = $lp.Value.cod
        $sql = "INSERT INTO [saLineaArticulo] ([co_lin],[lin_des],[va],[movil],[co_us_in],[co_sucu_in],[fe_us_in],[rowguid]) VALUES " +
               "('$cod', '$($lp.Key)', 0, 0, '$coUsIn', '$coSucuIn', $fe, '$([guid]::NewGuid())')"
        [void](EjecutarNoQuery $sql)
        # SUBLINEAS
        foreach ($s in $lp.Value.subs.GetEnumerator()) {
            $parts = $s.Key.Split('|')
            $codSub = $s.Value.cod
            $sql = "INSERT INTO [saSubLinea] ([co_lin],[co_subl],[subl_des],[movil],[co_us_in],[co_sucu_in],[fe_us_in],[rowguid]) VALUES " +
                   "('$cod', '$codSub', '$($parts[1])', 0, '$coUsIn', '$coSucuIn', $fe, '$([guid]::NewGuid())')"
            [void](EjecutarNoQuery $sql)
            # CATEGORIA
            $codCat = $s.Value.cat
            $sql = "INSERT INTO [saCatArticulo] ([co_cat],[cat_des],[movil],[co_us_in],[co_sucu_in],[fe_us_in],[rowguid]) VALUES " +
                   "('$codCat', '$($parts[1])', 0, '$coUsIn', '$coSucuIn', $fe, '$([guid]::NewGuid())')"
            [void](EjecutarNoQuery $sql)
        }
    }

    # 2) UNIDADES
    $desUni = @{ UNI = "UNIDAD"; KG = "KILOGRAMO"; MT = "METRO" }
    foreach ($u in $unidadesReq.Keys) {
        $existe = EjecutarEscalar "SELECT COUNT(*) FROM saUnidad WHERE LTRIM(RTRIM(co_uni)) = '$u'"
        if ([int]$existe -eq 0) {
            $codU = Rango6 $u
            $descU = $desUni[$u]; if (-not $descU) { $descU = $u }
            $sql = "INSERT INTO [saUnidad] ([co_uni],[des_uni],[co_us_in],[co_sucu_in],[fe_us_in],[rowguid]) VALUES " +
                   "('$codU', '$descU', '$coUsIn', '$coSucuIn', $fe, '$([guid]::NewGuid())')"
            [void](EjecutarNoQuery $sql)
        }
    }

    # 3-6) ARTICULOS + PRECIO + UNIDAD + STOCK
    $n = 0
    foreach ($f in $filas) {
        $n++
        if ($n % 500 -eq 0) { Write-Host ("  ... {0}/{1}" -f $n, $filas.Count) }
        $codigo = $f.codigo.Trim().ToUpper()
        if ($articulosBD.ContainsKey($codigo)) { $saltados++; continue }

        $lin = $f.linea.Trim().ToUpper()
        $sub = $f.sublinea.Trim().ToUpper()
        $codLin = $lineasPlan[$lin].cod
        $codSub = $lineasPlan[$lin].subs["$lin|$sub"].cod
        $codCat = $lineasPlan[$lin].subs["$lin|$sub"].cat

        $desc = $f.descripcion.Trim().Replace("'", "''")
        $trunco = $false
        if ($desc.Length -gt $longArtDes) { $desc = $desc.Substring(0, $longArtDes); $trunco = $true }

        $coArt = (($codigo) + (' ' * 30)).Substring(0, 30)
        $precio = ("{0:0.00000}" -f [double]$f.precio)
        $costo = ("{0:0.00000}" -f [double]$f.costo)
        $stock = ("{0:0.00000}" -f [double]$f.stock)
        $stockMin = ("{0:0.00000}" -f [double]$f.stock_minimo)
        $marca = $f.marca.Trim().Replace("'", "''")
        $ref = (($marca) + (' ' * 20)).Substring(0, [Math]::Min(20, $marca.Length))
        $unidad = $f.unidad.Trim()
        if ($unidad -eq "uds") { $unidad = "UNI" } elseif ($unidad -eq "kg") { $unidad = "KG" } elseif ($unidad -eq "mt") { $unidad = "MT" }
        $codUni = Rango6 $unidad

        $guid = [guid]::NewGuid().ToString()

        try {
            $sqlArt = "INSERT INTO [saArticulo] ([co_art],[fecha_reg],[art_des],[tipo],[anulado],[co_lin],[co_subl],[co_cat],[stock_min],[tipo_imp],[co_us_in],[co_sucu_in],[fe_us_in],[revisado],[trasnfe],[rowguid]) VALUES " +
                      "('$coArt',$fecReg, '$desc', 'V', 0, '$codLin', '$codSub', '$codCat', $stockMin, '$tipoImp', '$coUsIn', '$coSucuIn', $fe, NULL, NULL, '$guid')"
            [void](EjecutarNoQuery $sqlArt)

            $sqlPre = "INSERT INTO [saArtPrecio] ([co_art],[co_precio],[desde],[hasta],[co_alma],[monto],[co_us_in],[co_sucu_in],[fe_us_in],[rowguid]) VALUES " +
                      "('$coArt', '$coPrecio', $fe, NULL, '$coAlma', $precio, '$coUsIn', '$coSucuIn', $fe, '$([guid]::NewGuid())')"
            [void](EjecutarNoQuery $sqlPre)

            $sqlUni = "INSERT INTO [saArtUnidad] ([co_art],[co_uni],[relacion],[equivalencia],[uso_venta],[uso_compra],[uni_principal],[uso_principal],[uni_secundaria],[uso_secundaria],[co_us_in],[co_sucu_in],[fe_us_in],[rowguid]) VALUES " +
                      "('$coArt', '$codUni', 0, 1.00000, 1, 1, 1, 1, 0, 0, '$coUsIn', '$coSucuIn', $fe, '$([guid]::NewGuid())')"
            [void](EjecutarNoQuery $sqlUni)

            $sqlStk = "INSERT INTO [saStockAlmacen] ([co_alma],[co_art],[tipo],[stock]) VALUES " +
                      "('$coAlma', '$coArt', 'ACT ', $stock)"
            [void](EjecutarNoQuery $sqlStk)

            $insertados++
            $detalle += [PSCustomObject]@{ codigo = $codigo; co_art = $coArt.Trim(); resultado = "insertado"; trunco_desc = $trunco }
        } catch {
            $errores++
            $log += ("ERROR {0}: {1}" -f $codigo, $_.Exception.Message)
            $detalle += [PSCustomObject]@{ codigo = $codigo; co_art = $coArt.Trim(); resultado = "error"; trunco_desc = $trunco }
        }
    }

    if ($errores -eq 0) {
        $trans.Commit()
        Write-Host ""
        Write-Host "TRANSACCION CONFIRMADA (COMMIT). Todo el catalogo quedo guardado."
    } else {
        $trans.Rollback()
        Write-Host ""
        Write-Host "HAY ERRORES ($errores): se REVIRTIO todo (ROLLBACK). Nada se guardo."
        Write-Host "Revisa salida/log_carga.txt y corrige antes de reintentar."
    }
} catch {
    try { $trans.Rollback() } catch {}
    Write-Host "EXCEPCION GENERAL: se REVIRTIO todo. $($_.Exception.Message)"
    $errores++
}
$conn.Close()

$detalle | Export-Csv -LiteralPath (Join-Path $salida "resultado_carga.csv") -NoTypeInformation -Encoding UTF8
$log | Set-Content -LiteralPath (Join-Path $salida "log_carga.txt") -Encoding UTF8

Write-Host ""
Write-Host ("RESUMEN: insertados={0} saltados={1} errores={2}" -f $insertados, $saltados, $errores)
Write-Host "Detalle: salida/resultado_carga.csv"
if ($errores -eq 0 -and $insertados -gt 0) {
    Write-Host ""
    Write-Host "DESPUES DE CARGAR, DENTRO DE PROFIT PLUS:"
    Write-Host "  1. Mantenimiento -> Validar consistencia."
    Write-Host "  2. Mantenimiento -> Actualizar tablas locales (si aplica)."
    Write-Host "  3. Tablas -> Articulos: revisa una muestra del catalogo."
    Write-Host "  4. Los PRECIOS quedaron en la lista '$coPrecio' (co_precio)."
    Write-Host "  5. El COSTO no se carga en este paso (se maneja con compras o"
    Write-Host "     Ajuste de precio/costo). Los datos de costo estan en"
    Write-Host "     salida/refrimar_reporte_revision.csv."
}
