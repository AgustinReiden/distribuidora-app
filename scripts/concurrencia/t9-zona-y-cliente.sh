#!/usr/bin/env bash
# asignar_preventista_zona contra lo que cambia la zona a la vez (Var-B9, ola 3 de #1603, tarjeta T9). Dos
# sesiones psql reales contra una base DESCARTABLE de Docker (con la semilla: un admin de la sucursal 1).
# NUNCA contra prod.
#
#   CONTENEDOR=<contenedor> bash scripts/concurrencia/t9-zona-y-cliente.sh
#
# Z1 · S1 (admin) le pasa la zona Z de P0 a P1 y espera antes del COMMIT; S2 (admin) mete en Z, por REST, un
#      cliente X que estaba fuera. Con la migración (551_ola3_zonas_cartera_vehiculos) S1 tiene la zona tomada:
#      la FK de X espera, y el trigger del cambio de zona ve el dueño nuevo; X queda de P1. Sin ella, X queda
#      de P0 en una zona que es de P1 (ASG-A rojo).
# Z2 · S1 le pasa la zona a P1 y espera; S2 se la pasa a P2. Con la migración S2 espera la zona y gana: la
#      zona y todos sus clientes quedan de P2. Sin ella, S2 da un 23505 crudo («duplicate key value…»).
# Z3 · S1 le pasa la zona Z a P1 y espera; S2 se lleva un cliente de Z a la zona W, de P2. Con la migración S1
#      tiene tomados los clientes de Z: el cambio espera y su trigger deja el cliente sólo de P2. Sin ella (o sin
#      el lock de los clientes, aunque esté el de la zona), el cliente queda de P1 y de P2.
#
# Control negativo: correrlo sobre una base sin la migración tiene que dar FALLA en Z1, Z2 y Z3.
# Al final borra lo que creó. Sale con 1 si algún caso falla.
set -u
C="${CONTENEDOR:?Falta CONTENEDOR (una base descartable de docker)}"
SLEEP="${SLEEP:-5}"
TMP="${TMPDIR:-/tmp}"
psqlc() { docker exec -i "$C" psql -U postgres -h localhost -d postgres -X -At -v ON_ERROR_STOP=1 "$@"; }

