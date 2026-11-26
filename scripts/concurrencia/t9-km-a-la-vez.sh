#!/usr/bin/env bash
# Dos registrar_km_vehiculo a la vez con la misma lectura (Var-B7, ola 3 de #1603, tarjeta T9). Dos sesiones
# psql reales contra una base DESCARTABLE de Docker (con la semilla: un admin de la sucursal 1). NUNCA contra prod.
#
#   CONTENEDOR=<contenedor> bash scripts/concurrencia/t9-km-a-la-vez.sh
#
# K1 · S1 (admin) registra la lectura de ayer del vehículo V y espera antes del COMMIT; S2 (admin) registra la
#      misma. Con la migración (NNN_ola3_zonas_cartera_vehiculos) registrar_km_vehiculo toma el vehículo
#      (FOR NO KEY UPDATE) antes de mirar la serie: S2 espera a S1, ve su lectura y se rechaza («ya está
#      cargada»); queda UNA. Sin la migración, o sin ese lock, las dos entran: S2 no ve lo que S1 no confirmó.
#
# Control negativo: correrlo sobre una base sin la migración (o con el lock sacado) tiene que dar FALLA.
# Al final borra lo que creó. Sale con 1 si quedan dos lecturas.
set -u
C="${CONTENEDOR:?Falta CONTENEDOR (una base descartable de docker)}"
SLEEP="${SLEEP:-5}"
TMP="${TMPDIR:-/tmp}"
psqlc() { docker exec -i "$C" psql -U postgres -h localhost -d postgres -X -At -v ON_ERROR_STOP=1 "$@"; }

ADM=$(psqlc -c "SELECT p.id FROM perfiles p JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = 1
                 WHERE p.rol = 'admin' AND p.activo ORDER BY p.id LIMIT 1")
[ -n "$ADM" ] || { echo "falta un admin activo de la sucursal 1 (la semilla)"; exit 2; }
PAT="ZT9K$(date +%s | tail -c 4)"
V=$(psqlc -c "INSERT INTO vehiculos (sucursal_id, patente, descripcion) VALUES (1, '$PAT', 'T9 km a la vez') RETURNING id" | head -1)
FECHA=$(psqlc -c "SELECT public._tablero_hoy() - 1")

# $1 S1|S2, $2 segundos antes del COMMIT
sesion() {
  printf "BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '%s', 'role', 'authenticated')::text, true),
       set_config('request.headers', json_build_object('x-sucursal-id', '1')::text, true);
SET LOCAL ROLE authenticated;
SELECT '%s empieza ' || clock_timestamp();
SELECT '%s lectura ' || public.registrar_km_vehiculo(%s, '%s', 123456);
SELECT pg_sleep(%s);
SELECT '%s confirma ' || clock_timestamp();
COMMIT;
" "$ADM" "$1" "$1" "$V" "$FECHA" "$2" "$1" | psqlc
}

( sesion S1 "$SLEEP" > "$TMP/t9k-s1.out" 2>&1 ) &
sleep 2
sesion S2 0 > "$TMP/t9k-s2.out" 2>&1
wait

N=$(psqlc -c "SELECT count(*) FROM vehiculo_km WHERE vehiculo_id = $V")
echo "== K1 · dos lecturas iguales a la vez del vehículo $V"
grep -h -E "^S[12] (empieza|confirma|lectura)|ERROR|deadlock" "$TMP/t9k-s1.out" "$TMP/t9k-s2.out" | sed 's/^/   /'
S2E=$(sed -n 's/^S2 empieza //p' "$TMP/t9k-s2.out")
S1C=$(sed -n 's/^S1 confirma //p' "$TMP/t9k-s1.out")

psqlc >/dev/null <<SQL
DELETE FROM audit_logs WHERE tabla IN ('vehiculo_km', 'vehiculos')
   AND (new_data->>'vehiculo_id' = '$V' OR old_data->>'vehiculo_id' = '$V' OR registro_id = '$V');
DELETE FROM vehiculo_km WHERE vehiculo_id = $V;
DELETE FROM vehiculos WHERE id = $V;
SQL

if [ -z "$S2E" ] || [ -z "$S1C" ] || [[ ! "$S2E" < "$S1C" ]]; then
  echo "   NO SE CRUZARON (S2 empezó $S2E, S1 confirmó $S1C): subí SLEEP"; exit 1
fi
if [ "$N" = "1" ] && grep -q "ya está cargada" "$TMP/t9k-s2.out"; then
  echo "   OK: S2 esperó a S1 y se rechazó por la lectura repetida; queda 1"
  exit 0
fi
echo "   FALLA: quedaron $N lecturas iguales"
exit 1
