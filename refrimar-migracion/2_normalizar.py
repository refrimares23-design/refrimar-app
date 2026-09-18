#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REFRIMAR -> MIGRACION A PROFIT PLUS 2KDOCE
Paso 2: Normalizacion y control de calidad del catalogo.

Lee:     salida/refrimar_productos.csv   (generado por 1_extraer_supabase.py)
Genera:
  salida/refrimar_normalizado.csv        -> catalogo limpio y listo para mapear
  salida/refrimar_reporte_revision.csv   -> filas que requieren decision humana
  salida/lineas.json                     -> lineas/sublinies sugeridas para Profit Plus

Nada de esto toca Supabase ni Profit Plus: solo crea archivos de trabajo.
"""

import csv
import json
import os
import re

BASE = os.path.dirname(os.path.abspath(__file__))
SALIDA = os.path.join(BASE, "salida")
ENTRADA = os.path.join(SALIDA, "refrimar_productos.csv")

CANONICA = {
    "FERRETERIA": "FERRETERIA",
    "FERRETERÍA": "FERRETERIA",
    "FERRETERÍA GENERAL": "FERRETERIA",
    "PLOMERÍA": "PLOMERIA",
    "PLOMERIA": "PLOMERIA",
    "ELECTRICIDAD": "ELECTRICIDAD",
    "ELÉCTRICOS": "ELECTRICIDAD",
    "HERRAMIENTAS": "HERRAMIENTAS",
    "HOGAR / COCINA": "HOGAR",
    "HOGAR/COCINA": "HOGAR",
    "SEGURIDAD": "SEGURIDAD",
    "JARDINERÍA": "JARDINERIA",
    "REFRIGERACIÓN": "REFRIGERACION",
    "EQUIPOS": "EQUIPOS",
    "INSUMOS": "INSUMOS",
    "CONTROL": "CONTROL",
}


def linea_de(categoria):
    c = (categoria or "").strip().upper()
    if not c or c == "SIN CATEGORIA" or c == "3" or not re.match(r"[A-ZÁÉÍÓÚÑ ]", c):
        return "SIN CLASIFICAR"
    return CANONICA.get(c, "SIN CLASIFICAR")


def limpiar_descripcion(desc):
    d = (desc or "").strip()
    alt = re.search(r"\(\s*Alt\s*[:\-]?\s*([0-9]+)\s*\)", d, flags=re.IGNORECASE)
    alt_codigo = alt.group(1) if alt else ""
    limpia = re.sub(r"\(\s*Alt\s*[:\-]?\s*[0-9]+\s*\)", "", d, flags=re.IGNORECASE)
    limpia = re.sub(r"\s+", " ", limpia).strip(" -")
    return limpia, alt_codigo


def a_num(valor):
    if valor is None or str(valor).strip() == "":
        return 0.0
    try:
        return float(valor)
    except ValueError:
        return 0.0


def main():
    with open(ENTRADA, newline="", encoding="utf-8-sig") as fh:
        filas = list(csv.DictReader(fh))

    limpios = []
    revision = []
    lineas = {}

    for f in filas:
        codigo = (f.get("codigo") or "").strip()
        desc, alt_de_desc = limpiar_descripcion(f.get("descripcion"))
        categoria = (f.get("categoria") or "").strip().upper()
        linea = linea_de(categoria)
        sublinea = "GENERAL" if linea == "SIN CLASIFICAR" else categoria
        marca = (f.get("marca") or "").strip()
        costo = a_num(f.get("costo"))
        precio = a_num(f.get("precio"))
        stock = a_num(f.get("stock"))
        stock_min = a_num(f.get("stock_minimo"))
        unidad = (f.get("unidad") or "uds").strip()
        alt_original = f.get("codigos_alternos") or "[]"

        alternos = []
        try:
            alternos = json.loads(alt_original) if alt_original.strip() else []
        except Exception:
            alternos = []
        if not isinstance(alternos, list):
            alternos = []
        alternos = [str(a).strip() for a in alternos if str(a).strip()]
        if alt_de_desc and alt_de_desc not in alternos:
            alternos.append(alt_de_desc)

        codigo_barras = codigo if codigo.isdigit() else (alternos[0] if alternos else "")

        limpios.append({
            "codigo": codigo,
            "descripcion": desc,
            "descripcion_original": (f.get("descripcion") or "").strip(),
            "linea": linea,
            "sublinea": sublinea,
            "marca": marca,
            "costo": "%.2f" % costo,
            "precio": "%.2f" % precio,
            "stock": "%.2f" % stock,
            "stock_minimo": "%.2f" % stock_min,
            "unidad": unidad,
            "codigo_barras": codigo_barras,
            "codigos_alternos": ";".join(alternos),
        })

        lineas.setdefault(linea, {})
        lineas[linea][sublinea] = lineas[linea].get(sublinea, 0) + 1

        motivos = []
        if costo <= 0:
            motivos.append("costo<=0")
        if precio <= 0:
            motivos.append("precio<=0")
        if 0 < costo and 0 < precio and precio < costo:
            motivos.append("precio<costo")
        if stock < 0:
            motivos.append("stock<0")
        if linea == "SIN CLASIFICAR":
            motivos.append("categoria-no-estandar")
        if alt_de_desc:
            motivos.append("barras-en-descripcion")
        if len(desc) > 60:
            motivos.append("descripcion-larga")
        if motivos:
            revision.append({
                "codigo": codigo,
                "descripcion": desc,
                "categoria_original": categoria,
                "marca": marca,
                "costo": costo,
                "precio": precio,
                "stock": stock,
                "motivos": ";".join(motivos),
            })

    campos = ["codigo", "descripcion", "linea", "sublinea", "marca",
              "costo", "precio", "stock", "stock_minimo", "unidad",
              "codigo_barras", "codigos_alternos", "descripcion_original"]
    with open(os.path.join(SALIDA, "refrimar_normalizado.csv"), "w",
              newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=campos, lineterminator="\r\n")
        w.writeheader()
        w.writerows(limpios)

    campos_r = ["codigo", "descripcion", "categoria_original", "marca",
                "costo", "precio", "stock", "motivos"]
    with open(os.path.join(SALIDA, "refrimar_reporte_revision.csv"), "w",
              newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=campos_r, lineterminator="\r\n")
        w.writeheader()
        w.writerows(revision)

    with open(os.path.join(SALIDA, "lineas.json"), "w", encoding="utf-8") as fh:
        json.dump({"lineas": lineas}, fh, ensure_ascii=False, indent=2)

    print("LISTO.")
    print("  Normalizados : %d" % len(limpios))
    print("  En revision  : %d (ver refrimar_reporte_revision.csv)" % len(revision))
    print("  Lineas unicas: %d (ver lineas.json)" % len(lineas))
    for linea, subs in sorted(lineas.items()):
        print("    - %s (%d sublineas)" % (linea, len(subs)))


if __name__ == "__main__":
    main()
