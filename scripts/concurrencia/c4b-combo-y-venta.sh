#!/usr/bin/env bash
# Guardar un combo mientras se vende o se edita un pedido con ese combo (tarjeta C4b de #1603, H1 de
# su revisión adversarial). Dos sesiones psql reales contra una base DESCARTABLE de Docker con la
# migración de C4b y la semilla de los ensayos (scripts/ci/semilla-ensayos.sql). NUNCA contra prod.
#
#   CONTENEDOR=<contenedor> bash scripts/concurrencia/c4b-combo-y-venta.sh
#   CONTROL=1 CONTENEDOR=<contenedor> bash …   # control negativo: guardar_combo con FOR UPDATE (la v2)
#
# Los órdenes:
#   E1 la venta (crear_pedido_completo) primero, guardar el combo durante.
#   E2 guardar el combo primero, la venta durante.
#   E3 la venta con el producto ya tomado (como lo toma al empezar) y la línea del combo después;
#      guardar el combo en el medio. Es el cruce de la revisión: con FOR UPDATE en el combo, la venta
#      espera al combo y el guardado espera al producto → «deadlock detected».
#   E4 lo mismo con la edición del pedido (actualizar_pedido_items).
#   E5 la venta primero, editar el cliente de la venta durante (guardar_cliente, FOR NO KEY UPDATE).
#   E6 N1 de la segunda revisión: guardar el combo con los lugares al revés ([B] antes que [A], B de id
#      mayor). E6a la venta con A ya tomado y guardar en el medio; E6b guardar primero y la venta durante.
#      Las filas de combo_componentes toman el KEY SHARE de la FK en el orden del JSON: sin tomar antes
#      los productos por id, el guardado toma B, espera A, y la venta (que tiene A) espera B.
# Sin CONTROL, los siete tienen que terminar sin deadlock y con las dos operaciones bien. Con
# CONTROL=1, E3 y E4 (con FOR UPDATE en el combo, la v2) y E6a (sin el KEY SHARE de los productos, la
# 531) tienen que dar deadlock (si no, el guion no muerde). Sale con 1 si no da lo esperado.
set -u
C="${CONTENEDOR:?Falta CONTENEDOR (una base descartable de docker con la migración de C4b)}"
D="$(cd "$(dirname "$0")" && pwd)"
SLEEP="${SLEEP:-4}"
CONTROL="${CONTROL:-0}"
psqlc() { docker exec -i -e PGOPTIONS=-cclient_min_messages=warning "$C" psql -U postgres -h localhost -d postgres -X -At "$@"; }

psqlc -v ON_ERROR_STOP=1 < "$D/c4b-combo-y-venta.sql" >/dev/null || { echo "no se pudieron cargar los fixtures"; exit 2; }

