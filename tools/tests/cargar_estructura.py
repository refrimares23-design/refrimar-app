#!/usr/bin/env python3
"""Convierte el CSV de la estructura (Supabase → Export) en un SQL que se puede cargar."""
import csv, sys
src, dst = sys.argv[1], sys.argv[2]
csv.field_size_limit(10**9)
filas = list(csv.DictReader(open(src, encoding='utf-8-sig')))
saltar = {'filas_aprox'}
out = ["set check_function_bodies = off;", "set client_min_messages = warning;"]
for f in sorted(filas, key=lambda r: (int(r['orden']), r['nombre'])):
    if f['tipo'] in saltar or f['tipo'] == 'schema' and f['nombre'] in ('auth', 'extensions', 'storage'):
        continue
    ddl = f['ddl'].strip()
    if f['tipo'] == 'extension':
        # En la copia de prueba solo hacen falta las que existen en Postgres normal
        ddl = "do $x$ begin execute %s; exception when others then raise notice 'extension omitida: %s'; end $x$;" % (
            "'" + ddl.replace("'", "''") + "'", f['nombre'])
    out.append(ddl if ddl.endswith(';') else ddl + ';')
open(dst, 'w', encoding='utf-8').write("\n\n".join(out) + "\n")
print(f"{len(filas)} objetos -> {dst}")
