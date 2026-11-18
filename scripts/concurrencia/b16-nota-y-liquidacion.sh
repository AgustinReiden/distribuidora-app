#!/usr/bin/env bash
# Carreras de la nota de crédito de venta con la liquidación del vendedor (tarjeta B16 de #1603, H1 de la
# revisión de la v3). Dos sesiones psql reales contra una base DESCARTABLE de Docker con la migración de B16:
# una abre su transacción, hace lo suyo y espera; la otra arranca después y choca. NUNCA contra prod.
#
#   CONTENEDOR=<contenedor> bash scripts/concurrencia/b16-nota-y-liquidacion.sh
#
# Los órdenes (la nota es una de rechazo de 200 sobre una boleta de 1.000 del mes pasado):
#   E1 la nota primero, la liquidación durante: la liquidación espera y la ve (liquida 800; si había
#      abierto la vista previa antes, contesta «Algo cambió» y se reabre).
#   E2 la liquidación primero, la nota durante: la nota espera y queda «ya liquidada» (no resta; 1.000).
#   E3 anular la nota primero, la liquidación durante: la liquidación espera y la ve anulada (1.000).
#   E4 la liquidación primero (con la nota vigente), anular durante: la anulación espera; lo liquidado
#      con la nota (800) queda congelado y la nota sigue restando.
#   E5 (N1 de la revisión de la v4) con la boleta ya liquidada con la nota (800): anular la nota primero,
#      anular la liquidación durante: la anulación de la liquidación espera y suelta la nota.
#   E6 al revés: anular la liquidación primero, anular la nota durante: la nota espera y ve la boleta sin
#      liquidar. En los dos, la nota anulada deja de restar y la próxima liquidación trae la boleta por
#      1.000. Sin el FOR KEY SHARE de anular_liquidacion, los dos quedaban en 800.
#   E7 y E8 (N4, decisión del dueño del 18/11: «Sí, vuelve a descontar») con la boleta liquidada SIN nota:
#      crear la nota y anular la liquidación a la vez, en los dos órdenes. La nota queda restando y la
#      próxima liquidación trae la boleta por 800 en los dos (antes: 1.000 u 800 según el orden).
# En E1 a E4: ningún ajuste pendiente para la liquidación siguiente. Sale con 1 si alguno no da OK.
set -u
C="${CONTENEDOR:?Falta CONTENEDOR (una base descartable de docker con la migración de B16)}"
D="$(cd "$(dirname "$0")" && pwd)"
SLEEP="${SLEEP:-12}"
psqlc() { docker exec -i "$C" psql -U postgres -h localhost -d postgres -X -At -v ON_ERROR_STOP=1 "$@"; }

psqlc < "$D/b16-nota-y-liquidacion.sql" >/dev/null || { echo "no se pudieron cargar los fixtures"; exit 2; }

FALLAS=0
# $1 nombre, $2 con nota al armar (true/false), $3 lo de S1, $4 lo de S2, [$5 liquidar antes (true/false),
# $6 la función del veredicto]
escenario() {
  psqlc -c "SELECT b16c.escenario($2)" >/dev/null || { echo "$1: no se pudo armar"; FALLAS=$((FALLAS + 1)); return; }
  if [ "${5:-false}" = true ]; then
    psqlc -c "SELECT b16c.liquidar()" | grep -q '^liquidación' || { echo "$1: no se pudo liquidar antes"; FALLAS=$((FALLAS + 1)); return; }
  fi
  ( printf "BEGIN;\nSELECT 'S1 empieza ' || clock_timestamp();\nSELECT 'S1 ' || (%s);\nSELECT pg_sleep(%s);\nSELECT 'S1 confirma ' || clock_timestamp();\nCOMMIT;\n" "$3" "$SLEEP" \
      | psqlc > "/tmp/b16c-$1-s1.out" 2>&1 ) &
  sleep 2
  printf "BEGIN;\nSELECT 'S2 empieza ' || clock_timestamp();\nSELECT 'S2 ' || (%s);\nSELECT 'S2 termina ' || clock_timestamp();\nCOMMIT;\n" "$4" \
    | psqlc > "/tmp/b16c-$1-s2.out" 2>&1
  wait
  local v s2 s1
  v=$(psqlc -c "SELECT b16c.${6:-veredicto}()")
  # Si S2 arrancó después de que S1 confirmó, no hubo carrera (una máquina cargada tarda en abrir
  # la segunda sesión): el escenario no prueba nada y cuenta como falla. Subí SLEEP.
  s2=$(sed -n 's/^S2 empieza //p' "/tmp/b16c-$1-s2.out")
  s1=$(sed -n 's/^S1 confirma //p' "/tmp/b16c-$1-s1.out")
  if [ -z "$s2" ] || [ -z "$s1" ] || [[ ! "$s2" < "$s1" ]]; then v="NO SE CRUZARON (S2 empezó $s2, S1 confirmó $s1): subí SLEEP · $v"; fi
  echo "== $1"
  grep -h -E "^S[12] |ERROR|deadlock" "/tmp/b16c-$1-s1.out" "/tmp/b16c-$1-s2.out" | sed 's/^/   /'
  echo "   $v"
  case "$v" in OK*) ;; *) FALLAS=$((FALLAS + 1)) ;; esac
}

NOTA="((b16c.nc())->>'resta_comision')"
ANULAR="((b16c.anular())->>'success')"
LIQ="b16c.liquidar()"
escenario E1-nota-y-liquidacion        false "'nota resta_comision=' || $NOTA" "$LIQ"
escenario E2-liquidacion-y-nota        false "$LIQ" "'nota resta_comision=' || $NOTA"
escenario E3-anular-y-liquidacion      true  "'anulada ' || $ANULAR" "$LIQ"
escenario E4-liquidacion-y-anular      true  "$LIQ" "'anulada ' || $ANULAR"
ANULIQ="b16c.anular_liq()"
escenario E5-anular-y-anular-liq       true  "'anulada ' || $ANULAR" "$ANULIQ" true veredicto_sin_liquidar
escenario E6-anular-liq-y-anular       true  "$ANULIQ" "'anulada ' || $ANULAR" true veredicto_sin_liquidar
escenario E7-nota-y-anular-liq         false "'nota resta_comision=' || $NOTA" "$ANULIQ" true veredicto_sin_liquidar
escenario E8-anular-liq-y-nota         false "$ANULIQ" "'nota resta_comision=' || $NOTA" true veredicto_sin_liquidar

if [ "$FALLAS" -gt 0 ]; then echo "FALLAN $FALLAS escenario(s)"; exit 1; fi
echo "OK: los ocho órdenes dan lo que dice la foto (E1–E4 sin ajuste pendiente; E5 a E8, la nota como si la boleta no se hubiera liquidado)"
