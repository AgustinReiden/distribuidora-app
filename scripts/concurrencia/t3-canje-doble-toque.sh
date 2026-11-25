#!/usr/bin/env bash
# El doble toque del canje (Rut-B8, ola 3, tarjeta T3 de #1677). Dos sesiones psql reales contra una base
# DESCARTABLE de Docker: S1 registra un canje por registrar_cambio_producto y espera antes del COMMIT; S2
# arranca después con lo mismo. NUNCA contra prod.
#
#   CONTENEDOR=<contenedor> bash scripts/concurrencia/t3-canje-doble-toque.sh
#
# Dos rondas:
#   1 · con la MISMA clave (p_clave): S2 espera en la PK de altas_por_clave a que S1 confirme y devuelve el
#       canje de S1, sin mover el stock otra vez. Queda UN canje y el stock entregado baja 2, no 4.
#   2 · control negativo, SIN clave (un PWA de antes): las dos pasan y quedan DOS canjes. Es lo que pasaba
#       siempre, y prueba que las sesiones se cruzan de verdad (si no, la ronda 1 no probaría nada).
# Sin la migración (NNN_ola3_rutas_paradas_canjes) la ronda 1 falla: p_clave no existe. Al final borra lo
# que creó. Sale con 1 si la ronda 1 no deja un solo canje o si las sesiones no se cruzaron.
set -u
C="${CONTENEDOR:?Falta CONTENEDOR (una base descartable de docker)}"
SLEEP="${SLEEP:-6}"
TMP="${TMPDIR:-/tmp}"
export MSYS_NO_PATHCONV=1
psqlc() { docker exec -i "$C" psql -U postgres -h localhost -d postgres -X -At -v ON_ERROR_STOP=1 "$@"; }

TAG="T3 canje $(date +%s%N | cut -c1-15)"
U=$(psqlc -c "SELECT gen_random_uuid()")
CLAVE=$(psqlc -c "SELECT gen_random_uuid()")

IDS=$(psqlc <<SQL
INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES ('$U', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't3-$U@ensayo.invalid',
        '{"rol":"encargado","sucursal_id":1}', '{"nombre":"$TAG"}', now(), now());
WITH c AS (INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
           VALUES ('$TAG', '$TAG', 'Calle T3', 1) RETURNING id),
     d AS (INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
           VALUES ('$TAG devuelto', 100, 1000, 60, 1) RETURNING id),
     e AS (INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
           VALUES ('$TAG entregado', 100, 1000, 60, 1) RETURNING id)
SELECT c.id || ' ' || d.id || ' ' || e.id FROM c, d, e;
SQL
) || { echo "no se pudieron crear los datos"; exit 2; }
read -r CLI DEV ENT <<<"$(echo "$IDS" | tail -1)"

# $1 S1|S2, $2 segundos antes del COMMIT, $3 la clave ('' = sin clave), $4 observaciones
canje() {
  local clave_arg=""
  [ -n "$3" ] && clave_arg=", p_clave => '$3'::uuid"
  printf "BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '%s', 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', '%s', true),
       set_config('request.headers', json_build_object('x-sucursal-id', '1')::text, true);
SET LOCAL ROLE authenticated;
SELECT '%s empieza ' || clock_timestamp();
SELECT '%s canje ' || public.registrar_cambio_producto(p_cliente_id => %s, p_producto_devuelto_id => %s,
         p_cantidad_devuelta => 2, p_producto_entregado_id => %s, p_cantidad_entregada => 2,
         p_observaciones => '%s', p_motivo => 'erroneo'%s);
SELECT pg_sleep(%s);
SELECT '%s confirma ' || clock_timestamp();
COMMIT;
" "$U" "$U" "$1" "$1" "$CLI" "$DEV" "$ENT" "$4" "$clave_arg" "$2" "$1" | psqlc
}

# $1 ronda, $2 clave ('' = sin clave). Deja en N la cantidad de canjes y en ST el stock entregado.
ronda() {
  local obs="$TAG r$1"
  ( canje S1 "$SLEEP" "$2" "$obs" > "$TMP/t3-r$1-s1.out" 2>&1 ) &
  sleep 2
  canje S2 0 "$2" "$obs" > "$TMP/t3-r$1-s2.out" 2>&1
  wait
  N=$(psqlc -c "SELECT count(*) FROM cambios_productos WHERE observaciones = '$obs'")
  ST=$(psqlc -c "SELECT stock FROM productos WHERE id = $ENT")
  grep -h -E "^S[12] |ERROR|deadlock" "$TMP/t3-r$1-s1.out" "$TMP/t3-r$1-s2.out" | sed 's/^/   /'
  S2E=$(sed -n 's/^S2 empieza //p' "$TMP/t3-r$1-s2.out")
  S1C=$(sed -n 's/^S1 confirma //p' "$TMP/t3-r$1-s1.out")
  CRUCE=1
  if [ -z "$S2E" ] || [ -z "$S1C" ] || [[ ! "$S2E" < "$S1C" ]]; then CRUCE=0; fi
}

FALLA=0
echo "== ronda 1 · dos toques a la vez con la misma clave"
ronda 1 "$CLAVE"
ID1=$(sed -n 's/^S1 canje //p' "$TMP/t3-r1-s1.out"); ID2=$(sed -n 's/^S2 canje //p' "$TMP/t3-r1-s2.out")
if [ "$CRUCE" != "1" ]; then
  echo "   NO SE CRUZARON: subí SLEEP"; FALLA=1
elif [ "$N" = "1" ] && [ "$ST" = "998" ] && [ -n "$ID1" ] && [ "$ID1" = "$ID2" ]; then
  echo "   OK: S2 esperó a S1 y devolvió su canje (#$ID1); queda 1 canje y el stock entregado en $ST"
else
  echo "   FALLA: quedaron $N canje(s) (ids '$ID1' y '$ID2') y el stock entregado en $ST (se esperaba 1 y 998)"; FALLA=1
fi

echo "== ronda 2 · control negativo: los mismos dos toques sin clave (un PWA de antes)"
ronda 2 ""
if [ "$CRUCE" = "1" ] && [ "$N" = "2" ]; then
  echo "   OK (control): sin clave las dos pasan y quedan 2 canjes, como siempre"
else
  echo "   FALLA el control: $N canje(s), cruce $CRUCE (se esperaban 2 y cruzadas)"; FALLA=1
fi

psqlc >/dev/null <<SQL
SET session_replication_role = replica;
DELETE FROM cambios_productos WHERE cliente_id = $CLI;
DELETE FROM stock_historico WHERE producto_id IN ($DEV, $ENT);
DELETE FROM audit_logs WHERE (tabla = 'productos' AND registro_id IN ('$DEV', '$ENT')) OR (tabla = 'clientes' AND registro_id = '$CLI');
DELETE FROM altas_por_clave WHERE usuario_id = '$U';
DELETE FROM productos WHERE id IN ($DEV, $ENT);
DELETE FROM clientes WHERE id = $CLI;
DELETE FROM usuario_sucursales WHERE usuario_id = '$U';
DELETE FROM perfil_roles WHERE usuario_id = '$U';
DELETE FROM perfiles WHERE id = '$U';
DELETE FROM auth.users WHERE id = '$U';
SQL
exit $FALLA
