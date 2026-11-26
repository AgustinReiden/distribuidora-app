#!/usr/bin/env bash
# El orden de los bloqueos de las rutas (pedidos → rutas → paradas, #1406) en los tres caminos que no lo seguían
# (#1432, ola 3, tarjeta T2 de #1677). Sesiones psql reales contra una base DESCARTABLE de Docker con la migración
# 554_ola3_t2_rutas_no_entregado. NUNCA contra prod.
#
#   CONTENEDOR=<contenedor> bash scripts/concurrencia/t2-rutas-orden-de-bloqueos.sh
#
# Ronda 1 · marcar_no_entregado contra la entrega del mismo pedido (VTA-06 incluido). T1 (la entrega: el pedido tomado,
#   una espera, y el UPDATE a entregado, cuyo trigger toma la ruta y la parada) toma P. T2 = marcar_no_entregado(P) del
#   chofer. Antes, T2 escribía la parada y esperaba el pedido; T1, al despertar, pedía la parada: 40P01. Con el
#   arreglo T2 espera el pedido primero, T1 entrega, y T2 se rechaza con «ya figura entregado» (no vuelve a pendiente).
#   Control negativo: marcar_no_entregado sin tomar el pedido ni las rutas antes de la parada: 40P01.
# Ronda 2 · _pedido_a_pendiente con un pedido ya pendiente, sin chofer ni orden, que sigue de parada en una ruta en curso
#   (su UPDATE no matchea y el trigger no toma la ruta). T1 toma la ruta, espera y borra la parada (el orden de
#   recalcular_recorrido y de quitar_pedido_de_recorridos_activos: ruta → parada). T2 = volver_pedido_a_pendiente(P).
#   Antes T2 borraba la parada y después pedía la ruta: 40P01. Con el arreglo T2 espera la ruta y pasan las dos.
#   Control negativo: _pedido_a_pendiente sin tomar las rutas al principio: 40P01.
# Ronda 3 · cambiar_transportista_recorrido contra la entrega de un pedido de esa ruta. T1 toma P, espera y lo entrega
#   (pedido → ruta). T2 = cambiar_transportista_recorrido(R, B). Antes T2 tomaba la ruta y pedía P: 40P01. Con el
#   arreglo T2 espera P primero; T1 entrega y T2 se rechaza con «ya tiene 1 entrega(s) hecha(s)».
#   Control negativo: cambiar_transportista_recorrido sin tomar los pedidos antes de la ruta: 40P01.
# Cada control cambia la función, corre la ronda y la deja como estaba. Los datos de cada ronda quedan en la base (es
# descartable). Sale con 1 si algo no da lo esperado.
set -u
C="${CONTENEDOR:?Falta CONTENEDOR (una base descartable de docker)}"
SLEEP="${SLEEP:-4}"
TMP="${TMPDIR:-/tmp}"
export MSYS_NO_PATHCONV=1
psqlc() { docker exec -i "$C" psql -U postgres -h localhost -d postgres -X -At -v ON_ERROR_STOP=1 "$@"; }
FALLA=0

# Una sesión como $1 (uuid) en la sucursal 1, que corre $2 y espera $3 segundos antes del COMMIT.
como() {
  printf "BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '%s', 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', '%s', true),
       set_config('request.headers', json_build_object('x-sucursal-id', '1')::text, true);
SET LOCAL ROLE authenticated;
%s;
SELECT pg_sleep(%s);
COMMIT;
" "$1" "$1" "$2" "$3" | psqlc
}

