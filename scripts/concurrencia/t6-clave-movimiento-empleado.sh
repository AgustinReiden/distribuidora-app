#!/usr/bin/env bash
# El doble toque de un pago al personal y de una liquidación, en dos sesiones a la vez (Com-B3 de #1554, ola 3,
# tarjeta T6 de #1677). Dos sesiones psql reales contra una base DESCARTABLE de Docker con la migración
# NNN_ola3_personal_liquidaciones. NUNCA contra prod.
#
#   CONTENEDOR=<contenedor> bash scripts/concurrencia/t6-clave-movimiento-empleado.sh
#
# Escenarios (el admin es uno de todas las sucursales de la base; el empleado lo crea el guion):
#   P1 registrar_movimiento_empleado: S1 paga $ 1.000 con la clave K y espera antes del COMMIT; S2 manda lo mismo
#      con K (el reintento tras perder la respuesta). S2 espera el lock del empleado y devuelve el movimiento de
#      S1: queda UN pago.
#   L1 liquidar_empleado: lo mismo con el JSON de ModalLiquidar y la clave K: queda UNA liquidación y S2 devuelve
#      la de S1.
#   Control negativo (P0 y L0): lo mismo con dos claves distintas, que es lo que pasa sin clave (un PWA de antes):
#      el pago entra dos veces (el saldo alcanza para los dos), y la segunda liquidación, que ya no es la del
#      período, se rechaza (sin clave no hay reintento: el guion lo cuenta como lo esperado). Si P0 no deja dos
#      pagos, el guion no está probando nada.
# Sale con 1 si algún escenario no da lo esperado. Al final borra lo que creó (si la base lo deja).
set -u
C="${CONTENEDOR:?Falta CONTENEDOR (una base descartable de docker con la migración de T6)}"
SLEEP="${SLEEP:-6}"
TMP="${TMPDIR:-/tmp}"
psqlc() { docker exec -i "$C" psql -U postgres -h localhost -d postgres -X -At -v ON_ERROR_STOP=1 "$@"; }

ADMIN=$(psqlc -c "SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id AND p.activo AND p.rol = 'admin'
                   WHERE NOT EXISTS (SELECT 1 FROM sucursales s WHERE s.activa AND NOT EXISTS (
                           SELECT 1 FROM usuario_sucursales u2 WHERE u2.usuario_id = us.usuario_id AND u2.sucursal_id = s.id))
                   ORDER BY us.usuario_id LIMIT 1")
SUC=$(psqlc -c "SELECT min(id) FROM sucursales WHERE activa")
[ -n "$ADMIN" ] && [ -n "$SUC" ] || { echo "sin admin de todas las sucursales o sin sucursal activa"; exit 2; }
psqlc -c "SELECT to_regprocedure('public.registrar_movimiento_empleado(bigint,jsonb,uuid)') IS NOT NULL" | grep -q t \
  || { echo "la base no tiene la migración de T6 (registrar_movimiento_empleado con p_clave)"; exit 2; }

# Un empleado con sueldo semanal desde hace dos semanas y $ 5.000 de saldo a favor (como ModalEmpleado y un ajuste).
empleado() {
  psqlc <<SQL
SELECT set_config('request.jwt.claims', json_build_object('sub', '$ADMIN', 'role', 'authenticated')::text, false),
       set_config('request.headers', json_build_object('x-sucursal-id', '$SUC')::text, false);
SET ROLE authenticated;
SELECT public.guardar_empleado(p_empleado => jsonb_build_object(
  'nombre', 'ZZ t6 carrera ' || gen_random_uuid(), 'puesto', 'ayudante', 'sucursal_id', $SUC, 'de_las_dos', false,
  'arreglo', jsonb_build_object('vigente_desde', date_trunc('week', public._tablero_hoy()::timestamp)::date - 14,
                                'sueldo', 70000, 'frecuencia', 'semanal', 'comisiona', false),
  'saldo_inicial', 5000));
SQL
}

# $1 S1|S2, $2 la llamada (SQL), $3 segundos de espera antes del COMMIT
sesion() {
  printf "BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '%s', 'role', 'authenticated')::text, true),
       set_config('request.headers', json_build_object('x-sucursal-id', '%s')::text, true);
SET LOCAL ROLE authenticated;
SELECT '%s empieza ' || clock_timestamp();
SELECT '%s id ' || (%s);
SELECT pg_sleep(%s);
SELECT '%s confirma ' || clock_timestamp();
COMMIT;
" "$ADMIN" "$SUC" "$1" "$1" "$2" "$3" "$1" | psqlc
}

FALLAS=0
CREADOS=()
# $1 nombre, $2 llamada de S1, $3 llamada de S2, $4 consulta del veredicto (cuántos quedaron), $5 cuántos se esperan
escenario() {
  ( sesion S1 "$2" "$SLEEP" > "$TMP/t6c-$1-s1.out" 2>&1 ) &
  sleep 2
  sesion S2 "$3" 0 > "$TMP/t6c-$1-s2.out" 2>&1
  wait
  local n s2e s1c id1 id2 v
  n=$(psqlc -c "$4")
  s2e=$(sed -n 's/^S2 empieza //p' "$TMP/t6c-$1-s2.out")
  s1c=$(sed -n 's/^S1 confirma //p' "$TMP/t6c-$1-s1.out")
  id1=$(sed -n 's/^S1 id //p' "$TMP/t6c-$1-s1.out")
  id2=$(sed -n 's/^S2 id //p' "$TMP/t6c-$1-s2.out")
  echo "== $1"
  grep -h -E "^S[12] |ERROR|deadlock" "$TMP/t6c-$1-s1.out" "$TMP/t6c-$1-s2.out" | sed 's/^/   /'
  if [ -z "$s2e" ] || [ -z "$s1c" ] || [[ ! "$s2e" < "$s1c" ]]; then
    v="NO SE CRUZARON (S2 empezó $s2e, S1 confirmó $s1c): subí SLEEP"
  elif [ "$n" = "$5" ]; then
    v="OK: quedaron $n (S1 $id1, S2 ${id2:-rechazada})"
  else
    v="FALLA: quedaron $n y se esperaban $5 (S1 $id1, S2 ${id2:-rechazada})"
  fi
  echo "   $v"
  case "$v" in OK*) ;; *) FALLAS=$((FALLAS + 1)) ;; esac
}

