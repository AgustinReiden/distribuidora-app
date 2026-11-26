#!/usr/bin/env bash
# El GPS del alta y el de la cola, a la vez (permisos-B4, ola 3, tanda T8b de #1690; mig NNN_ola3_t8b_pedido_gps).
# Sesiones psql reales contra una base DESCARTABLE de Docker con la migración aplicada. NUNCA contra prod.
#
#   CONTENEDOR=<contenedor> bash scripts/concurrencia/t8b-gps-alta-y-cola.sh
#
# Ronda · S1 = el alta: registrar_geolocalizacion_pedido(ok, con coordenadas) y espera $SLEEP s antes del COMMIT.
#   S2 = el replay de la cola del mismo pedido: registrar_geolocalizacion_pedido(denied). Su SELECT previo no ve la
#   fila de S1 (sin COMMIT), así que va al INSERT y espera en la clave (pedido_id). Cuando S1 confirma, el
#   ON CONFLICT … DO UPDATE de S2 ve el ok y su guarda (`WHERE g.gps_status <> 'ok' AND EXCLUDED.gps_status = 'ok'`)
#   no lo pisa: S2 devuelve ya_registrado y la fila queda ok con sus coordenadas.
#   Control negativo: la misma ronda con la RPC sin esa guarda. El denied pisa el ok y se pierden las coordenadas.
# El control cambia la función, corre la ronda y la deja como estaba. Los datos quedan en la base (es
# descartable). Sale con 1 si algo no da lo esperado.
set -u
C="${CONTENEDOR:?Falta CONTENEDOR (una base descartable de docker)}"
SLEEP="${SLEEP:-4}"
TMP="${TMPDIR:-/tmp}"
export MSYS_NO_PATHCONV=1
psqlc() { docker exec -i "$C" psql -U postgres -h localhost -d postgres -X -At -v ON_ERROR_STOP=1 "$@"; }
FALLA=0
F_GEO='public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)'

# Una sesión como $1 (uuid) en la sucursal 1, que corre $2 y espera $3 segundos antes del COMMIT.
como() {
  printf "BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '%s', 'role', 'authenticated')::text, true),
       set_config('request.headers', json_build_object('x-sucursal-id', '1')::text, true);
SET LOCAL ROLE authenticated;
%s;
SELECT pg_sleep(%s);
COMMIT;
" "$1" "$2" "$3" | psqlc
}

# Un preventista nuevo de la sucursal 1, un cliente y un pedido suyo. Deja PREV y PED en el entorno.
fixtures() {
  local tag="T8b gps $(date +%s%N | cut -c1-15)"
  read -r PREV PED <<<"$(psqlc <<SQL | tail -1
WITH u AS (
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't8b-' || gen_random_uuid() || '@ensayo.invalid',
          jsonb_build_object('rol', 'preventista', 'sucursal_id', 1), jsonb_build_object('nombre', '$tag'), now(), now())
  RETURNING id),
c AS (INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES ('$tag', '$tag', 'Calle T8b', 1) RETURNING id),
p AS (INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, sucursal_id)
      SELECT c.id, public._tablero_hoy(), 'pendiente', 1000, 0, 'pendiente', 'app', u.id, 1 FROM c, u
      RETURNING id)
SELECT (SELECT id FROM u) || ' ' || (SELECT id FROM p);
SQL
)"
}

ronda() {
  fixtures
  ( como "$PREV" "SELECT 'S1 ' || public.registrar_geolocalizacion_pedido(p_pedido_id => $PED, p_status => 'ok', p_lat => -26.8241, p_lng => -65.2226, p_accuracy => 12.5)::text" "$SLEEP" \
      > "$TMP/t8b-s1.out" 2>&1 ) &
  sleep 1
  como "$PREV" "SELECT 'S2 ' || public.registrar_geolocalizacion_pedido(p_pedido_id => $PED, p_status => 'denied', p_motivo_omision => 'cola')::text" 0 \
    > "$TMP/t8b-s2.out" 2>&1
  wait
  grep -h -E "^S[12] |ERROR" "$TMP/t8b-s1.out" "$TMP/t8b-s2.out" | sed 's/^/   /'
  FILA=$(psqlc -c "SELECT gps_status || ' ' || COALESCE(gps_lat::text, '-') || ' ' || COALESCE(gps_lng::text, '-') FROM pedido_gps WHERE pedido_id = $PED")
  S2_YA=$(grep -c '"ya_registrado": true' "$TMP/t8b-s2.out")
  echo "   pedido $PED: pedido_gps = $FILA; S2 ya_registrado: $S2_YA"
}

echo "== el alta (ok) y la cola (denied) del mismo pedido a la vez"
ronda
if [ "$FILA" = "ok -26.8241000 -65.2226000" ] && [ "$S2_YA" = "1" ]; then
  echo "   OK: quedó el ok con sus coordenadas; la cola devolvió ya_registrado"
else echo "   FALLA: quedó «$FILA» (ya_registrado: $S2_YA)"; FALLA=1; fi

echo "== control negativo: la RPC sin la guarda del DO UPDATE"
psqlc -c "SELECT pg_get_functiondef('$F_GEO'::regprocedure)" > "$TMP/t8b-geo.sql"
psqlc >/dev/null <<SQL
DO \$m\$
DECLARE v text := pg_get_functiondef('$F_GEO'::regprocedure);
        n text;
BEGIN
  n := replace(v, E'\n  WHERE g.gps_status <> ''ok'' AND EXCLUDED.gps_status = ''ok'';', ';');
  IF n = v THEN RAISE EXCEPTION 'el control no encontró la guarda'; END IF;
  EXECUTE n;
END \$m\$;
SQL
ronda
{ cat "$TMP/t8b-geo.sql"; echo ";"; } | psqlc >/dev/null
if [ "$FILA" = "denied - -" ]; then
  echo "   OK (control): sin la guarda, el denied pisó el ok ($FILA)"
else echo "   FALLA el control: el ok quedó igual sin la guarda"; FALLA=1; fi

exit $FALLA
