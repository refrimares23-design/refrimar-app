# Pruebas automáticas de REFRIMAR

Corren contra una **copia de la estructura** de la base en un Postgres local. Nunca tocan la base de la tienda ni sus datos.

## Qué hace `correr.sh`

1. Crea la base `refrimar_prueba` con lo mínimo de Supabase (`stubs.sql`: roles `anon`, `authenticated`, `auth.jwt()`, `auth.uid()`).
2. Carga la estructura real desde `estructura/estructura.csv` (el CSV que sale al correr `sql/2026-11-16-etapa0-estructura.sql` en Supabase y tocar *Export*).
3. Comprueba que esa exportación se puede reconstruir igual en otra base.
4. Corre cada archivo `pruebas/NN_nombre.sql` dentro de una transacción que se deshace al final.

Una prueba falla con `assert` o `raise exception`. Si le falta algo para correr, imprime `OMITIDA: motivo` y no cuenta como falla.

## Arrancar Postgres local (Linux)

```bash
PGB=/usr/lib/postgresql/16/bin; D=/var/lib/postgresql/refrimar-test
su postgres -s /bin/bash -c "$PGB/initdb -D $D -U postgres -A trust && $PGB/pg_ctl -D $D -o '-p 54329 -k /var/lib/postgresql' -l $D.log start"
tools/tests/correr.sh
```

## Reglas

- Cada cambio de base (archivo en `sql/`) llega con su prueba en `pruebas/`.
- Las pruebas revisan el antes y el después: stock, kardex, saldo y caja.
- Esta carpeta y `sql/` no se publican en la tienda (`.assetsignore`).
