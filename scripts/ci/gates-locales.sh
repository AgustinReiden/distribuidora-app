#!/bin/bash
# Corre los gates de SQL sobre una base LOCAL (la del PR): los mismos scripts que el cron
# de integridad.yml corre contra prod, apuntados a un PostgREST de juguete
# (scripts/ci/rpc-local.mjs) o directo al catálogo. Sin secrets.
#
# Uso:  GATE_DB_CONTENEDOR=<contenedor> bash scripts/ci/gates-locales.sh
#       GATE_DB_URL=<url de conexion de la base local> bash scripts/ci/gates-locales.sh
#
# Sigue aunque uno falle (una corrida dice todo lo que está mal de una vez) y termina con
# exit 1 si alguno falló o no pudo correr.
#
# Qué NO corre acá, y dónde corre:
#   check-integridad, check-embeds  necesitan los datos de prod / el PostgREST de verdad
#                                   (integridad.yml, y los embeds también en ci.yml)
#   check-auth, check-storage       miran /auth y el schema storage, que la base local no tiene
#   check-migrations                compara contra el ledger de prod
#   espejo-motor-compras            necesita node_modules (corre en integridad.yml)
set -u

PUERTO="${RPC_LOCAL_PUERTO:-54499}"
if [ -z "${GATE_DB_CONTENEDOR:-}" ] && [ -z "${GATE_DB_URL:-}" ]; then
  echo "Falta GATE_DB_CONTENEDOR o GATE_DB_URL." >&2
  exit 2
fi
# Lista blanca: el contenedor local, o una URL a localhost / 127.0.0.1 / ::1 (los gates de acá corren RPCs y arman
# datos). Una URL sin host, `service=…` o una IP de afuera no pasan; scripts/lib/pg.mjs lo vuelve a verificar.
if [ -z "${GATE_DB_CONTENEDOR:-}" ]; then
  case "${GATE_DB_URL:-}" in
    *://localhost[:/]*|*://127.0.0.1[:/]*|*://*@localhost[:/]*|*://*@127.0.0.1[:/]*|*@\[::1\]*) ;;
    *) echo "GATE_DB_URL no es una base local (localhost / 127.0.0.1): no se corre." >&2; exit 2 ;;
  esac
fi
unset SUPABASE_DB_URL

node scripts/ci/rpc-local.mjs "$PUERTO" > /tmp/rpc-local.log 2>&1 &
SERVIDOR=$!
trap 'kill $SERVIDOR 2>/dev/null' EXIT
for i in $(seq 1 30); do
  grep -q escuchando /tmp/rpc-local.log 2>/dev/null && break
  sleep 1
done
if ! grep -q escuchando /tmp/rpc-local.log 2>/dev/null; then
  echo "rpc-local no levantó:"; cat /tmp/rpc-local.log; exit 2
fi

export SUPABASE_URL="http://127.0.0.1:$PUERTO"
export SUPABASE_SERVICE_ROLE_KEY="local"

FALLAN=()
correr() {
  local nombre="$1"; shift
  echo ""
  echo "=== $nombre"
  "$@"
  local c=$?
  if [ $c -ne 0 ]; then
    FALLAN+=("$nombre (exit $c)")
  fi
}

# Los que hablan por el RPC (y, los endurecidos, también por el catálogo).
correr "Permisos EXECUTE"                    node scripts/check-permisos.mjs
correr "Rama admin de las policies"          node scripts/check-rama-admin.mjs
correr "Aislamiento por sucursal (FK)"       node scripts/check-sucursal-cruzada.mjs
correr "RPCs definer"                        node scripts/check-rpcs-definer.mjs
correr "Rol sin activo"                      node scripts/check-rol-sin-activo.mjs
correr "Clientes dados de baja"              node scripts/check-clientes-activo.mjs
correr "Locks en orden"                      node scripts/check-locks.mjs
correr "Día argentino"                       node scripts/check-fechas-utc.mjs
correr "Lectura anónima de tablas"           node scripts/check-tablas-anon.mjs
correr "Grants de tabla"                     node scripts/check-grants-tablas.mjs
correr "Funciones de fila"                   node scripts/check-funciones-fila.mjs
correr "Resumen del bot"                     node scripts/check-bot.mjs
correr "Paridad del tope de regalo"          node scripts/espejo-tope-regalo.mjs
correr "Paridad del tope del sustituto"      node scripts/espejo-tope-sustituto.mjs
correr "Espejo de formas de pago"            node scripts/espejo-formas-pago.mjs

# Los que leen el catálogo directo.
correr "Realtime"                            node scripts/check-realtime.mjs
correr "Mensajes de error de los triggers"   node scripts/check-mensajes-trigger.mjs
correr "auditoria_integridad() estructural"  node scripts/ci/auditoria-local.mjs
# Arma datos (que se deshacen): va último.
correr "Cruce por ids de otra sucursal"      node scripts/check-cruce-ids.mjs

echo ""
if [ ${#FALLAN[@]} -gt 0 ]; then
  echo "❌ Fallaron ${#FALLAN[@]} gate(s):"
  printf '   - %s\n' "${FALLAN[@]}"
  exit 1
fi
echo "✅ Todos los gates de SQL pasaron sobre la base local."
