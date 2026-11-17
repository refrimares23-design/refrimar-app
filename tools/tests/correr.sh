#!/usr/bin/env bash
# Pruebas automáticas de REFRIMAR contra una COPIA de la estructura (nunca contra la tienda).
#   ./correr.sh            -> crea la copia desde estructura/estructura.csv y corre pruebas/*.sql
# Variables opcionales: PGHOST, PGPORT, PGUSER (por defecto un Postgres local).
set -u
AQUI="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
: "${PGHOST:=/var/lib/postgresql}" "${PGPORT:=54329}" "${PGUSER:=postgres}"
export PGHOST PGPORT PGUSER PGOPTIONS="-c client_min_messages=warning"
PSQL="psql -X -q -v ON_ERROR_STOP=1"
DB=refrimar_prueba; DB2=refrimar_reconstruida
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok=0; fallo=0
pasa() { echo "  OK     $1"; ok=$((ok+1)); }
falla() { echo "  FALLO  $1"; [ -n "${2:-}" ] && sed 's/^/         /' "$2" | head -15; fallo=$((fallo+1)); }

if ! $PSQL -d postgres -c "select 1" >/dev/null 2>&1; then
  echo "No hay Postgres en $PGHOST:$PGPORT. Arráncalo primero (ver README.md)."; exit 2
fi

nueva_base() { $PSQL -d postgres -c "drop database if exists $1" -c "create database $1" >/dev/null && $PSQL -d "$1" -f "$AQUI/stubs.sql" >/dev/null; }

echo "== Copia de prueba"
nueva_base $DB
CSV="$AQUI/estructura/estructura.csv"
if [ -f "$CSV" ]; then
  python3 "$AQUI/cargar_estructura.py" "$CSV" "$TMP/estructura.sql" >/dev/null
  if $PSQL -d $DB -f "$TMP/estructura.sql" >"$TMP/carga.log" 2>&1; then pasa "estructura real cargada"; else falla "cargar estructura real" "$TMP/carga.log"; fi
  if $PSQL -d $DB -f "$AQUI/semilla.sql" >"$TMP/semilla.log" 2>&1; then pasa "datos de prueba"; else falla "datos de prueba" "$TMP/semilla.log"; fi
else
  echo "  (falta estructura/estructura.csv: solo se prueban las herramientas)"
fi

if [ -f "$CSV" ]; then
  echo "== Migraciones nuevas (sql/) sobre la copia"
  for m in "$RAIZ"/sql/*.sql; do
    case "$(basename "$m")" in *etapa0*) continue;; esac
    if $PSQL -d $DB -f "$m" >"$TMP/m.log" 2>&1; then pasa "aplica $(basename "$m")"; else falla "aplica $(basename "$m")" "$TMP/m.log"; fi
  done
fi

echo "== Exportación de la estructura"
if $PSQL -d $DB -f "$RAIZ/sql/2026-11-16-etapa0-estructura.sql" --csv >"$TMP/exp.csv" 2>"$TMP/exp.log"; then
  pasa "el SQL de la etapa 0 corre"
  nueva_base $DB2
  python3 "$AQUI/cargar_estructura.py" "$TMP/exp.csv" "$TMP/re.sql" >/dev/null
  if $PSQL -d $DB2 -f "$TMP/re.sql" >"$TMP/re.log" 2>&1; then
    contar='select (select count(*) from pg_tables where schemaname=$$public$$)||$$/$$||(select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname=$$public$$)||$$/$$||(select count(*) from pg_policies where schemaname=$$public$$)'
    a=$($PSQL -At -d $DB -c "$contar"); b=$($PSQL -At -d $DB2 -c "$contar")
    if [ "$a" = "$b" ]; then pasa "la estructura exportada se reconstruye igual (tablas/funciones/políticas: $a)"; else echo "original $a / reconstruida $b" >"$TMP/dif"; falla "reconstrucción distinta" "$TMP/dif"; fi
  else falla "reconstruir desde la exportación" "$TMP/re.log"; fi
else falla "el SQL de la etapa 0" "$TMP/exp.log"; fi

echo "== Pruebas"
for f in "$AQUI"/pruebas/[0-9]*.sql; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .sql)"
  if { echo "begin;"; cat "$f"; echo "rollback;"; } | $PSQL -d $DB >"$TMP/p.log" 2>&1; then
    if grep -q "OMITIDA" "$TMP/p.log"; then echo "  OMITIDA $n ($(grep -o 'OMITIDA.*' "$TMP/p.log" | head -1))"; else pasa "$n"; fi
  else falla "$n" "$TMP/p.log"; fi
done

echo; echo "Resultado: $ok bien, $fallo con fallas"
[ "$fallo" -eq 0 ]