mov() { echo "public.registrar_movimiento_empleado(p_empleado_id => $1, p_movimiento => '{\"tipo\":\"pago\",\"monto\":1000}'::jsonb, p_clave => '$2'::uuid)"; }
pagos() { echo "SELECT count(*) FROM empleado_movimientos WHERE empleado_id = $1 AND tipo = 'pago'"; }
# El JSON de ModalLiquidar para el próximo período del empleado (se arma una vez: el reintento manda lo mismo).
lqj() {
  psqlc <<SQL | tail -1
SELECT set_config('request.jwt.claims', json_build_object('sub', '$ADMIN', 'role', 'authenticated')::text, false),
       set_config('request.headers', json_build_object('x-sucursal-id', '$SUC')::text, false);
SET ROLE authenticated;
SELECT jsonb_build_object('desde', v#>>'{periodo,desde}', 'hasta', v#>>'{periodo,hasta}',
                          'sueldo', (v#>>'{sueldo,propuesto}')::numeric, 'motivo_sueldo', NULL, 'pago', 0,
                          'fecha_pago', public._tablero_hoy(), 'a_pagar_esperado', (v->>'a_pagar')::numeric)
  FROM (SELECT public.previsualizar_liquidacion(p_empleado_id => $1) AS v) x;
SQL
}
liq() { echo "public.liquidar_empleado(p_empleado_id => $1, p_liquidacion => '$2'::jsonb, p_clave => '$3'::uuid)"; }
liqs() { echo "SELECT count(*) FROM empleado_liquidaciones WHERE empleado_id = $1 AND anulada_at IS NULL"; }
uuid() { psqlc -c "SELECT gen_random_uuid()"; }
# Las claves que usa el guion, todas acá: al final se borran sólo ésas (el alta del empleado va sin clave).
K1=$(uuid); K2=$(uuid); K3=$(uuid); K4=$(uuid); K5=$(uuid); K6=$(uuid)

E=$(empleado | tail -1); CREADOS+=("$E")
escenario P1-pago-misma-clave "$(mov "$E" "$K1")" "$(mov "$E" "$K1")" "$(pagos "$E")" 1
E=$(empleado | tail -1); CREADOS+=("$E")
escenario P0-control-dos-claves "$(mov "$E" "$K2")" "$(mov "$E" "$K3")" "$(pagos "$E")" 2
E=$(empleado | tail -1); CREADOS+=("$E"); J=$(lqj "$E")
escenario L1-liquidacion-misma-clave "$(liq "$E" "$J" "$K4")" "$(liq "$E" "$J" "$K4")" "$(liqs "$E")" 1
if grep -q "^S2 id " "$TMP/t6c-L1-liquidacion-misma-clave-s2.out"; then :; else
  echo "   FALLA: en L1 S2 tenía que devolver la liquidación de S1, no rechazarse"; FALLAS=$((FALLAS + 1)); fi
E=$(empleado | tail -1); CREADOS+=("$E"); J=$(lqj "$E")
escenario L0-control-dos-claves "$(liq "$E" "$J" "$K5")" "$(liq "$E" "$J" "$K6")" "$(liqs "$E")" 1
grep -q "ya no es el próximo" "$TMP/t6c-L0-control-dos-claves-s2.out" \
  || { echo "   FALLA: en L0 S2 tenía que rechazarse por el período (es otra liquidación, no un reintento)"; FALLAS=$((FALLAS + 1)); }

IDS=$(IFS=,; echo "${CREADOS[*]}")
psqlc >/dev/null 2>&1 <<SQL
SET session_replication_role = replica;
DELETE FROM altas_por_clave WHERE clave IN ('$K1', '$K2', '$K3', '$K4', '$K5', '$K6');
DELETE FROM empleado_movimientos WHERE empleado_id IN ($IDS);
DELETE FROM empleado_liquidacion_conceptos WHERE liquidacion_id IN (SELECT id FROM empleado_liquidaciones WHERE empleado_id IN ($IDS));
DELETE FROM empleado_liquidacion_lineas WHERE empleado_id IN ($IDS);
DELETE FROM empleado_liquidaciones WHERE empleado_id IN ($IDS);
DELETE FROM empleado_arreglos WHERE empleado_id IN ($IDS);
DELETE FROM empleados WHERE id IN ($IDS);
SQL

if [ "$FALLAS" -gt 0 ]; then echo "FALLAN $FALLAS escenario(s)"; exit 1; fi
echo "OK: con la misma clave queda un solo pago y una sola liquidación; con dos claves (sin clave), el pago entra dos veces"
