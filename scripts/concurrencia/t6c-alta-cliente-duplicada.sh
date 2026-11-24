#!/usr/bin/env bash
# Dos altas de cliente a la vez en la misma dirección (catalogo-B9, tanda 6 de #1603). Dos sesiones psql
# reales contra una base DESCARTABLE de Docker: S1 da de alta «T6C Carrera <n>» por guardar_cliente y espera
# antes del COMMIT; S2 arranca después con la misma dirección (otra clave, otro usuario). NUNCA contra prod.
#
#   CONTENEDOR=<contenedor> bash scripts/concurrencia/t6c-alta-cliente-duplicada.sh
#
# Con la migración (NNN_catalogo_clientes_tanda6): S2 espera el lock de los duplicados de la sucursal y,
# cuando S1 confirma, ve el cliente y se rechaza («Ya hay un cliente en esa dirección…»): queda UN cliente.
# Sin ella, las dos pasan y quedan dos clientes en la misma puerta. Al final borra lo que creó.
# Sale con 1 si no queda uno solo.
set -u
C="${CONTENEDOR:?Falta CONTENEDOR (una base descartable de docker)}"
SLEEP="${SLEEP:-6}"
TMP="${TMPDIR:-/tmp}"
psqlc() { docker exec -i "$C" psql -U postgres -h localhost -d postgres -X -At -v ON_ERROR_STOP=1 "$@"; }

DIR="T6C Carrera $(date +%s%N | cut -c1-15) 123"
U1=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || psqlc -c "SELECT gen_random_uuid()")
U2=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || psqlc -c "SELECT gen_random_uuid()")

psqlc >/dev/null <<SQL || { echo "no se pudieron crear los usuarios"; exit 2; }
INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES ('$U1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6c-$U1@ensayo.invalid',
        '{"rol":"preventista","sucursal_id":1}', '{"nombre":"T6C carrera 1"}', now(), now()),
       ('$U2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6c-$U2@ensayo.invalid',
        '{"rol":"preventista","sucursal_id":1}', '{"nombre":"T6C carrera 2"}', now(), now());
SQL

# $1 usuario, $2 S1|S2, $3 segundos de espera antes del COMMIT
alta() {
  printf "BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '%s', 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', '%s', true),
       set_config('request.headers', json_build_object('x-sucursal-id', '1')::text, true);
SET LOCAL ROLE authenticated;
SELECT '%s empieza ' || clock_timestamp();
SELECT '%s ' || (public.guardar_cliente(jsonb_build_object('clave', gen_random_uuid(), 'campos',
         jsonb_build_object('razon_social', '%s', 'nombre_fantasia', '%s', 'direccion', '%s')))->'cliente'->>'id');
SELECT pg_sleep(%s);
SELECT '%s confirma ' || clock_timestamp();
COMMIT;
" "$1" "$1" "$2" "$2" "$DIR" "$DIR" "$DIR" "$3" "$2" | psqlc
}

( alta "$U1" S1 "$SLEEP" > "$TMP/t6c-s1.out" 2>&1 ) &
sleep 2
alta "$U2" S2 0 > "$TMP/t6c-s2.out" 2>&1
wait

N=$(psqlc -c "SELECT count(*) FROM clientes WHERE direccion = '$DIR'")
echo "== dos altas a la vez en «$DIR»"
grep -h -E "^S[12] |ERROR|deadlock" "$TMP/t6c-s1.out" "$TMP/t6c-s2.out" | sed 's/^/   /'
S2E=$(sed -n 's/^S2 empieza //p' "$TMP/t6c-s2.out")
S1C=$(sed -n 's/^S1 confirma //p' "$TMP/t6c-s1.out")

psqlc >/dev/null <<SQL
DELETE FROM cliente_preventistas WHERE cliente_id IN (SELECT id FROM clientes WHERE direccion = '$DIR');
DELETE FROM altas_por_clave WHERE usuario_id IN ('$U1', '$U2');
DELETE FROM audit_logs WHERE tabla = 'clientes' AND registro_id IN (SELECT id::text FROM clientes WHERE direccion = '$DIR');
DELETE FROM clientes WHERE direccion = '$DIR';
DELETE FROM auth.users WHERE id IN ('$U1', '$U2');
SQL

if [ -z "$S2E" ] || [ -z "$S1C" ] || [[ ! "$S2E" < "$S1C" ]]; then
  echo "   NO SE CRUZARON (S2 empezó $S2E, S1 confirmó $S1C): subí SLEEP"; exit 1
fi
if [ "$N" = "1" ] && grep -q "Ya hay un cliente en esa dirección" "$TMP/t6c-s2.out"; then
  echo "   OK: S2 esperó a S1 y se rechazó por el duplicado; queda 1 cliente"
  exit 0
fi
echo "   FALLA: quedaron $N clientes en la misma dirección"
exit 1
