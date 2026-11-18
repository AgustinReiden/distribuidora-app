#!/usr/bin/env bash
# Carreras de la nota de crédito de venta que mueve mercadería (tarjeta B22 de #1603). Dos sesiones psql
# reales contra una base DESCARTABLE de Docker con la migración de B22: una abre su transacción, hace lo suyo
# y espera; la otra arranca después y choca. NUNCA contra prod.
#
#   CONTENEDOR=<contenedor> bash scripts/concurrencia/b22-nota-con-mercaderia.sh
#
# A tiene L1 20 y L2 20 y la bolsa en 0; P1 es A×10, vendida de L1 (L1 10, huella L1:10).
#   V1 la nota de rechazo de A×4 primero, una venta de A×6 (a otro cliente) durante: la venta espera el
#      producto y sale de L1 ya repuesto: stock 28, lotes [8,20].
#   V2 la venta primero, la nota durante: la nota espera y vuelve a L1: lo mismo.
#   V3 la nota primero, una salvedad de A×2 sobre la misma línea durante: la salvedad espera la boleta y se
#      rechaza (nota vigente). Stock 34, lotes [14,20], huella L1:6. OJO: registrar_salvedad mira la nota
#      vigente ANTES de tomar la boleta (mig 276) y no después, así que hoy la salvedad entra igual (stock
#      36, línea 8): V3 da FALLA hasta que registrar_salvedad repita esa guarda después de su FOR UPDATE
#      (hallazgo fuera de B22, que no toca la salvedad; el parche está en el informe de la tarjeta).
#   V4 la salvedad primero, la nota durante: la nota espera y acredita sobre las 8 que quedan. Stock 36,
#      lotes [16,20], línea 8 con huella L1:4.
#   V5 dos notas de A×6 a la vez: la segunda espera y se rechaza (quedan 4). Stock 36, lotes [16,20].
#   V6 con la nota de A×4 hecha: anularla primero y la venta de A×6 durante: stock 24, lotes [4,20].
#   V7 la venta primero y anular durante: lo mismo.
# Sin deadlock en ninguno. Sale con 1 si alguno no da OK.
set -u
C="${CONTENEDOR:?Falta CONTENEDOR (una base descartable de docker con la migración de B22)}"
D="$(cd "$(dirname "$0")" && pwd)"
SLEEP="${SLEEP:-8}"
TMP="${TMPDIR:-/tmp}"
psqlc() { docker exec -i "$C" psql -U postgres -h localhost -d postgres -X -At -v ON_ERROR_STOP=1 "$@"; }

psqlc < "$D/b22-nota-con-mercaderia.sql" >/dev/null || { echo "no se pudieron cargar los fixtures"; exit 2; }

FALLAS=0
# $1 nombre, $2 con nota al armar (true/false), $3 lo de S1, $4 lo de S2, $5 el veredicto (foto, línea, huella)
escenario() {
  psqlc -c "SELECT b22c.escenario($2)" >/dev/null || { echo "$1: no se pudo armar"; FALLAS=$((FALLAS + 1)); return; }
  ( printf "BEGIN;\nSELECT 'S1 empieza ' || clock_timestamp();\nSELECT 'S1 ' || (%s);\nSELECT pg_sleep(%s);\nSELECT 'S1 confirma ' || clock_timestamp();\nCOMMIT;\n" "$3" "$SLEEP" \
      | psqlc > "$TMP/b22c-$1-s1.out" 2>&1 ) &
  sleep 2
  printf "BEGIN;\nSELECT 'S2 empieza ' || clock_timestamp();\nSELECT 'S2 ' || (%s);\nSELECT 'S2 termina ' || clock_timestamp();\nCOMMIT;\n" "$4" \
    | psqlc > "$TMP/b22c-$1-s2.out" 2>&1
  wait
  local v s2 s1
  v=$(psqlc -c "SELECT b22c.veredicto($5)")
  s2=$(sed -n 's/^S2 empieza //p' "$TMP/b22c-$1-s2.out")
  s1=$(sed -n 's/^S1 confirma //p' "$TMP/b22c-$1-s1.out")
  if [ -z "$s2" ] || [ -z "$s1" ] || [[ ! "$s2" < "$s1" ]]; then v="NO SE CRUZARON (S2 empezó $s2, S1 confirmó $s1): subí SLEEP · $v"; fi
  if grep -q -E "deadlock|ERROR" "$TMP/b22c-$1-s1.out" "$TMP/b22c-$1-s2.out"; then v="CON ERROR · $v"; fi
  echo "== $1"
  grep -h -E "^S[12] |ERROR|deadlock" "$TMP/b22c-$1-s1.out" "$TMP/b22c-$1-s2.out" | sed 's/^/   /'
  echo "   $v"
  case "$v" in OK*) ;; *) FALLAS=$((FALLAS + 1)) ;; esac
}

escenario V1-nota-y-venta      false "b22c.nc_txt(4)"   "b22c.venta(6)"     "'stock=28 lotes=[8,20] bolsa=0', 10, 6"
escenario V2-venta-y-nota      false "b22c.venta(6)"    "b22c.nc_txt(4)"    "'stock=28 lotes=[8,20] bolsa=0', 10, 6"
escenario V3-nota-y-salvedad   false "b22c.nc_txt(4)"   "b22c.salvedad(2)"  "'stock=34 lotes=[14,20] bolsa=0', 10, 6"
escenario V4-salvedad-y-nota   false "b22c.salvedad(2)" "b22c.nc_txt(4)"    "'stock=36 lotes=[16,20] bolsa=0', 8, 4"
escenario V5-nota-y-nota       false "b22c.nc_txt(6)"   "b22c.nc_txt(6)"    "'stock=36 lotes=[16,20] bolsa=0', 10, 4"
escenario V6-anular-y-venta    true  "b22c.anular()"    "b22c.venta(6)"     "'stock=24 lotes=[4,20] bolsa=0', 10, 10"
escenario V7-venta-y-anular    true  "b22c.venta(6)"    "b22c.anular()"     "'stock=24 lotes=[4,20] bolsa=0', 10, 10"

if [ "$FALLAS" -gt 0 ]; then echo "FALLAN $FALLAS escenario(s)"; exit 1; fi
echo "OK: los siete órdenes dan lo que dice la foto, sin deadlock (la nota con mercadería se serializa con la venta del producto, con la salvedad y con otra nota de la misma boleta)"
