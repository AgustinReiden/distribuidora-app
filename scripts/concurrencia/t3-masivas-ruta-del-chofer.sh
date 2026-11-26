#!/usr/bin/env bash
# La ruta del chofer que entrega, con otra sesión en el medio (Rut-B5, ola 3, tarjeta T3 de #1677; revisión de
# c38729c2). Sesiones psql reales contra una base DESCARTABLE de Docker con la migración 550_ola3_rutas_paradas_canjes.
# NUNCA contra prod.
#
#   CONTENEDOR=<contenedor> bash scripts/concurrencia/t3-masivas-ruta-del-chofer.sh
#
# Ronda 1 · dos masivas cruzadas. R_B (de B, con Q1) tiene un id menor que R_A (de A, con P y Q2).
#   S0 toma el cliente de P y espera. T1 = marcar_entrega_y_pago_masivo([P], B): toma P y sus rutas y queda frenado en
#   el cliente (el pago). T2 = marcar_entregas_masivo([Q1, Q2], A): toma Q1, Q2 y sus rutas. Cuando S0 suelta, el
#   trigger de la entrega de T1 pide la ruta de B (la entrega se mueve ahí). Con el arreglo, T1 ya la tenía (su
#   pre-lock suma la ruta en curso del chofer que entrega) y T2 la esperaba: pasan las dos.
#   Control negativo: con el pre-lock de marcar_entrega_y_pago_masivo_impl sin esa ruta, 40P01.
# Ronda 3 · dos masivas SIN pago cruzadas, con los roles invertidos. La cláusula nueva de marcar_entregas_masivo (su
#   pre-lock suma la ruta en curso del chofer que entrega) sólo se ejerce si los pedidos NO están en esa ruta: en la
#   ronda 1, T2 ya toma R_A por Q2. Acá cada masiva entrega un pedido de la ruta del OTRO chofer, a nombre del suyo:
#   T1 = marcar_entregas_masivo([Q1 (de R_B)], A) y T2 = marcar_entregas_masivo([Q2 (de R_A)], B). La ruta del chofer
#   sólo la pide el trigger (la entrega se mueve a ella), así que sin la cláusula T1 tiene R_B, T2 tiene R_A, y cada una
#   pide la del otro. Como esta masiva no tiene dónde frenarse (no hay pago ni cliente), el ensayo le mete un
#   pg_sleep justo después del pre-lock (las dos corren la MISMA función, con la espera puesta) para que la carrera sea
#   determinista: con la cláusula, la primera toma las dos rutas por id y la otra espera; sin ella, 40P01.
#   Control negativo: la misma función con la espera y sin la cláusula.
# Ronda 2 · la ruta de B cambia de chofer mientras la entrega espera su lock. S0 = cambiar_transportista_recorrido(R_B, C)
#   y espera antes del COMMIT. T1 entrega P (de la ruta de A) a nombre de B: el trigger ve R_B como de B, espera el
#   lock y, cuando S0 confirma, R_B ya es de C. Con el arreglo la vuelve a mirar y sigue como «B sin ruta»: P queda
#   entregado en la ruta de A y la de C no gana una parada.
#   Control negativo: sin volver a mirar la ruta, la entrega de B cuenta en la ruta de C.
# Cada control cambia la función, corre la ronda y la deja como estaba. Los datos de cada ronda quedan en la base
# (es descartable). Sale con 1 si algo no da lo esperado.
set -u
C="${CONTENEDOR:?Falta CONTENEDOR (una base descartable de docker)}"
SLEEP="${SLEEP:-6}"
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