FALLAS=0
# $1 nombre, $2 lo de S1 antes de dormir ('' si nada), $3 lo de S1 después de dormir ('' si nada), $4 lo de S2,
# $5 lo esperado: ok o deadlock
escenario() {
  psqlc -v ON_ERROR_STOP=1 -c "SELECT c4bc.escenario()" >/dev/null || { echo "$1: no se pudo armar"; FALLAS=$((FALLAS + 1)); return; }
  local pre="" post=""
  [ -n "$2" ] && pre="SELECT 'S1 ' || ($2);"
  [ -n "$3" ] && post="SELECT 'S1 ' || ($3);"
  ( printf "BEGIN;\nSELECT 'S1 empieza ' || clock_timestamp();\n%s\nSELECT pg_sleep(%s);\n%s\nSELECT 'S1 confirma ' || clock_timestamp();\nCOMMIT;\n" "$pre" "$SLEEP" "$post" \
      | psqlc > "/tmp/c4bc-$1-s1.out" 2>&1 ) &
  sleep 1
  printf "BEGIN;\nSELECT 'S2 empieza ' || clock_timestamp();\nSELECT 'S2 ' || (%s);\nSELECT 'S2 termina ' || clock_timestamp();\nCOMMIT;\n" "$4" \
    | psqlc > "/tmp/c4bc-$1-s2.out" 2>&1
  wait
  local dl ok1 ok2 v
  dl=$(grep -c "deadlock detected" "/tmp/c4bc-$1-s1.out" "/tmp/c4bc-$1-s2.out" | awk -F: '{s+=$2} END {print s}')
  ok1=$(grep -c '"success": true' "/tmp/c4bc-$1-s1.out")
  ok2=$(grep -c '"success": true' "/tmp/c4bc-$1-s2.out")
  if [ "$5" = deadlock ]; then
    if [ "$dl" -gt 0 ]; then v="OK (control negativo): deadlock, como sin el arreglo"; else v="EL CONTROL NO MUERDE: no hubo deadlock"; fi
  else
    if [ "$dl" -eq 0 ] && [ "$ok1" -ge 1 ] && [ "$ok2" -ge 1 ]; then v="OK: sin deadlock, las dos operaciones entran"; else v="FALLA: deadlock=$dl venta/edición ok=$ok1 guardar ok=$ok2"; fi
  fi
  echo "== $1"
  grep -h -E "^S[12] |ERROR|deadlock" "/tmp/c4bc-$1-s1.out" "/tmp/c4bc-$1-s2.out" | cut -c1-200 | sed 's/^/   /'
  echo "   $v"
  case "$v" in OK*) ;; *) FALLAS=$((FALLAS + 1)) ;; esac
}

if [ "$CONTROL" = 1 ]; then
  psqlc -c "SELECT c4bc.poner_for_update(true)" | grep -q cambiado || { echo "no se pudo poner el FOR UPDATE"; exit 2; }
  escenario E3-venta-con-producto-tomado  "c4bc.tomar_producto()" "c4bc.vender()" "c4bc.guardar()" deadlock
  escenario E4-edicion-con-producto-tomado "c4bc.tomar_producto()" "c4bc.editar()" "c4bc.guardar()" deadlock
  psqlc -c "SELECT c4bc.poner_for_update(false)" >/dev/null
  psqlc -c "SELECT c4bc.sin_key_share(true)" | grep -q cambiado || { echo "no se pudo sacar el KEY SHARE"; exit 2; }
  escenario E6a-venta-con-producto-tomado-guardar-ba "c4bc.tomar_producto()" "c4bc.vender()" "c4bc.guardar_ba()" deadlock
  psqlc -c "SELECT c4bc.sin_key_share(false)" >/dev/null
else
  escenario E1-venta-y-guardar            "c4bc.vender()" "" "c4bc.guardar()" ok
  escenario E2-guardar-y-venta            "c4bc.guardar()" "" "c4bc.vender()" ok
  escenario E3-venta-con-producto-tomado  "c4bc.tomar_producto()" "c4bc.vender()" "c4bc.guardar()" ok
  escenario E4-edicion-con-producto-tomado "c4bc.tomar_producto()" "c4bc.editar()" "c4bc.guardar()" ok
  escenario E5-venta-y-editar-cliente     "c4bc.vender()" "" "c4bc.guardar_cliente()" ok
  escenario E6a-venta-con-producto-tomado-guardar-ba "c4bc.tomar_producto()" "c4bc.vender()" "c4bc.guardar_ba()" ok
  escenario E6b-guardar-ba-y-venta        "c4bc.guardar_ba()" "" "c4bc.vender()" ok
fi

if [ "$FALLAS" -gt 0 ]; then echo "FALLAN $FALLAS escenario(s)"; exit 1; fi
if [ "$CONTROL" = 1 ]; then echo "OK: el control negativo muerde (con FOR UPDATE en el combo, E3 y E4 dan deadlock; sin el KEY SHARE de los productos, E6a)"; else echo "OK: los siete órdenes terminan sin deadlock"; fi
