#!/bin/bash
# Controles negativos de los gates de SQL: arma a propósito el defecto que cada uno vigila, en la
# base LOCAL, y comprueba que el gate se pone ROJO (exit 1); después lo deshace. Un gate que nunca
# falla no sirve: si alguien le saca el diente (un cambio en una regla, un filtro de más), éste
# lo dice. Lo corre sql-local.yml después de los gates, sobre la misma base.
#
# Uso:  GATE_DB_CONTENEDOR=<contenedor> bash scripts/ci/gates-muerden.sh
#
# NUNCA contra prod: crea y borra objetos. Sólo contenedor local (GATE_DB_CONTENEDOR).
set -u

if [ -z "${GATE_DB_CONTENEDOR:-}" ]; then
  echo "Falta GATE_DB_CONTENEDOR (sólo se corre contra el contenedor local)." >&2
  exit 2
fi
unset SUPABASE_DB_URL GATE_DB_URL

PUERTO="${RPC_LOCAL_PUERTO:-54498}"
node scripts/ci/rpc-local.mjs "$PUERTO" > /tmp/rpc-local-muerden.log 2>&1 &
SERVIDOR=$!
trap 'kill $SERVIDOR 2>/dev/null' EXIT
for i in $(seq 1 30); do
  grep -q escuchando /tmp/rpc-local-muerden.log 2>/dev/null && break
  sleep 1
done
grep -q escuchando /tmp/rpc-local-muerden.log 2>/dev/null || { echo "rpc-local no levantó:"; cat /tmp/rpc-local-muerden.log; exit 2; }
export SUPABASE_URL="http://127.0.0.1:$PUERTO" SUPABASE_SERVICE_ROLE_KEY="local"

verificar_semilla() {
  n=$(docker exec -i "$GATE_DB_CONTENEDOR" psql -U postgres -h localhost -d postgres -X -q -At -c "SELECT count(*) FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000004e7'")
  [ "$n" = "1" ] || { echo "La base no tiene el usuario de la semilla (docker-local.mjs semilla): no se escribe en ella." >&2; exit 2; }
}
verificar_semilla

SQL() { docker exec -i "$GATE_DB_CONTENEDOR" psql -U postgres -h localhost -d postgres -X -q -v ON_ERROR_STOP=1 -c "$1" > /dev/null; }

MAL=()
# muerde <nombre> <gate.mjs> <marca> <sql que arma el defecto> <sql que lo deshace>
# Cuenta como «mordió» sólo si el gate sale con 1 Y su salida nombra el objeto plantado (<marca>, zz_gate_*):
# un exit 1 pelado también es una excepción de Node (psql caído, un archivo que falta), y eso no es morder.
muerde() {
  local nombre="$1" gate="$2" marca="$3" arma="$4" deshace="$5"
  echo ""
  echo "=== $nombre"
  if ! SQL "$arma"; then
    echo "   no pude armar el defecto"; MAL+=("$nombre (no armó)"); SQL "$deshace" || true; return
  fi
  node "scripts/$gate" > /tmp/muerde.out 2>&1
  local c=$?
  SQL "$deshace" || { echo "   NO pude deshacer el defecto"; MAL+=("$nombre (no deshizo)"); }
  if [ $c -eq 1 ] && grep -q "$marca" /tmp/muerde.out; then
    echo "   ✓ el gate se puso rojo (exit 1) y nombra $marca, como tiene que ser"
  else
    echo "   ✗ el gate dio exit $c y $marca $(grep -q "$marca" /tmp/muerde.out && echo aparece || echo NO aparece) en su salida: ya no muerde (o se cayó)"
    tail -5 /tmp/muerde.out | sed 's/^/     /'
    MAL+=("$nombre (exit $c)")
  fi
}

# no_muerde <nombre> <gate.mjs> <sql que arma> <sql que deshace>: el caso contrario. Arma algo que el
# gate tiene que DEJAR PASAR (exit 0): un gate que se pone rojo por lo que no es suyo hace ruido y se
# termina ignorando.
no_muerde() {
  local nombre="$1" gate="$2" arma="$3" deshace="$4"
  echo ""
  echo "=== $nombre"
  if ! SQL "$arma"; then
    echo "   no pude armar el caso"; MAL+=("$nombre (no armó)"); SQL "$deshace" || true; return
  fi
  node "scripts/$gate" > /tmp/muerde.out 2>&1
  local c=$?
  SQL "$deshace" || { echo "   NO pude deshacer el caso"; MAL+=("$nombre (no deshizo)"); }
  if [ $c -eq 0 ]; then
    echo "   ✓ el gate lo deja pasar (exit 0), como tiene que ser"
  else
    echo "   ✗ el gate dio exit $c ante algo que no es suyo"
    tail -5 /tmp/muerde.out | sed 's/^/     /'
    MAL+=("$nombre (exit $c)")
  fi
}

