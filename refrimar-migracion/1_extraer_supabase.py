#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REFRIMAR -> MIGRACION A PROFIT PLUS 2KDOCE
Paso 1: Extraer el catalogo de productos desde Supabase (web) a CSV.

- Cero dependencias: solo libreria estandar de Python (urllib, json, csv).
- La clave "anon" es la misma que usa la propia aplicacion web en el navegador;
  aqui se usa para LECTURA de la tabla 'productos', con permisos RLS de SELECT
  que el proyecto ya concede a la app. No modifica NADA en Supabase.
- Pagina automaticamente todos los registros (Range headers).
- Salida:
    salida/refrimar_productos.csv   -> catalogo canonico (UTF-8 BOM)
    salida/resumen.json             -> estadisticas y alertas de calidad
"""

import csv
import json
import os
import sys
import urllib.request

SUPABASE_URL = "https://hjecifftqidqeswcpvwt.supabase.co"
SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhqZWNpZmZ0cWlkcWVzd2Nwdnd0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUxMDE0NzAsImV4cCI6MjEwMDY3NzQ3MH0.X0pqSe-CVjDgEVO2Cgd89pucXs-cfC7MbJIlx4hfKGM"
TABLA = "productos"
PAGINA = 1000

BASE = os.path.dirname(os.path.abspath(__file__))
SALIDA = os.path.join(BASE, "salida")


def api_get(url):
    req = urllib.request.Request(url)
    req.add_header("apikey", SUPABASE_ANON_KEY)
    req.add_header("Authorization", "Bearer " + SUPABASE_ANON_KEY)
    req.add_header("Accept", "application/json")
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = resp.read().decode("utf-8", errors="replace")
        return json.loads(body)


def extraer_todo():
    filas = []
    desde = 0
    total_estimado = None
    while True:
        url = (SUPABASE_URL + "/rest/v1/" + TABLA + "?select=*")
        req = urllib.request.Request(url)
        req.add_header("apikey", SUPABASE_ANON_KEY)
        req.add_header("Authorization", "Bearer " + SUPABASE_ANON_KEY)
        req.add_header("Accept", "application/json")
        req.add_header("Range", "%d-%d" % (desde, desde + PAGINA - 1))
        req.add_header("Prefer", "count=exact")
        with urllib.request.urlopen(req, timeout=90) as resp:
            chunk = json.loads(resp.read().decode("utf-8", errors="replace"))
            cr = resp.headers.get("Content-Range", "")
            if total_estimado is None and "/" in cr:
                total_estimado = int(cr.split("/")[1])
            print("  paginado desde %d -> %d registros (total: %s)" %
                  (desde, len(chunk), total_estimado or "?"))
            if not chunk:
                break
            filas.extend(chunk)
            desde += len(chunk)
            if total_estimado is not None and desde >= total_estimado:
                break
            if len(chunk) < PAGINA:
                break
    return filas


def normalizar(valor):
    if valor is None:
        return ""
    if isinstance(valor, (dict, list)):
        return json.dumps(valor, ensure_ascii=False)
    if isinstance(valor, bool):
        return "true" if valor else "false"
    return str(valor)


def main():
    os.makedirs(SALIDA, exist_ok=True)
    print("Conectando a Supabase: %s (%s)" % (SUPABASE_URL, TABLA))
    filas = extraer_todo()

    if not filas:
        print("No se encontro ningun registro. Abortando.")
        sys.exit(1)

    columnas = list(filas[0].keys())
    print("Columnas detectadas: %s" % ", ".join(columnas))

    # ---- Estadisticas de calidad ----
    codigos = [f.get("codigo", "") for f in filas]
    duplicados = {}
    vistos = set()
    for c in codigos:
        c = (c or "").strip().upper()
        if not c:
            continue
        if c in vistos:
            duplicados[c] = duplicados.get(c, 1) + 1
        else:
            vistos.add(c)

    sin_codigo = sum(1 for c in codigos if not (c or "").strip())
    sin_desc = sum(1 for f in filas if not (f.get("descripcion") or "").strip())
    sin_costo = sum(1 for f in filas if f.get("costo") is None)
    sin_precio = sum(1 for f in filas if f.get("precio") is None)
    stock_negativo = sum(1 for f in filas if (f.get("stock") or 0) < 0)

    resumen = {
        "total_productos": len(filas),
        "columna_codigos_duplicados": len(duplicados),
        "detalle_codigos_duplicados": dict(sorted(duplicados.items())[:50]),
        "sin_codigo": sin_codigo,
        "sin_descripcion": sin_desc,
        "sin_costo": sin_costo,
        "sin_precio": sin_precio,
        "stock_negativo": stock_negativo,
        "conteo_por_categoria": {},
    }
    for f in filas:
        cat = (f.get("categoria") or "SIN CATEGORIA").strip().upper()
        resumen["conteo_por_categoria"][cat] = resumen["conteo_por_categoria"].get(cat, 0) + 1
    resumen["conteo_por_categoria"] = dict(
        sorted(resumen["conteo_por_categoria"].items(), key=lambda kv: -kv[1]))

    csv_path = os.path.join(SALIDA, "refrimar_productos.csv")
    with open(csv_path, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh, delimiter=",", quotechar='"',
                       quoting=csv.QUOTE_MINIMAL, lineterminator="\r\n")
        w.writerow(columnas)
        for fila in filas:
            w.writerow([normalizar(fila.get(c)) for c in columnas])

    resumen_path = os.path.join(SALIDA, "resumen.json")
    with open(resumen_path, "w", encoding="utf-8") as fh:
        json.dump(resumen, fh, ensure_ascii=False, indent=2)

    print("")
    print("LISTO. Archivos generados:")
    print("  CSV   : %s" % csv_path)
    print("  JSON  : %s" % resumen_path)
    print("  Total : %d productos | codigos duplicados: %d | sin codigo: %d" %
          (len(filas), len(duplicados), sin_codigo))


if __name__ == "__main__":
    main()