# Crea la gente, el cliente y los pedidos de una ronda. Deja en el entorno E, A, B, CH, CLI, P, Q1 y Q2.
fixtures() {
  local tag="T3 masivas $1 $(date +%s%N | cut -c1-15)"
  read -r E A B CH CLI P Q1 Q2 <<<"$(psqlc <<SQL | tail -1
WITH u AS (
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  SELECT gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         't3m-' || x.n || '-' || gen_random_uuid() || '@ensayo.invalid',
         jsonb_build_object('rol', x.rol, 'sucursal_id', 1), jsonb_build_object('nombre', '$tag ' || x.n), now(), now()
    FROM (VALUES (1, 'encargado'), (2, 'transportista'), (3, 'transportista'), (4, 'transportista')) x(n, rol)
  RETURNING id, raw_user_meta_data->>'nombre' AS nombre),
c AS (INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES ('$tag', '$tag', 'Calle T3', 1) RETURNING id),
p AS (INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por, sucursal_id)
      SELECT c.id, public._tablero_hoy(), 'pendiente', 1000, 0, 'pendiente', 'app', NULL, NULL, 1 FROM c, generate_series(1, 3)
      RETURNING id)
SELECT (SELECT id FROM u WHERE nombre LIKE '% 1') || ' ' || (SELECT id FROM u WHERE nombre LIKE '% 2') || ' ' ||
       (SELECT id FROM u WHERE nombre LIKE '% 3') || ' ' || (SELECT id FROM u WHERE nombre LIKE '% 4') || ' ' ||
       (SELECT id FROM c) || ' ' || (SELECT string_agg(id::text, ' ' ORDER BY id) FROM p);
SQL
)"
}

ruta() {  # $1 chofer, $2 lista de pedidos (JSON). Devuelve el id de la ruta.
  como "$E" "SELECT 'RUTA ' || public.aplicar_orden_ruta('$1'::uuid, '$2'::jsonb, NULL, NULL, NULL, public._tablero_hoy())" 0 \
    | sed -n 's/^RUTA //p'
}

guardar() { psqlc -c "SELECT pg_get_functiondef('$1'::regprocedure)" > "$TMP/t3m-$2.sql"; }
restaurar() { { cat "$TMP/t3m-$2.sql"; echo ";"; } | psqlc >/dev/null; }

# --------------------------------------------------------------------- ronda 1
ronda1() {
  fixtures r1
  local rb ra
  rb=$(ruta "$B" "[{\"pedido_id\": $Q1, \"orden_entrega\": 1}]")
  ra=$(ruta "$A" "[{\"pedido_id\": $P, \"orden_entrega\": 1}, {\"pedido_id\": $Q2, \"orden_entrega\": 2}]")
  ( printf "BEGIN; SELECT 1 FROM clientes WHERE id = %s FOR UPDATE; SELECT pg_sleep(%s); COMMIT;\n" "$CLI" "$SLEEP" | psqlc > /dev/null 2>&1 ) &
  sleep 1
  ( como "$E" "SELECT 'T1 ' || public.marcar_entrega_y_pago_masivo(ARRAY[$P]::bigint[], '$B'::uuid, 'efectivo', public._tablero_hoy(), gen_random_uuid())" 0 \
      > "$TMP/t3m-r1-t1.out" 2>&1 ) &
  sleep 2
  como "$E" "SELECT 'T2 ' || public.marcar_entregas_masivo(ARRAY[$Q1, $Q2]::bigint[], '$A'::uuid, public._tablero_hoy())" 0 \
    > "$TMP/t3m-r1-t2.out" 2>&1
  wait
  grep -h -E "^T[12] |ERROR|deadlock" "$TMP/t3m-r1-t1.out" "$TMP/t3m-r1-t2.out" | sed 's/^/   /'
  DEADLOCK=0; grep -q -i "deadlock" "$TMP/t3m-r1-t1.out" "$TMP/t3m-r1-t2.out" && DEADLOCK=1
  OKS=$(cat "$TMP/t3m-r1-t1.out" "$TMP/t3m-r1-t2.out" | grep -c -E "^T[12] ")
  echo "   rutas: B #$rb, A #$ra"
}

echo "== ronda 1 · dos masivas cruzadas (con el arreglo)"
ronda1
if [ "$DEADLOCK" = "0" ] && [ "$OKS" = "2" ]; then echo "   OK: pasaron las dos, sin deadlock"; else echo "   FALLA: deadlock $DEADLOCK, pasaron $OKS"; FALLA=1; fi

