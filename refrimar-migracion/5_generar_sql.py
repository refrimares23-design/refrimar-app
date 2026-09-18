# -*- coding: utf-8 -*-
# ============================================================
# REFRIMAR -> MIGRACION A PROFIT PLUS 2KDOCE
# Paso 5: Generar un archivo .sql autocontenido a partir del
#         catalogo normalizado (salida/refrimar_normalizado.csv).
#
# El .sql resultante se abre en SQL Server Management Studio
# (en el servidor donde esta la base de Profit Plus) y se
# ejecuta ahi. NO necesita conexion desde esta PC.
#
# Uso:
#   python 5_generar_sql.py
# Salida:
#   salida/carga_refrimar_2kdoce.sql
# ============================================================

import csv
import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
SALIDA = os.path.join(AQUI, "salida")
CSV_IN = os.path.join(SALIDA, "refrimar_normalizado.csv")
SQL_OUT = os.path.join(SALIDA, "carga_refrimar_2kdoce.sql")

LOTE_VALUES = 900  # limite SQL Server: 1000 constructores por INSERT


def esc(texto):
    """Escape para literal SQL: doblar comillas simples y limpiar saltos."""
    if texto is None:
        return ""
    return texto.replace("'", "''").replace("\r", " ").replace("\n", " ").strip()


def numero(val):
    """Normaliza un numero a decimal con 5 decimales ('' -> 0)."""
    try:
        return "{:.5f}".format(float(val))
    except (TypeError, ValueError):
        return "0.00000"


def sql_literal(val):
    return "'" + esc(val) + "'"


