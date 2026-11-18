#!/usr/bin/env bash
# Carreras de la edición de una compra que guarda sus vencimientos en la misma llamada (STK-13 de #1542,
# tarjeta C3 de la tanda 5 de #1603) contra una venta del mismo producto. Dos sesiones psql reales contra una
# base DESCARTABLE de Docker con la migración de C3: una abre su transacción, hace lo suyo y espera; la otra
# arranca después y choca. NUNCA contra prod.
#
#   CONTENEDOR=<contenedor> bash scripts/concurrencia/c3-edicion-compra-y-venta.sh
#
# A tiene una ZZ de A×100 con lotes de 60 (vence primero) y 40, y la bolsa en 0.
#   V1 la edición a A×80 con lotes de 50 y 30 primero, una venta de A×10 durante: la venta espera el producto
#      y sale del lote que vence primero, ya corregido: stock 70, lotes 40/50 y 30/30, bolsa 0.
#   V2 la venta primero, la edición durante: la edición espera el producto, le saca a los lotes de la
#      compra lo que la bolsa no cubre (sin contarlo como vendido) y los deja en la foto menos lo que de
#      verdad salió: lo mismo.
#   V3 dos ediciones a la vez con la misma versión: la segunda espera la compra y se rechaza («alguien la
#      cambió»); queda la primera: stock 80, lotes 50/50 y 30/30.
# Sin deadlock en ninguno. Sale con 1 si alguno no da OK.
set -u
C="${CONTENEDOR:?Falta CONTENEDOR (una base descartable de docker con la migración de C3)}"
D="$(cd "$(dirname "$0")" && pwd)"
SLEEP="${SLEEP:-8}"
TMP="${TMPDIR:-/tmp}"
psqlc() { docker exec -i "$C" psql -U postgres -h localhost -d postgres -X -At -v ON_ERROR_STOP=1 "$@"; }

psqlc < "$D/c3-edicion-compra-y-venta.sql" >/dev/null || { echo "no se pudieron cargar los fixtures"; exit 2; }

FALLAS=0
# $1 nombre, $2 lo de S1, $3 lo de S2, $4 la foto esperada
escenario() {
  psqlc -c "SELECT c3c.escenario()" >/dev/null || { echo "$1: no se pudo armar"; FALLAS=$((FALLAS + 1)); return; }
  ( printf "BEGIN;\nSELECT 'S1 empieza ' || clock_timestamp();\nSELECT 'S1 ' || (%s);\nSELECT pg_sleep(%s);\nSELECT 'S1 confirma ' || clock_timestamp();\nCOMMIT;\n" "$2" "$SLEEP" \
      | psqlc > "$TMP/c3c-$1-s1.out" 2>&1 ) &
  sleep 2
  printf "BEGIN;\nSELECT 'S2 empieza ' || clock_timestamp();\nSELECT 'S2 ' || (%s);\nSELECT 'S2 termina ' || clock_timestamp();\nCOMMIT;\n" "$3" \
    | psqlc > "$TMP/c3c-$1-s2.out" 2>&1
  wait
  local v s2 s1
  v=$(psqlc -c "SELECT c3c.veredicto('$4')")
  s2=$(sed -n 's/^S2 empieza //p' "$TMP/c3c-$1-s2.out")
  s1=$(sed -n 's/^S1 confirma //p' "$TMP/c3c-$1-s1.out")
  if [ -z "$s2" ] || [ -z "$s1" ] || [[ ! "$s2" < "$s1" ]]; then v="NO SE CRUZARON (S2 empezó $s2, S1 confirmó $s1): subí SLEEP · $v"; fi
  if grep -q -E "deadlock|ERROR" "$TMP/c3c-$1-s1.out" "$TMP/c3c-$1-s2.out"; then v="CON ERROR · $v"; fi
  echo "== $1"
  grep -h -E "^S[12] |ERROR|deadlock" "$TMP/c3c-$1-s1.out" "$TMP/c3c-$1-s2.out" | sed 's/^/   /'
  echo "   $v"
  case "$v" in OK*) ;; *) FALLAS=$((FALLAS + 1)) ;; esac
}

escenario V1-edicion-y-venta   "c3c.editar()"  "c3c.venta(10)"  "stock=70 lotes=[40/50,30/30] bolsa=0 compra=80"
escenario V2-venta-y-edicion   "c3c.venta(10)" "c3c.editar()"   "stock=70 lotes=[40/50,30/30] bolsa=0 compra=80"
escenario V3-edicion-y-edicion "c3c.editar()"  "c3c.editar()"   "stock=80 lotes=[50/50,30/30] bolsa=0 compra=80"

if [ "$FALLAS" -gt 0 ]; then echo "FALLAN $FALLAS escenario(s)"; exit 1; fi
echo "OK: los tres órdenes dan lo que dice la foto, sin deadlock (la edición con sus vencimientos se serializa con la venta del producto y con otra edición de la misma compra)"