echo "== ronda 1 · control negativo: el pre-lock de la masiva con pago sin la ruta del chofer"
guardar 'public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)' impl
psqlc >/dev/null <<'SQL'
DO $m$
DECLARE v text := pg_get_functiondef('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)'::regprocedure);
        n text;
BEGIN
  n := regexp_replace(v, '\n\s*-- mig NNN \(Rut-B5, revisión\): y la ruta en curso.*?AND estado = ''en_curso'' AND fecha = p_fecha\)', '');
  IF n = v THEN RAISE EXCEPTION 'el control no encontró el pre-lock'; END IF;
  EXECUTE n;
END $m$;
SQL
ronda1
restaurar 'public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)' impl
if [ "$DEADLOCK" = "1" ]; then echo "   OK (control): sin el arreglo, 40P01"; else echo "   FALLA el control: no hubo deadlock (pasaron $OKS)"; FALLA=1; fi

# --------------------------------------------------------------------- ronda 3
# Aplica a marcar_entregas_masivo una espera de $SLEEP s después de su pre-lock de rutas y, con $1 = sin_clausula,
# además le saca la ruta del chofer del pre-lock.
mutar_masivo() {
  sed -e "s/__SLEEP__/$SLEEP/" -e "s/__MODO__/$1/" <<'SQL' | psqlc >/dev/null
DO $m$
DECLARE v text := pg_get_functiondef('public.marcar_entregas_masivo(bigint[],uuid,date)'::regprocedure);
        n text;
BEGIN
  n := v;
  IF '__MODO__' = 'sin_clausula' THEN
    n := regexp_replace(n, '\n\s*-- mig NNN \(Rut-B5, revisión\): y la ruta en curso.*?AND estado = ''en_curso'' AND fecha = p_fecha\)', '');
    IF n = v THEN RAISE EXCEPTION 'el control no encontró la cláusula'; END IF;
  END IF;
  v := n;
  n := replace(n, E'\n  -- #1342: con las rendiciones y los pedidos tomados.', E'\n  PERFORM pg_sleep(__SLEEP__);\n  -- #1342: con las rendiciones y los pedidos tomados.');
  IF n = v THEN RAISE EXCEPTION 'el control no encontró dónde poner la espera'; END IF;
  EXECUTE n;
END $m$;
SQL
}

ronda3() {
  fixtures r3
  local rb ra
  rb=$(ruta "$B" "[{\"pedido_id\": $Q1, \"orden_entrega\": 1}]")
  ra=$(ruta "$A" "[{\"pedido_id\": $Q2, \"orden_entrega\": 1}]")
  ( como "$E" "SELECT 'T1 ' || public.marcar_entregas_masivo(ARRAY[$Q1]::bigint[], '$A'::uuid, public._tablero_hoy())" 0 \
      > "$TMP/t3m-r3-t1.out" 2>&1 ) &
  sleep 1
  como "$E" "SELECT 'T2 ' || public.marcar_entregas_masivo(ARRAY[$Q2]::bigint[], '$B'::uuid, public._tablero_hoy())" 0 \
    > "$TMP/t3m-r3-t2.out" 2>&1
  wait
  grep -h -E "^T[12] |ERROR|deadlock" "$TMP/t3m-r3-t1.out" "$TMP/t3m-r3-t2.out" | sed 's/^/   /'
  DEADLOCK=0; grep -q -i "deadlock" "$TMP/t3m-r3-t1.out" "$TMP/t3m-r3-t2.out" && DEADLOCK=1
  OKS=$(cat "$TMP/t3m-r3-t1.out" "$TMP/t3m-r3-t2.out" | grep -c -E "^T[12] ")
  ENTREGADOS=$(psqlc -c "SELECT count(*) FROM pedidos WHERE id IN ($Q1, $Q2) AND estado = 'entregado'")
  echo "   rutas: B #$rb, A #$ra; entregados: $ENTREGADOS"
}