# La gente, el cliente y un pedido en la ruta de hoy de A. Deja E, A, B, P y R.
fixtures() {
  local tag="T2 locks $1 $(date +%s%N | cut -c1-15)"
  read -r E A B CLI P <<<"$(psqlc <<SQL | tail -1
WITH u AS (
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  SELECT gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         't2l-' || x.n || '-' || gen_random_uuid() || '@ensayo.invalid',
         jsonb_build_object('rol', x.rol, 'sucursal_id', 1), jsonb_build_object('nombre', '$tag ' || x.n), now(), now()
    FROM (VALUES (1, 'encargado'), (2, 'transportista'), (3, 'transportista')) x(n, rol)
  RETURNING id, raw_user_meta_data->>'nombre' AS nombre),
c AS (INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES ('$tag', '$tag', 'Calle T2', 1) RETURNING id),
p AS (INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por, sucursal_id)
      SELECT c.id, public._tablero_hoy(), 'pendiente', 1000, 0, 'pendiente', 'app', NULL, NULL, 1 FROM c
      RETURNING id)
SELECT (SELECT id FROM u WHERE nombre LIKE '% 1') || ' ' || (SELECT id FROM u WHERE nombre LIKE '% 2') || ' ' ||
       (SELECT id FROM u WHERE nombre LIKE '% 3') || ' ' || (SELECT id FROM c) || ' ' || (SELECT id FROM p);
SQL
)"
  R=$(como "$E" "SELECT 'RUTA ' || public.aplicar_orden_ruta('$A'::uuid, '[{\"pedido_id\": $P, \"orden_entrega\": 1}]'::jsonb, NULL, NULL, NULL, public._tablero_hoy())" 0 \
    | sed -n 's/^RUTA //p')
}

# T1 de las rondas 1 y 3: toma P como lo toma una entrega o un cobro, espera, y lo entrega (el trigger toma la ruta y
# la parada).
entrega_lenta() {
  printf "BEGIN; SELECT 1 FROM pedidos WHERE id = %s FOR UPDATE; SELECT pg_sleep(%s);
UPDATE pedidos SET estado = 'entregado', fecha_entrega = now() WHERE id = %s; SELECT 'T1 entregado'; COMMIT;\n" \
    "$P" "$SLEEP" "$P" | psqlc
}

guardar() { psqlc -c "SELECT pg_get_functiondef('$1'::regprocedure)" > "$TMP/t2l-$2.sql"; }
restaurar() { { cat "$TMP/t2l-$2.sql"; echo ";"; } | psqlc >/dev/null; }
# Saca de la función $1 el texto que matchea la regexp $2 (o falla si no lo encuentra).
mutar() {
  psqlc >/dev/null <<SQL
DO \$m\$
DECLARE v text := pg_get_functiondef('$1'::regprocedure); n text;
BEGIN
  n := regexp_replace(v, \$re\$$2\$re\$, '');
  IF n = v THEN RAISE EXCEPTION 'el control no encontró el bloque'; END IF;
  EXECUTE n;
END \$m\$;
SQL
}

veredicto() {  # $1 esperado (sin_deadlock | deadlock), $2 regexp que tiene que salir sin deadlock
  local out="$TMP/t2l-t1.out $TMP/t2l-t2.out"
  grep -h -E "^T[12] |ERROR|deadlock" $out | sed 's/^/   /'
  if grep -q -i "deadlock" $out; then d=1; else d=0; fi
  if [ "$1" = "deadlock" ]; then
    if [ "$d" = "1" ]; then echo "   OK (control): sin el arreglo, 40P01"; else echo "   FALLA el control: no hubo deadlock"; FALLA=1; fi
  else
    if [ "$d" = "0" ] && grep -q -E "$2" $out; then echo "   OK: sin deadlock"; else echo "   FALLA: deadlock $d"; FALLA=1; fi
  fi
}

