# ============================================================
# REFRIMAR -> MIGRACION A PROFIT PLUS 2KDOCE
# Paso 3: Descubrir la instalacion de Profit Plus y su
#         configuracion de conexion a SQL Server.
# ------------------------------------------------------------
# Uso:  powershell -ExecutionPolicy Bypass -File 3_descubrir_conexion.ps1
#       (opcional)  -Ruta "C:\carpeta\donde\esta\profit"
# No modifica nada: solo lee archivos y procesos.
# ============================================================

param(
    [string]$Ruta = ""
)

$patrones = @(
    '(?i)(data\s*source|server|initial\s*catalog|database|user\s*id|uid=|pwd=|password|integrated\s*security)'
)

function Buscar-CarpetaProfit {
    $candidatas = @(
        "C:\Profit", "C:\Profit Plus", "C:\ProfitPlus",
        "C:\Archivos de programa\Softech", "C:\Program Files\Softech",
        "C:\Archivos de programa (x86)\Softech", "C:\Program Files (x86)\Softech",
        "C:\Profit Plus Administrativo", "C:\ProfitPlus2K",
        "$env:ProgramFiles\Profit Plus", "${env:ProgramFiles(x86)}\Profit Plus"
    )
    foreach ($c in $candidatas) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Buscar-CarpetaPorProceso {
    $proc = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'profit|administr|2kdoce' }
    if ($proc) {
        $ruta = ($proc | Select-Object -First 1).Path
        if ($ruta -and (Test-Path -LiteralPath $ruta)) {
            return Split-Path -Parent $ruta
        }
    }
    return $null
}

$carpeta = ""
if ($Ruta) {
    $carpeta = $Ruta
} else {
    $carpeta = Buscar-CarpetaPorProceso
    if (-not $carpeta) { $carpeta = Buscar-CarpetaProfit }
}

Write-Host ""
Write-Host "== PASO 3: Descubrimiento de conexion Profit Plus =="
Write-Host ""
if (-not $carpeta -or -not (Test-Path -LiteralPath $carpeta)) {
    Write-Host "No se encontro automaticamente la carpeta de instalacion de Profit Plus."
    Write-Host "Ejecuta de nuevo indicando la ruta:"
    Write-Host '  powershell -ExecutionPolicy Bypass -File 3_descubrir_conexion.ps1 -Ruta "C:\Profit Plus"'
    exit 1
}

Write-Host ("Carpeta de trabajo: {0}" -f $carpeta)
Write-Host ""

$archivos = Get-ChildItem -LiteralPath $carpeta -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -match '\.(ini|xml|config|cfg|txt|json|ini|prg)$' } |
    Select-Object -First 200

if (-not $archivos) {
    Write-Host "No se encontraron archivos de configuracion (*.ini, *.xml, *.config)."
} else {
    Write-Host "Archivos de configuracion encontrados: $($archivos.Count)"
    Write-Host ""
    $vistos = @{}
    foreach ($a in $archivos) {
        try {
            $contenido = Get-Content -LiteralPath $a.FullName -Raw -Encoding Default -ErrorAction Stop
        } catch { continue }
        foreach ($patron in $patrones) {
            $matches = [regex]::Matches($contenido, $patron)
            if ($matches.Count -gt 0) {
                $rel = $a.FullName.Substring($carpeta.Length)
                $lineas = [regex]::Split($contenido, "`r?`n")
                for ($i = 0; $i -lt $lineas.Count; $i++) {
                    if ($lineas[$i] -match $patron -and -not $vistos.ContainsKey(("$rel|$i"))) {
                        $vistos["$rel|$i"] = $true
                        Write-Host ("  [{0}] L{1}: {2}" -f $rel, ($i + 1), $lineas[$i].Trim())
                    }
                }
            }
        }
    }
}

Write-Host ""
Write-Host "Si el archivo de conexion no aparece arriba, revisa manualmente la carpeta:"
Write-Host "  $carpeta"
Write-Host "Busca archivos con nombres como: Profit.ini, BDServidor, Conexion, *.config, *.xml"
Write-Host ""
Write-Host "DATO CLAVE PARA EL SIGUIENTE PASO: anota el 'Data Source' (servidor/instancia SQL)"
Write-Host "y el 'Initial Catalog' (nombre de la base de datos de la empresa)."
