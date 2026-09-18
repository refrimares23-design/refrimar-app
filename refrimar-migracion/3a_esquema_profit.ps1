# ============================================================
# REFRIMAR -> MIGRACION A PROFIT PLUS 2KDOCE
# Paso 3a: Volcar el esquema (tablas y columnas) del SQL
#          Server de Profit Plus 2KDoce a CSV.
# ------------------------------------------------------------
# Uso con usuario SQL:
#   powershell -ExecutionPolicy Bypass -File 3a_esquema_profit.ps1 `
#     -Servidor "127.0.0.1\SQLEXPRESS" -BaseDatos "EMPRESA001" `
#     -Usuario "sa" -Password "xxxx"
# Uso con autenticacion de Windows (sin -Usuario):
#   powershell -ExecutionPolicy Bypass -File 3a_esquema_profit.ps1 `
#     -Servidor "127.0.0.1\SQLEXPRESS" -BaseDatos "EMPRESA001"
# O bien edita config.json y ejecuta sin parametros.
#
# NO MODIFICA NADA: solo consulta INFORMATION_SCHEMA.
# Genera: salida/2kdoce_tablas.csv y salida/2kdoce_columnas.csv
# ============================================================

param(
    [string]$Servidor = "",
    [string]$BaseDatos = "",
    [string]$Usuario = "",
    [string]$Password = ""
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$salida = Join-Path $scriptDir "salida"
$configPath = Join-Path $scriptDir "config.json"

# ---- Cargar parametros desde config.json si faltan ----
if (-not $Servidor) {
    if (Test-Path -LiteralPath $configPath) {
        $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $Servidor = $cfg.Profit2K.Servidor
        $BaseDatos = $cfg.Profit2K.BaseDatos
        $Usuario = $cfg.Profit2K.Usuario
        $Password = $cfg.Profit2K.Password
    }
}
if (-not $Servidor -or -not $BaseDatos) {
    Write-Host ""
    Write-Host "Faltan datos de conexion. Crea el archivo config.json con este formato:"
    Write-Host "  {"
    Write-Host '    "Profit2K": {'
    Write-Host '      "Servidor": "127.0.0.1\\SQLEXPRESS",'
    Write-Host '      "BaseDatos": "EMPRESA001",'
    Write-Host '      "Usuario": "sa",'
    Write-Host '      "Password": "clave"'
    Write-Host "    }"
    Write-Host "  }"
    Write-Host "(Si usas autenticacion de Windows, deja Usuario y Password vacios)."
    exit 1
}

Add-Type -AssemblyName System.Data

$connString = ""
if ($Usuario) {
    $connString = "Server=$Servidor;Database=$BaseDatos;User Id=$Usuario;Password=$Password;TrustServerCertificate=True"
} else {
    $connString = "Server=$Servidor;Database=$BaseDatos;Integrated Security=True;TrustServerCertificate=True"
}

New-Item -ItemType Directory -Path $salida -Force | Out-Null

try {
    $conn = New-Object System.Data.SqlClient.SqlConnection $connString
    $conn.Open()
    Write-Host ""
    Write-Host ("Conectado OK a {0} / {1}" -f $Servidor, $BaseDatos)

    $qTablas = @"
SELECT TABLE_NAME, TABLE_TYPE
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME
"@

    $qColumnas = @"
SELECT TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, DATA_TYPE,
       CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE, COLUMN_DEFAULT
FROM INFORMATION_SCHEMA.COLUMNS
ORDER BY TABLE_NAME, ORDINAL_POSITION
"@

    $da = New-Object System.Data.SqlClient.SqlDataAdapter $qTablas, $conn
    $dtTablas = New-Object System.Data.DataTable
    [void]$da.Fill($dtTablas)

    $da2 = New-Object System.Data.SqlClient.SqlDataAdapter $qColumnas, $conn
    $dtCols = New-Object System.Data.DataTable
    [void]$da2.Fill($dtCols)

    $conn.Close()

    $pathTablas = Join-Path $salida "2kdoce_tablas.csv"
    $dtTablas | ConvertTo-Csv -NoTypeInformation | Set-Content -LiteralPath $pathTablas -Encoding UTF8

    $pathCols = Join-Path $salida "2kdoce_columnas.csv"
    $dtCols | ConvertTo-Csv -NoTypeInformation | Set-Content -LiteralPath $pathCols -Encoding UTF8

    Write-Host ("Tablas  : {0}" -f $dtTablas.Rows.Count)
    Write-Host ("Columnas: {0}" -f $dtCols.Rows.Count)
    Write-Host ""
    Write-Host "Archivos generados:"
    Write-Host "  $pathTablas"
    Write-Host "  $pathCols"
    Write-Host ""

    $patronArticulos = '(art|artic|produ|item|exist|invent|linea|line|subline|precio|price|codig)'
    Write-Host "Candidatos a tabla de articulos (revisar en 2kdoce_tablas.csv):"
    $dtTablas | Select-Object -ExpandProperty TABLE_NAME |
        Where-Object { $_ -match $patronArticulos } |
        ForEach-Object { Write-Host "  - $_" }

} catch {
    Write-Host ""
    Write-Host "ERROR de conexion: $($_.Exception.Message)"
    Write-Host ""
    Write-Host "Comprueba:"
    Write-Host "  1. El servidor/instancia (ej: localhost, 127.0.0.1\SQLEXPRESS, MAQUINA\INSTANCIA)."
    Write-Host "  2. El nombre de la base de datos (esta en el archivo de conexion del Paso 3)."
    Write-Host "  3. Usuario/clave (o usa autenticacion de Windows quitando -Usuario)."
    Write-Host "  4. Que el servicio 'SQL Server (SQLEXPRESS)' este iniciado (services.msc)."
}