muerde "Realtime: una tabla con SELECT por columna entra en la publicación" check-realtime.mjs zz_gate_rt \
  "CREATE TABLE public.zz_gate_rt (id int, secreto int); REVOKE ALL ON public.zz_gate_rt FROM PUBLIC, anon, authenticated; ALTER TABLE public.zz_gate_rt ENABLE ROW LEVEL SECURITY; GRANT SELECT (id) ON public.zz_gate_rt TO authenticated; ALTER PUBLICATION supabase_realtime ADD TABLE public.zz_gate_rt" \
  "DROP TABLE IF EXISTS public.zz_gate_rt"

# Prod tiene, además de supabase_realtime, la publicación de Broadcast con particiones diarias
# (realtime.messages_AAAA_MM_DD, sin SELECT para authenticated): no es de este gate.
no_muerde "Realtime: la publicación de Broadcast de Supabase (particiones diarias) no lo pone rojo" check-realtime.mjs   "DO \$f\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime_messages_publication') THEN CREATE PUBLICATION supabase_realtime_messages_publication; END IF; END \$f\$; CREATE TABLE public.zz_gate_messages_2026_11_14 (id int); REVOKE ALL ON public.zz_gate_messages_2026_11_14 FROM PUBLIC, anon, authenticated; ALTER PUBLICATION supabase_realtime_messages_publication ADD TABLE public.zz_gate_messages_2026_11_14"   "ALTER PUBLICATION supabase_realtime_messages_publication DROP TABLE public.zz_gate_messages_2026_11_14; DROP TABLE public.zz_gate_messages_2026_11_14"

muerde "Tablas anon: una tabla VACÍA legible por anon" check-tablas-anon.mjs zz_gate_anon \
  "CREATE TABLE public.zz_gate_anon (id int); ALTER TABLE public.zz_gate_anon ENABLE ROW LEVEL SECURITY; GRANT SELECT ON public.zz_gate_anon TO anon; CREATE POLICY zz_abierta ON public.zz_gate_anon FOR SELECT TO anon USING (true)" \
  "DROP TABLE IF EXISTS public.zz_gate_anon"

muerde "Guardas: IF NOT (rol IN (…) OR col = auth.uid()) sin COALESCE" check-rpcs-definer.mjs zz_gate_guarda \
  "CREATE FUNCTION public.zz_gate_guarda(p_pedido_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS \$f\$ DECLARE v_rol text; v_chofer uuid; BEGIN SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid(); SELECT transportista_id INTO v_chofer FROM pedidos WHERE id = p_pedido_id AND sucursal_id = current_sucursal_id(); IF NOT (v_rol IN ('admin','encargado') OR v_chofer = auth.uid()) THEN RAISE EXCEPTION 'sin permiso'; END IF; END \$f\$" \
  "DROP FUNCTION IF EXISTS public.zz_gate_guarda(bigint)"

muerde "Rol sin activo: una _impl sin EXECUTE que lee el rol sin activo" check-rol-sin-activo.mjs zz_gate_impl \
  "CREATE FUNCTION public.zz_gate_impl(p_x bigint) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS \$f\$ DECLARE v_rol text; BEGIN SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid(); RETURN v_rol; END \$f\$; REVOKE EXECUTE ON FUNCTION public.zz_gate_impl(bigint) FROM PUBLIC, anon, authenticated" \
  "DROP FUNCTION IF EXISTS public.zz_gate_impl(bigint)"

muerde "Mensajes de trigger: un RAISE con el nombre de un cliente leído con NEW.cliente_id" check-mensajes-trigger.mjs zz_gate_trg \
  "CREATE FUNCTION public.zz_gate_trg() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS \$f\$ DECLARE v_n text; BEGIN SELECT razon_social INTO v_n FROM clientes WHERE id = NEW.cliente_id; RAISE EXCEPTION 'El cliente % ya tiene pedido', v_n; END \$f\$" \
  "DROP FUNCTION IF EXISTS public.zz_gate_trg()"

muerde "Cruce por ids: una RPC que cambia un cliente de otra sucursal" check-cruce-ids.mjs zz_gate_cruce \
  "CREATE FUNCTION public.zz_gate_cruce(p_cliente_id bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS \$f\$ BEGIN UPDATE clientes SET direccion = 'tocada' WHERE id = p_cliente_id; END \$f\$; GRANT EXECUTE ON FUNCTION public.zz_gate_cruce(bigint) TO authenticated" \
  "DROP FUNCTION IF EXISTS public.zz_gate_cruce(bigint)"

echo ""
if [ ${#MAL[@]} -gt 0 ]; then
  echo "❌ Gates que no muerden (o no se pudieron probar):"
  printf '   - %s\n' "${MAL[@]}"
  exit 1
fi
echo "✅ Cada gate se pone rojo ante su defecto."