# --------------------------------------------------------------------- ronda 1
ronda1() {
  fixtures r1
  ( entrega_lenta > "$TMP/t2l-t1.out" 2>&1 ) &
  sleep 1
  como "$A" "SELECT 'T2 ' || public.marcar_no_entregado($P, 'cerrado', NULL)::text" 0 > "$TMP/t2l-t2.out" 2>&1
  wait
  echo "   pedido #$P: $(psqlc -c "SELECT estado FROM pedidos WHERE id = $P")"
}
F_NE='public.marcar_no_entregado(bigint,character varying,text)'
echo "== ronda 1 · marcar_no_entregado contra la entrega del mismo pedido (con el arreglo)"
ronda1
veredicto sin_deadlock 'ya figura entregado'
echo "== ronda 1 · control negativo: sin tomar el pedido ni las rutas antes de la parada"
guardar "$F_NE" ne
mutar "$F_NE" '\n  FOR UPDATE(?=;)'
psqlc >/dev/null <<'SQL'
DO $m$
DECLARE v text := pg_get_functiondef('public.marcar_no_entregado(bigint,character varying,text)'::regprocedure); n text;
BEGIN
  n := regexp_replace(v, '  -- mig NNN \(#1432\): las rutas del pedido, por id, antes de su parada\..*?FOR NO KEY UPDATE;\n', '');
  IF n = v THEN RAISE EXCEPTION 'el control no encontró el bloque de las rutas'; END IF;
  EXECUTE n;
END $m$;
SQL
ronda1
restaurar "$F_NE" ne
veredicto deadlock ''

# --------------------------------------------------------------------- ronda 2
ronda2() {
  fixtures r2
  # P queda pendiente, sin chofer ni orden, y sigue de parada en la ruta en curso de A.
  psqlc -c "UPDATE pedidos SET estado = 'pendiente', transportista_id = NULL, orden_entrega = NULL WHERE id = $P" >/dev/null
  ( printf "BEGIN; SELECT 1 FROM recorridos WHERE id = %s FOR NO KEY UPDATE; SELECT pg_sleep(%s);
DELETE FROM recorrido_pedidos WHERE recorrido_id = %s AND pedido_id = %s; SELECT 'T1 parada borrada'; COMMIT;\n" \
      "$R" "$SLEEP" "$R" "$P" | psqlc > "$TMP/t2l-t1.out" 2>&1 ) &
  sleep 1
  como "$E" "SELECT 'T2 ' || public.volver_pedido_a_pendiente($P)::text" 0 > "$TMP/t2l-t2.out" 2>&1
  wait
}
F_PP='public._pedido_a_pendiente(bigint,bigint,text)'
echo "== ronda 2 · _pedido_a_pendiente con la parada en una ruta en curso (con el arreglo)"
ronda2
veredicto sin_deadlock '^T2 '
echo "== ronda 2 · control negativo: sin tomar las rutas al principio"
guardar "$F_PP" pp
mutar "$F_PP" '  -- mig NNN \(#1432\): las rutas del pedido, por id, antes de tocar nada.*?FOR NO KEY UPDATE;\n'
ronda2
restaurar "$F_PP" pp
veredicto deadlock ''

# --------------------------------------------------------------------- ronda 3
ronda3() {
  fixtures r3
  ( entrega_lenta > "$TMP/t2l-t1.out" 2>&1 ) &
  sleep 1
  como "$E" "SELECT 'T2 ' || public.cambiar_transportista_recorrido($R, '$B'::uuid)" 0 > "$TMP/t2l-t2.out" 2>&1
  wait
}
F_CT='public.cambiar_transportista_recorrido(bigint,uuid)'
echo "== ronda 3 · cambiar_transportista_recorrido contra la entrega de un pedido de la ruta (con el arreglo)"
ronda3
veredicto sin_deadlock 'entrega\(s\) hecha'
echo "== ronda 3 · control negativo: la ruta antes que los pedidos"
guardar "$F_CT" ct
mutar "$F_CT" '\n           ORDER BY p\.id\n             FOR NO KEY UPDATE'
ronda3
restaurar "$F_CT" ct
veredicto deadlock ''

# Las funciones quedaron como las deja la migración.
psqlc -c "SELECT md5(prosrc) FROM pg_proc WHERE oid IN ('$F_NE'::regprocedure, '$F_PP'::regprocedure, '$F_CT'::regprocedure) ORDER BY oid" \
  | sed 's/^/   md5 /'

[ "$FALLA" = "0" ] && echo "TODO OK" || echo "HUBO FALLAS"
exit "$FALLA"