def main():
    if not os.path.exists(CSV_IN):
        print("No existe %s. Corre antes 1_extraer_supabase.py y 2_normalizar.py" % CSV_IN)
        sys.exit(1)

    with open(CSV_IN, encoding="utf-8-sig", newline="") as fh:
        filas = list(csv.DictReader(fh))

    print("Leyendo %d articulos de %s" % (len(filas), CSV_IN))

    if not filas:
        print("El CSV esta vacio.")
        sys.exit(1)

    renglones = []
    unidades_set = set()

    for f in filas:
        codigo = f["codigo"].strip()
        desc = esc(f["descripcion"])
        linea = f["linea"].strip()
        sublinea = f["sublinea"].strip()
        unidad = f["unidad"].strip()
        if unidad == "uds":
            unidad = "UNI"
        elif unidad == "kg":
            unidad = "KG"
        elif unidad == "mt":
            unidad = "MT"
        unidades_set.add(unidad)
        costo = numero(f["costo"])
        precio = numero(f["precio"])
        stock = numero(f["stock"])
        stock_min = numero(f["stock_minimo"])
        renglones.append(
            "("
            + ", ".join(
                [
                    sql_literal(codigo),
                    sql_literal(desc),
                    sql_literal(linea),
                    sql_literal(sublinea),
                    costo,
                    precio,
                    stock,
                    stock_min,
                    sql_literal(unidad),
                ]
            )
            + ")"
        )

    lineas_unicas = sorted({f["linea"].strip() for f in filas})
    sub_unicas = sorted({(f["linea"].strip(), f["sublinea"].strip()) for f in filas})

    print("Lineas: %d | Sublineas: %d | Unidades: %s" % (
        len(lineas_unicas), len(sub_unicas), ", ".join(sorted(unidades_set))))
    print("Generando %s ..." % SQL_OUT)

    # ---------- Cuerpo de INSERTs por lotes ----------
    partes = []
    for i in range(0, len(renglones), LOTE_VALUES):
        lote = renglones[i : i + LOTE_VALUES]
        partes.append("INSERT INTO #cata \n"
                      "    (codigo, descripcion, linea, sublinea, costo, precio, stock, stock_minimo, unidad)\n"
                      "VALUES\n    " + ",\n    ".join(lote) + ";")
    cuerpo_inserts = "\n\n".join(partes)

    requeridas = [
        ("saArticulo", "co_art"), ("saArticulo", "fecha_reg"), ("saArticulo", "art_des"),
        ("saArticulo", "tipo"), ("saArticulo", "anulado"), ("saArticulo", "co_lin"),
        ("saArticulo", "co_subl"), ("saArticulo", "co_cat"), ("saArticulo", "stock_min"),
        ("saArticulo", "tipo_imp"), ("saArticulo", "co_us_in"), ("saArticulo", "co_sucu_in"),
        ("saArticulo", "fe_us_in"), ("saArticulo", "revisado"), ("saArticulo", "trasnfe"),
        ("saArticulo", "rowguid"),
        ("saArtPrecio", "co_art"), ("saArtPrecio", "co_precio"), ("saArtPrecio", "desde"),
        ("saArtPrecio", "hasta"), ("saArtPrecio", "co_alma"), ("saArtPrecio", "monto"),
        ("saArtPrecio", "co_us_in"), ("saArtPrecio", "co_sucu_in"), ("saArtPrecio", "fe_us_in"),
        ("saArtPrecio", "rowguid"),
        ("saArtUnidad", "co_art"), ("saArtUnidad", "co_uni"), ("saArtUnidad", "relacion"),
        ("saArtUnidad", "equivalencia"), ("saArtUnidad", "uso_venta"), ("saArtUnidad", "uso_compra"),
        ("saArtUnidad", "uni_principal"), ("saArtUnidad", "uso_principal"),
        ("saArtUnidad", "uni_secundaria"), ("saArtUnidad", "uso_secundaria"),
        ("saArtUnidad", "co_us_in"), ("saArtUnidad", "co_sucu_in"), ("saArtUnidad", "fe_us_in"),
        ("saArtUnidad", "rowguid"),
        ("saStockAlmacen", "co_alma"), ("saStockAlmacen", "co_art"),
        ("saStockAlmacen", "tipo"), ("saStockAlmacen", "stock"),
        ("saLineaArticulo", "co_lin"), ("saLineaArticulo", "lin_des"), ("saLineaArticulo", "va"),
        ("saLineaArticulo", "movil"), ("saLineaArticulo", "co_us_in"),
        ("saLineaArticulo", "co_sucu_in"), ("saLineaArticulo", "fe_us_in"),
        ("saLineaArticulo", "rowguid"),
        ("saSubLinea", "co_lin"), ("saSubLinea", "co_subl"), ("saSubLinea", "subl_des"),
        ("saSubLinea", "movil"), ("saSubLinea", "co_us_in"), ("saSubLinea", "co_sucu_in"),
        ("saSubLinea", "fe_us_in"), ("saSubLinea", "rowguid"),
        ("saCatArticulo", "co_cat"), ("saCatArticulo", "cat_des"), ("saCatArticulo", "movil"),
        ("saCatArticulo", "co_us_in"), ("saCatArticulo", "co_sucu_in"),
        ("saCatArticulo", "fe_us_in"), ("saCatArticulo", "rowguid"),
        ("saUnidad", "co_uni"), ("saUnidad", "des_uni"), ("saUnidad", "co_us_in"),
        ("saUnidad", "co_sucu_in"), ("saUnidad", "fe_us_in"), ("saUnidad", "rowguid"),
    ]
    req_values = ",\n        ".join("('{0}', '{1}')".format(t, c) for t, c in requeridas)

    with open(SQL_OUT, "w", encoding="utf-8-sig", newline="\n") as fh:
        fh.write("""/* ================================================================
 * REFRIMAR OS -> PROFIT PLUS ADMINISTRATIVO 2KDOCE
 * Carga del catalogo web (refrimar-app) en la base de Profit Plus.
 *
 * COMO USAR (en el servidor DESKTOP-NTF3LQP):
 *   1. HAZ UN BACKUP de la base primero:
 *        - Herramienta de Administracion -> Mantenimiento -> Backup
 *        (o SSMS -> clic derecho en la base -> Tasks -> Back Up...)
 *   2. Abre este archivo en SQL Server Management Studio (SSMS).
 *      Si las letras tildadas se ven raras, vuelve a abrir con
 *      File -> Open -> archivo, codificacion UTF-8.
 *   3. En la barra de herramientas elige la base de datos de la
 *      empresa (NO 'master'). Si no aparece la lista, ejecuta con
 *      sqlcmd:  sqlcmd -S SERVICIO\\INSTANCIA -d NOMBRE_BASE -E -b -i carga_refrimar_2kdoce.sql
 *   4. Ejecuta (F5). Todo corre en UNA transaccion: si algo falla,
 *      se REVIERTE todo y no queda nada a medias.
 *
 * Que hace:
 *   - Crea LINEAS, SUBLINEAS, CATEGORIAS y UNIDADES que falten.
 *   - Inserta ARTICULOS, PRECIOS (saArtPrecio), UNIDAD por articulo
 *     (saArtUnidad) y STOCK inicial (saStockAlmacen, tipo 'ACT ').
 *   - Solo inserta los codigos que NO existan ya (idempotente).
 *   - El COSTO no se carga en este script (se maneja via compras o
 *     ajuste de precio/costo). Los datos de costo estan en
 *     salida/refrimar_reporte_revision.csv.
 *   - Las descripciones mayores al largo de art_des se truncan.
 * ================================================================ */
SET NOCOUNT ON;
GO

PRINT 'REF RIMAR: iniciando carga (solo se mostrara si es UTF-8 correcto)';

/* ---------- 0. PRE-CHECK: tablas y columnas requeridas ---------- */
IF DB_ID() IS NULL OR DB_NAME() = 'master'
BEGIN
    RAISERROR('Estas conectado a la base [master]. Selecciona la base de la empresa de Profit Plus y vuelve a ejecutar.', 16, 1);
    RETURN;
END

DECLARE @faltantes NVARCHAR(MAX) = '';
WITH req(T, C) AS (
    SELECT * FROM (VALUES
        %(req_values)s
    ) AS r(T, C)
)
SELECT @faltantes = @faltantes + '[' + req.T + '.' + req.C + '] '
FROM req
WHERE NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS c
                  WHERE c.TABLE_NAME = req.T AND c.COLUMN_NAME = req.C);

IF @faltantes <> ''
BEGIN
    RAISERROR('Faltan columnas en esta base (seguro que es la de Profit?): %%s. NO se modifico nada.', 16, 1, @faltantes);
    RETURN;
END
PRINT 'OK: tablas y columnas requeridas presentes.';
GO

/* ---------- 1. STAGING: catalogo temporal ---------- */
IF OBJECT_ID('tempdb..#cata') IS NOT NULL DROP TABLE #cata;
CREATE TABLE #cata (
    codigo        VARCHAR(50),
    descripcion   NVARCHAR(400),
    linea         NVARCHAR(100),
    sublinea      NVARCHAR(100),
    costo         DECIMAL(18,5),
    precio        DECIMAL(18,5),
    stock         DECIMAL(18,5),
    stock_minimo  DECIMAL(18,5),
    unidad        VARCHAR(6),
    co_art AS (LEFT(RTRIM(codigo), 30) + SPACE(30 - LEN(LEFT(RTRIM(codigo), 30))))
);
PRINT 'OK: tabla temporal creada.';
GO

%(cuerpo_inserts)s

PRINT 'OK: catalogo cargado en memoria (%(n)s registros).';
GO

/* ---------- 2. REFERENCIAS desde la base real ---------- */
DECLARE @co_sucu_in CHAR(6) = '01    ';
DECLARE @co_us_in   CHAR(6) = '001   ';
DECLARE @co_precio  CHAR(6) = '01    ';
DECLARE @co_alma    CHAR(6) = '001   ';
DECLARE @tipo_imp   VARCHAR(1) = '1';
DECLARE @artDesLen  INT = 60;
DECLARE @fecha_reg  VARCHAR(8);
DECLARE @fecha_aud  VARCHAR(19);

SELECT TOP 1 @co_sucu_in = co_sucu_in FROM saArticulo WHERE co_sucu_in IS NOT NULL;
SELECT TOP 1 @co_us_in   = co_us_in   FROM saArticulo WHERE co_us_in   IS NOT NULL;
SELECT TOP 1 @co_precio  = co_precio  FROM saTipoPrecio WHERE co_precio IS NOT NULL;
SELECT TOP 1 @co_alma    = co_alma    FROM saAlmacen WHERE co_alma IS NOT NULL;
SELECT TOP 1 @tipo_imp   = tipo_imp   FROM saArticulo WHERE tipo_imp IS NOT NULL;

SELECT @artDesLen = ISNULL(CHARACTER_MAXIMUM_LENGTH, 60)
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'saArticulo' AND COLUMN_NAME = 'art_des';

SET @fecha_reg = CONVERT(VARCHAR(8), GETDATE(), 112);        -- yyyyMMdd
SET @fecha_aud = CONVERT(VARCHAR(19), GETDATE(), 120);       -- yyyyMMdd HH:mm:ss

PRINT 'OK: referencias resueltas.';
GO

/* ---------- 3. MAPEO de lineas / sublineas / categorias ---------- */
IF OBJECT_ID('tempdb..#lin') IS NOT NULL DROP TABLE #lin;
CREATE TABLE #lin (linea NVARCHAR(100) NOT NULL PRIMARY KEY, co_lin CHAR(6) NULL);

INSERT INTO #lin (linea)
SELECT DISTINCT c.linea
FROM #cata c
WHERE NOT EXISTS (SELECT 1 FROM saLineaArticulo l WHERE LTRIM(RTRIM(l.co_lin)) = c.linea);

DECLARE @nLin INT = 1, @lin NVARCHAR(100), @codLin CHAR(6), @taken BIT;
WHILE EXISTS (SELECT 1 FROM #lin WHERE co_lin IS NULL)
BEGIN
    SELECT TOP 1 @lin = linea FROM #lin WHERE co_lin IS NULL ORDER BY linea;
    SET @taken = 1;
    WHILE @taken = 1
    BEGIN
        SET @codLin = RIGHT('00' + CAST(@nLin AS VARCHAR(2)), 2) + SPACE(4);
        SET @taken = CASE
            WHEN EXISTS (SELECT 1 FROM saLineaArticulo WHERE co_lin = @codLin) THEN 1
            WHEN EXISTS (SELECT 1 FROM #lin WHERE co_lin = @codLin) THEN 1
            ELSE 0 END;
        IF @taken = 1 SET @nLin = @nLin + 1;
    END;
    UPDATE #lin SET co_lin = @codLin WHERE linea = @lin;
    SET @nLin = @nLin + 1;
END;

IF OBJECT_ID('tempdb..#sub') IS NOT NULL DROP TABLE #sub;
CREATE TABLE #sub (
    linea NVARCHAR(100) NOT NULL, sublinea NVARCHAR(100) NOT NULL,
    co_lin CHAR(6) NULL, co_subl CHAR(6) NULL, co_cat CHAR(6) NULL,
    PRIMARY KEY (linea, sublinea));

INSERT INTO #sub (linea, sublinea)
SELECT DISTINCT linea, sublinea FROM #cata;

UPDATE s SET co_lin = l.co_lin FROM #sub s JOIN #lin l ON l.linea = s.linea;
UPDATE s SET co_lin = (SELECT TOP 1 l.co_lin FROM saLineaArticulo l WHERE LTRIM(RTRIM(l.co_lin)) = s.linea)
FROM #sub s WHERE s.co_lin IS NULL;

DECLARE @subl NVARCHAR(100), @nSub INT, @codSubl CHAR(6), @linCod CHAR(6), @cat CHAR(6);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT linea FROM #sub ORDER BY linea;
OPEN cur;
FETCH NEXT FROM cur INTO @lin;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @linCod = co_lin FROM #sub WHERE linea = @lin;
    SET @nSub = 1;
    DECLARE cur2 CURSOR LOCAL FAST_FORWARD FOR SELECT sublinea FROM #sub WHERE linea = @lin ORDER BY sublinea;
    OPEN cur2;
    FETCH NEXT FROM cur2 INTO @subl;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @taken = 1;
        WHILE @taken = 1
        BEGIN
            SET @codSubl = RIGHT('00' + CAST(@nSub AS VARCHAR(2)), 2) + SPACE(4);
            SET @taken = CASE
                WHEN EXISTS (SELECT 1 FROM saSubLinea WHERE co_lin = @linCod AND co_subl = @codSubl) THEN 1
                WHEN EXISTS (SELECT 1 FROM #sub WHERE co_lin = @linCod AND co_subl = @codSubl) THEN 1
                ELSE 0 END;
            IF @taken = 1 SET @nSub = @nSub + 1;
        END;
        SET @cat = LTRIM(RTRIM(@linCod)) + RIGHT('00' + CAST(@nSub AS VARCHAR(2)), 2) + SPACE(2);
        UPDATE #sub SET co_subl = @codSubl, co_cat = @cat WHERE linea = @lin AND sublinea = @subl;
        SET @nSub = @nSub + 1;
        FETCH NEXT FROM cur2 INTO @subl;
    END;
    CLOSE cur2; DEALLOCATE cur2;
    FETCH NEXT FROM cur INTO @lin;
END;
CLOSE cur; DEALLOCATE cur;
GO

PRINT 'OK: mapeo de lineas/sublineas listo.';
GO

/* ---------- 4. UNIDADES a crear ---------- */
IF OBJECT_ID('tempdb..#uni') IS NOT NULL DROP TABLE #uni;
CREATE TABLE #uni (unidad CHAR(6) NOT NULL PRIMARY KEY);
INSERT INTO #uni SELECT DISTINCT unidad FROM #cata;
DELETE FROM #uni
WHERE EXISTS (SELECT 1 FROM saUnidad u WHERE LTRIM(RTRIM(u.co_uni)) = LTRIM(RTRIM(unidad)));
GO

/* ================================================================
 * 5. CARGA REAL en UNA transaccion (todo o nada)
 * ================================================================ */
BEGIN TRY
    BEGIN TRANSACTION;

    -- LINEAS
    INSERT INTO saLineaArticulo (co_lin, lin_des, va, movil, co_us_in, co_sucu_in, fe_us_in, rowguid)
    SELECT co_lin, linea, 0, 0, @co_us_in, @co_sucu_in, @fecha_aud, NEWID() FROM #lin;

    -- SUBLINEAS
    INSERT INTO saSubLinea (co_lin, co_subl, subl_des, movil, co_us_in, co_sucu_in, fe_us_in, rowguid)
    SELECT co_lin, co_subl, sublinea, 0, @co_us_in, @co_sucu_in, @fecha_aud, NEWID() FROM #sub;

    -- CATEGORIAS
    INSERT INTO saCatArticulo (co_cat, cat_des, movil, co_us_in, co_sucu_in, fe_us_in, rowguid)
    SELECT co_cat, sublinea, 0, @co_us_in, @co_sucu_in, @fecha_aud, NEWID()
    FROM #sub s
    WHERE NOT EXISTS (SELECT 1 FROM saCatArticulo c WHERE c.co_cat = s.co_cat);

    -- UNIDADES
    INSERT INTO saUnidad (co_uni, des_uni, co_us_in, co_sucu_in, fe_us_in, rowguid)
    SELECT u.unidad,
           CASE LTRIM(RTRIM(u.unidad))
                WHEN 'UNI' THEN 'UNIDAD'
                WHEN 'KG'  THEN 'KILOGRAMO'
                WHEN 'MT'  THEN 'METRO'
                ELSE LTRIM(RTRIM(u.unidad)) END,
           @co_us_in, @co_sucu_in, @fecha_aud, NEWID()
    FROM #uni u;

    -- ARTICULOS (solo los que no existen)
    INSERT INTO saArticulo
        (co_art, fecha_reg, art_des, tipo, anulado, co_lin, co_subl, co_cat,
         stock_min, tipo_imp, co_us_in, co_sucu_in, fe_us_in, revisado, trasnfe, rowguid)
    SELECT c.co_art,
           @fecha_reg,
           LEFT(RTRIM(c.descripcion), @artDesLen),
           'V', 0,
           s.co_lin, s.co_subl, s.co_cat,
           c.stock_minimo,
           @tipo_imp, @co_us_in, @co_sucu_in, @fecha_aud, NULL, NULL, NEWID()
    FROM #cata c
    JOIN #sub s ON s.linea = c.linea AND s.sublinea = c.sublinea
    WHERE NOT EXISTS (SELECT 1 FROM saArticulo a WHERE a.co_art = c.co_art);
    DECLARE @nArt INT = @@ROWCOUNT;

    -- PRECIOS
    INSERT INTO saArtPrecio
        (co_art, co_precio, desde, hasta, co_alma, monto,
         co_us_in, co_sucu_in, fe_us_in, rowguid)
    SELECT c.co_art, @co_precio, @fecha_aud, NULL, @co_alma, c.precio,
           @co_us_in, @co_sucu_in, @fecha_aud, NEWID()
    FROM #cata c
    WHERE NOT EXISTS (SELECT 1 FROM saArticulo a WHERE a.co_art = c.co_art);

    -- UNIDAD por articulo
    INSERT INTO saArtUnidad
        (co_art, co_uni, relacion, equivalencia, uso_venta, uso_compra,
         uni_principal, uso_principal, uni_secundaria, uso_secundaria,
         co_us_in, co_sucu_in, fe_us_in, rowguid)
    SELECT c.co_art, c.unidad, 0, 1.00000, 1, 1, 1, 1, 0, 0,
           @co_us_in, @co_sucu_in, @fecha_aud, NEWID()
    FROM #cata c
    WHERE NOT EXISTS (SELECT 1 FROM saArticulo a WHERE a.co_art = c.co_art);

    -- STOCK inicial (tipo 'ACT ')
    INSERT INTO saStockAlmacen (co_alma, co_art, tipo, stock)
    SELECT @co_alma, c.co_art, 'ACT ', c.stock
    FROM #cata c
    WHERE NOT EXISTS (SELECT 1 FROM saArticulo a WHERE a.co_art = c.co_art);

    COMMIT TRANSACTION;

    DECLARE @nTotal INT = (SELECT COUNT(*) FROM #cata);
    DECLARE @nSobrantes INT = (SELECT COUNT(*) FROM #cata c
        WHERE EXISTS (SELECT 1 FROM saArticulo a WHERE a.co_art = c.co_art));
    DECLARE @nPrecioCero INT = (SELECT COUNT(*) FROM #cata WHERE precio = 0);

    PRINT '';
    PRINT '====================================================';
    PRINT ' CARGA FINALIZADA CORRECTAMENTE (COMMIT)';
    PRINT '====================================================';
    PRINT 'Articulos en el archivo   : ' + CAST(@nTotal AS VARCHAR(10));
    PRINT 'Articulos ya existentes   : ' + CAST(@nSobrantes AS VARCHAR(10));
    PRINT 'Articulos insertados      : ' + CAST(@nArt AS VARCHAR(10));
    PRINT 'Lineas nuevas             : ' + CAST((SELECT COUNT(*) FROM #lin) AS VARCHAR(10));
    PRINT 'Sublineas nuevas          : ' + CAST((SELECT COUNT(*) FROM #sub) AS VARCHAR(10));
    PRINT 'Unidades nuevas           : ' + CAST((SELECT COUNT(*) FROM #uni) AS VARCHAR(10));
    PRINT 'Articulos con PRECIO 0    : ' + CAST(@nPrecioCero AS VARCHAR(10)) + ' (revisar)';
    PRINT '  (los precios 0 se cargaron como 0; luego se ajustan)';
    PRINT '  (el COSTO no se cargo; se maneja via compras/ajustes)';
    PRINT '====================================================';
    PRINT 'DENTRO DE PROFIT PLUS AHORA:';
    PRINT '  1. Mantenimiento -> Validar consistencia.';
    PRINT '  2. Tablas -> Articulos: revisa una muestra.';
    PRINT '  3. Los precios quedaron en la lista de precios del co_precio';
    PRINT '     de la base.';
    PRINT '====================================================';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '';
    PRINT 'ERROR: se REVIRTIO TODO (ROLLBACK). Nada se guardo.';
    PRINT 'Mensaje: ' + ERROR_MESSAGE();
    PRINT 'Linea:   ' + CAST(ERROR_LINE() AS VARCHAR(10));
    PRINT 'Revisa el error, corrige y vuelve a ejecutar.';
    THROW;
END CATCH;
GO
""" % {
        "req_values": req_values,
        "cuerpo_inserts": cuerpo_inserts,
        "n": len(filas),
    })

    print("Generado OK: %s" % SQL_OUT)
    print("Articulos: %d | Renglones INSERT: %d lote(s) de %d" % (
        len(filas), (len(filas) + LOTE_VALUES - 1) // LOTE_VALUES, LOTE_VALUES))
    print("Lineas: %d | Sublineas: %d | Unidades: %s" % (
        len(lineas_unicas), len(sub_unicas), ", ".join(sorted(unidades_set))))


if __name__ == "__main__":
    main()