ADM=$(psqlc -c "SELECT p.id FROM perfiles p JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = 1
                 WHERE p.rol = 'admin' AND p.activo ORDER BY p.id LIMIT 1")
[ -n "$ADM" ] || { echo "falta un admin activo de la sucursal 1 (la semilla)"; exit 2; }
P0=$(psqlc -c "SELECT gen_random_uuid()"); P1=$(psqlc -c "SELECT gen_random_uuid()"); P2=$(psqlc -c "SELECT gen_random_uuid()")
MARCA="T9 carrera $(date +%s%N | cut -c1-15)"

psqlc >/dev/null <<SQL || { echo "no se pudieron crear los datos"; exit 2; }
INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't9c-' || u || '@ensayo.invalid',
       '{"rol":"preventista","sucursal_id":1}', jsonb_build_object('nombre', 'T9 carrera ' || left(u::text, 4)), now(), now()
  FROM unnest(ARRAY['$P0', '$P1', '$P2']::uuid[]) u;
SQL

# Arma la zona Z (de P0, con dos clientes suyos) y un cliente X fuera de ella. Devuelve "Z X".
armar() {
  psqlc <<SQL
WITH z AS (INSERT INTO zonas (nombre, sucursal_id) VALUES ('$MARCA ' || gen_random_uuid(), 1) RETURNING id),
     pz AS (INSERT INTO preventista_zonas (perfil_id, zona_id, sucursal_id) SELECT '$P0', id, 1 FROM z),
     c AS (INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
           SELECT '$MARCA', '$MARCA ' || g, '$MARCA calle ' || g || ' ' || gen_random_uuid(), 1, z.id
             FROM z, generate_series(1, 2) g RETURNING id)
INSERT INTO cliente_preventistas (cliente_id, preventista_id) SELECT id, '$P0' FROM c;
INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
VALUES ('$MARCA', '$MARCA X', '$MARCA calle X ' || gen_random_uuid(), 1);
SELECT (SELECT max(id) FROM zonas WHERE nombre LIKE '$MARCA %') || ' ' ||
       (SELECT max(id) FROM clientes WHERE nombre_fantasia = '$MARCA X' AND zona_id IS NULL);
SQL
}

# $1 S1|S2, $2 sql, $3 segundos antes del COMMIT
sesion() {
  printf "BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '%s', 'role', 'authenticated')::text, true),
       set_config('request.headers', json_build_object('x-sucursal-id', '1')::text, true);
SET LOCAL ROLE authenticated;
SELECT '%s empieza ' || clock_timestamp();
%s
SELECT pg_sleep(%s);
SELECT '%s confirma ' || clock_timestamp();
COMMIT;
" "$ADM" "$1" "$2" "$3" "$1" | psqlc
}

cruzaron() {  # $1 caso
  local s2e s1c
  s2e=$(sed -n 's/^S2 empieza //p' "$TMP/t9-$1-s2.out"); s1c=$(sed -n 's/^S1 confirma //p' "$TMP/t9-$1-s1.out")
  if [ -z "$s2e" ] || [ -z "$s1c" ] || [[ ! "$s2e" < "$s1c" ]]; then
    echo "   NO SE CRUZARON (S2 empezó $s2e, S1 confirmó $s1c): subí SLEEP"; return 1
  fi
}

FALLAS=0

# ---------------------------------------------------------------------- Z1 ---
read -r Z X <<< "$(armar | tail -1)"
( sesion S1 "SELECT 'S1 ' || public.asignar_preventista_zona($Z, '$P1', false)::text;" "$SLEEP" > "$TMP/t9-z1-s1.out" 2>&1 ) &
sleep 2
sesion S2 "UPDATE public.clientes SET zona_id = $Z WHERE id = $X RETURNING 'S2 movido ' || id;" 0 > "$TMP/t9-z1-s2.out" 2>&1
wait
echo "== Z1 · asignar la zona $Z a P1 mientras el cliente $X entra a la zona"
grep -h -E "^S[12] (empieza|confirma|movido)|ERROR|deadlock" "$TMP/t9-z1-s1.out" "$TMP/t9-z1-s2.out" | sed 's/^/   /'
DUENOS=$(psqlc -c "SELECT string_agg(CASE preventista_id WHEN '$P0' THEN 'P0' WHEN '$P1' THEN 'P1' ELSE 'otro' END, ',')
                     FROM cliente_preventistas WHERE cliente_id = $X")
MAL=$(psqlc -c "SELECT count(*) FROM clientes c WHERE c.zona_id = $Z
                  AND (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id AND cp.preventista_id = '$P1')
                       OR EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id AND cp.preventista_id <> '$P1'))")
if ! cruzaron z1; then FALLAS=$((FALLAS+1))
elif [ "$DUENOS" = "P1" ] && [ "$MAL" = "0" ]; then echo "   OK: el cliente que entró a la zona quedó de P1, el dueño nuevo"
else echo "   FALLA: el cliente $X quedó de «$DUENOS»; clientes de la zona que no son sólo de P1: $MAL"; FALLAS=$((FALLAS+1)); fi

# ---------------------------------------------------------------------- Z2 ---
read -r Z X <<< "$(armar | tail -1)"
( sesion S1 "SELECT 'S1 ' || public.asignar_preventista_zona($Z, '$P1', false)::text;" "$SLEEP" > "$TMP/t9-z2-s1.out" 2>&1 ) &
sleep 2
sesion S2 "SELECT 'S2 ' || public.asignar_preventista_zona($Z, '$P2', false)::text;" 0 > "$TMP/t9-z2-s2.out" 2>&1
wait
echo "== Z2 · dos asignaciones de la zona $Z a la vez (P1 y P2)"
grep -h -E "^S[12] (empieza|confirma)|ERROR|deadlock" "$TMP/t9-z2-s1.out" "$TMP/t9-z2-s2.out" | sed 's/^/   /'
DUENO=$(psqlc -c "SELECT CASE perfil_id WHEN '$P1' THEN 'P1' WHEN '$P2' THEN 'P2' ELSE 'otro' END FROM preventista_zonas WHERE zona_id = $Z")
MAL=$(psqlc -c "SELECT count(*) FROM clientes c WHERE c.zona_id = $Z
                  AND (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id AND cp.preventista_id = '$P2')
                       OR EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id AND cp.preventista_id <> '$P2'))")