echo "== ronda 3 · dos masivas sin pago cruzadas, cada una con un pedido de la ruta del otro (con el arreglo, y la espera)"
guardar 'public.marcar_entregas_masivo(bigint[],uuid,date)' masivo
mutar_masivo con_clausula
ronda3
restaurar 'public.marcar_entregas_masivo(bigint[],uuid,date)' masivo
if [ "$DEADLOCK" = "0" ] && [ "$OKS" = "2" ] && [ "$ENTREGADOS" = "2" ]; then
  echo "   OK: pasaron las dos, sin deadlock, los dos pedidos entregados"
else echo "   FALLA: deadlock $DEADLOCK, pasaron $OKS, entregados $ENTREGADOS"; FALLA=1; fi

echo "== ronda 3 · control negativo: marcar_entregas_masivo sin la ruta del chofer en su pre-lock"
mutar_masivo sin_clausula
ronda3
restaurar 'public.marcar_entregas_masivo(bigint[],uuid,date)' masivo
if [ "$DEADLOCK" = "1" ]; then echo "   OK (control): sin el arreglo, 40P01"; else echo "   FALLA el control: no hubo deadlock (pasaron $OKS)"; FALLA=1; fi

# --------------------------------------------------------------------- ronda 2
ronda2() {
  fixtures r2
  local rb ra
  rb=$(ruta "$B" "[{\"pedido_id\": $Q1, \"orden_entrega\": 1}]")
  ra=$(ruta "$A" "[{\"pedido_id\": $P, \"orden_entrega\": 1}]")
  ( como "$E" "SELECT 'S0 ' || public.cambiar_transportista_recorrido($rb, '$CH'::uuid)" "$SLEEP" > "$TMP/t3m-r2-s0.out" 2>&1 ) &
  sleep 2
  # La entrega como la hace el chofer por REST: un UPDATE del pedido (acá, como el servidor).
  psqlc -c "UPDATE pedidos SET estado = 'entregado', fecha_entrega = now(), transportista_id = '$B' WHERE id = $P" \
    > "$TMP/t3m-r2-t1.out" 2>&1
  wait
  grep -h -E "^S0 |ERROR" "$TMP/t3m-r2-s0.out" "$TMP/t3m-r2-t1.out" | sed 's/^/   /'
  EN_A=$(psqlc -c "SELECT COALESCE((SELECT estado_entrega FROM recorrido_pedidos WHERE recorrido_id = $ra AND pedido_id = $P), '-')")
  EN_C=$(psqlc -c "SELECT COALESCE((SELECT estado_entrega FROM recorrido_pedidos WHERE recorrido_id = $rb AND pedido_id = $P), '-')")
  DE=$(psqlc -c "SELECT transportista_id = '$CH' FROM recorridos WHERE id = $rb")
  echo "   P en la ruta de A: $EN_A · en la ruta #$rb (ahora de C: $DE): $EN_C"
}

echo "== ronda 2 · la ruta de B pasa a C mientras la entrega de B espera (con el arreglo)"
ronda2
if [ "$DE" = "t" ] && [ "$EN_A" = "entregado" ] && [ "$EN_C" = "-" ]; then
  echo "   OK: B quedó «sin ruta»; P entregado en la ruta de A, nada en la de C"
else echo "   FALLA"; FALLA=1; fi

echo "== ronda 2 · control negativo: sin volver a mirar la ruta después del lock"
guardar 'public.actualizar_recorrido_entrega()' trigger
psqlc >/dev/null <<'SQL'
DO $m$
DECLARE v text := pg_get_functiondef('public.actualizar_recorrido_entrega()'::regprocedure);
BEGIN
  IF strpos(v, '    v_ruta_chofer := NULL;') = 0 THEN RAISE EXCEPTION 'el control no encontró la revalidación'; END IF;
  EXECUTE replace(v, '    v_ruta_chofer := NULL;', '    NULL;');
END $m$;
SQL
ronda2
restaurar 'public.actualizar_recorrido_entrega()' trigger
if [ "$EN_C" = "entregado" ]; then echo "   OK (control): sin el arreglo, la entrega de B cuenta en la ruta de C"; else echo "   FALLA el control"; FALLA=1; fi

exit $FALLA