if ! cruzaron z2; then FALLAS=$((FALLAS+1))
elif [ "$DUENO" = "P2" ] && [ "$MAL" = "0" ] && ! grep -q "ERROR" "$TMP/t9-z2-s2.out"; then
  echo "   OK: S2 esperó la zona y la dejó de P2 con todos sus clientes"
else echo "   FALLA: la zona quedó de «$DUENO», clientes que no son sólo de P2: $MAL"; FALLAS=$((FALLAS+1)); fi

# ---------------------------------------------------------------------- Z3 ---
read -r Z X <<< "$(armar | tail -1)"
read -r W X2 <<< "$(armar | tail -1)"
psqlc >/dev/null <<SQL
UPDATE preventista_zonas SET perfil_id = '$P2' WHERE zona_id = $W;
UPDATE cliente_preventistas SET preventista_id = '$P2' WHERE cliente_id IN (SELECT id FROM clientes WHERE zona_id = $W);
SQL
C1=$(psqlc -c "SELECT min(id) FROM clientes WHERE zona_id = $Z")
( sesion S1 "SELECT 'S1 ' || public.asignar_preventista_zona($Z, '$P1', false)::text;" "$SLEEP" > "$TMP/t9-z3-s1.out" 2>&1 ) &
sleep 2
sesion S2 "UPDATE public.clientes SET zona_id = $W WHERE id = $C1 RETURNING 'S2 movido ' || id;" 0 > "$TMP/t9-z3-s2.out" 2>&1
wait
echo "== Z3 · asignar la zona $Z a P1 mientras su cliente $C1 se va a la zona $W (de P2)"
grep -h -E "^S[12] (empieza|confirma|movido)|ERROR|deadlock" "$TMP/t9-z3-s1.out" "$TMP/t9-z3-s2.out" | sed 's/^/   /'
DUENOS=$(psqlc -c "SELECT string_agg(CASE preventista_id WHEN '$P0' THEN 'P0' WHEN '$P1' THEN 'P1' WHEN '$P2' THEN 'P2' ELSE 'otro' END, ',' ORDER BY 1)
                     FROM cliente_preventistas WHERE cliente_id = $C1")
if ! cruzaron z3; then FALLAS=$((FALLAS+1))
elif [ "$DUENOS" = "P2" ]; then echo "   OK: el cliente que se fue quedó sólo de P2, el dueño de su zona nueva"
else echo "   FALLA: el cliente $C1, ahora en la zona $W, quedó de «$DUENOS»"; FALLAS=$((FALLAS+1)); fi

# ------------------------------------------------------------------ limpiar ---
psqlc >/dev/null <<SQL
DELETE FROM cliente_preventistas WHERE cliente_id IN (SELECT id FROM clientes WHERE razon_social = '$MARCA');
DELETE FROM preventista_zonas WHERE zona_id IN (SELECT id FROM zonas WHERE nombre LIKE '$MARCA %');
DELETE FROM audit_logs WHERE tabla IN ('clientes', 'cliente_preventistas')
   AND (new_data->>'razon_social' = '$MARCA' OR old_data->>'razon_social' = '$MARCA'
        OR new_data->>'preventista_id' IN ('$P0', '$P1', '$P2') OR old_data->>'preventista_id' IN ('$P0', '$P1', '$P2'));
DELETE FROM clientes WHERE razon_social = '$MARCA';
DELETE FROM zonas WHERE nombre LIKE '$MARCA %';
DELETE FROM auth.users WHERE id IN ('$P0', '$P1', '$P2');
SQL

[ "$FALLAS" = "0" ] && exit 0
exit 1
