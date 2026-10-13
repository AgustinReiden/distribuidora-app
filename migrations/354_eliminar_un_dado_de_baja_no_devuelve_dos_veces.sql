-- Eliminar un pedido dado de baja no devuelve el stock dos veces (#1125)
--
-- eliminar_pedido_completo con p_restaurar_stock = true recorria pedido_items
-- y sumaba cada linea al stock ('pedido_eliminado') sin mirar si el pedido ya
-- estaba dado de baja. cancelar_pedido_con_stock no borra las lineas: ya
-- devolvio esas unidades (o las devolvio y mermo, si fue por falta de stock),
-- ya revirtio el acumulador de los regalos y ya consumio la huella, asi que la
-- segunda devolucion entraba entera a la bolsa (desde la 353): stock +N que no
-- existe. El front (eliminarPedido) siempre manda true.
--
-- Decision del dueño (2026-10-13), opcion A: sobre un pedido dado de baja la
-- restauracion se fuerza a false, el pedido se borra igual, y
-- pedidos_eliminados guarda el valor efectivo (stock_restaurado = false) con
-- una marca en motivo_eliminacion que distingue "no se repuso porque ya estaba
-- devuelto" de "no se repuso por decision".
--
-- "Ya devuelto" = motivo_cancelacion no nulo. Es lo unico que escribe, y
-- siempre, la unica funcion que devuelve stock al dar de baja un pedido:
-- cancelar_pedido_con_stock (la unica que escribe estado = 'cancelado'; ninguna
-- funcion escribe 'anulado', y los 365 cancelados de prod tienen motivo). El
-- estado NO sirve de prueba: pedidos.estado y motivo_cancelacion se pueden
-- escribir por REST sin tocar el stock (mt_pedidos_update lo permite a
-- admin/encargado y al preventista duenio; pedidos_proteger_columnas no
-- bloquea esas columnas), y un 'cancelado' o 'anulado' puesto asi nunca
-- devolvio nada: tratarlo como devuelto perderia unidades reales y anotaria en
-- el registro una devolucion que no ocurrio (regresion respecto de hoy, que
-- las restaura). Inversamente, un cancelado que vuelve a otro estado por REST
-- (el pedido 1856 de prod: cancelado, vuelto a 'asignado' y entregado) conserva
-- el motivo y sigue siendo "ya devuelto". Nada limpia motivo_cancelacion: si un
-- camino futuro reactiva un pedido de verdad (volviendo a descontar), tiene que
-- limpiarlo o esta guarda lo seguira tratando como ya devuelto. Bloquear por
-- REST el cambio de estado desde/hacia cancelado queda en un issue aparte.
--
-- El SELECT del pedido pasa a FOR UPDATE: cierra la carrera con
-- cancelar_pedido_con_stock (que toma el mismo lock); eliminar espera, relee
-- la fila ya cancelada y entra a la guarda.
--
-- Lo que no se hace:
--   - No se repara ningun dato. El unico eliminado historico con estado
--     cancelado y stock_restaurado = true (pedido 414) restauro una sola vez.
--     El pedido 629 (cancelado sin que su stock volviera, segun el ledger)
--     ya no repondra sus unidades si se lo elimina: queda para el dueño.
--
-- Quien recree esta funcion despues tiene que conservar v_restaurar (#1125).
--
-- Funcion parcheada en vivo (cada fragmento tiene que aparecer exactamente
-- una vez o la migracion aborta). Firma, SECURITY DEFINER, search_path y
-- GRANTs: como estaban (se verifica el ACL antes/despues). No es funcion
-- nueva. La rama que restaura queda igual, con su app.stock_origen, asi que
-- STK-F no cambia; la que no restaura no mueve stock, asi que STK-D tampoco.
--
-- Ensayo: scripts/test-eliminar-cancelado-1125.sql (manual, contra prod).

CREATE OR REPLACE FUNCTION pg_temp.parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

CREATE TEMP TABLE _acl_1125 ON COMMIT DROP AS
SELECT proacl::text AS acl
  FROM pg_proc
 WHERE oid = 'public.eliminar_pedido_completo(bigint,uuid,text,boolean)'::regprocedure;

DO $eliminar$
DECLARE
  v_def text := pg_get_functiondef('public.eliminar_pedido_completo(bigint,uuid,text,boolean)'::regprocedure);
BEGIN
  -- 1 · las dos variables.
  v_def := pg_temp.parchar(v_def,
$q$  v_user_role TEXT;
BEGIN
$q$,
$q$  v_user_role TEXT;
  -- #1125: el pedido ya fue dado de baja, y lo que de verdad se restaura.
  v_ya_devuelto BOOLEAN;
  v_restaurar BOOLEAN;
BEGIN
$q$, '1 declare');

  -- 2 · el pedido con lock, como cancelar_pedido_con_stock.
  v_def := pg_temp.parchar(v_def,
$q$  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
$q$,
$q$  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;
$q$, '2 for update');

  -- 3 · la guarda.
  v_def := pg_temp.parchar(v_def,
$q$  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado'); END IF;
$q$,
$q$  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado'); END IF;

  -- #1125: una baja por cancelar_pedido_con_stock ya devolvio el stock (o lo
  -- devolvio y mermo, si fue por falta de stock) y ya revirtio el acumulador
  -- de los regalos. Las lineas siguen en pedido_items y la huella ya se
  -- consumio, asi que devolver otra vez suma a la bolsa unidades que no
  -- existen. Se mira motivo_cancelacion y no el estado: lo escribe solo esa
  -- funcion, y el estado se puede cambiar por REST sin tocar el stock (un
  -- cancelado asi nunca devolvio nada y hoy se restaura bien).
  v_ya_devuelto := v_pedido.motivo_cancelacion IS NOT NULL;
  v_restaurar := COALESCE(p_restaurar_stock, false) AND NOT v_ya_devuelto;
$q$, '3 guarda');

  -- 4 · el registro dice lo que de verdad paso.
  v_def := pg_temp.parchar(v_def,
$q$p_motivo, p_restaurar_stock, v_sucursal$q$,
$q$CASE WHEN p_restaurar_stock AND v_ya_devuelto
         THEN COALESCE(p_motivo, '') || ' [stock ya devuelto por la cancelacion]'
         ELSE p_motivo END,
    v_restaurar, v_sucursal$q$, '4 registro');

  -- 5 · restaura solo si corresponde (cuerpo intacto, acumulador incluido).
  v_def := pg_temp.parchar(v_def,
$q$  IF p_restaurar_stock THEN
    PERFORM set_config('app.stock_origen', 'pedido_eliminado', true);
$q$,
$q$  IF v_restaurar THEN
    PERFORM set_config('app.stock_origen', 'pedido_eliminado', true);
$q$, '5 rama');

  -- 6 · el RETURN informa si se restauro (el front solo lee success).
  v_def := pg_temp.parchar(v_def,
$q$RETURN jsonb_build_object('success', true, 'mensaje', 'Pedido eliminado y registrado correctamente');$q$,
$q$RETURN jsonb_build_object('success', true, 'mensaje', 'Pedido eliminado y registrado correctamente',
                            'stock_restaurado', v_restaurar);$q$, '6 return');

  EXECUTE v_def;
END
$eliminar$;

DROP FUNCTION pg_temp.parchar(text, text, text, text);

-- ---------------------------------------------------------------------------
-- Verificacion estructural
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_oid oid := 'public.eliminar_pedido_completo(bigint,uuid,text,boolean)'::regprocedure;
  v_def text := pg_get_functiondef('public.eliminar_pedido_completo(bigint,uuid,text,boolean)'::regprocedure);
  r record;
BEGIN
  IF v_def NOT LIKE '%sucursal_id = v_sucursal FOR UPDATE;%'
     OR v_def NOT LIKE '%v_ya_devuelto := v_pedido.motivo_cancelacion IS NOT NULL;%'
     OR v_def NOT LIKE '%IF v_restaurar THEN%'
     OR v_def LIKE '%IF p_restaurar_stock THEN%'
     OR v_def NOT LIKE '%app.stock_origen'', ''pedido_eliminado''%' THEN
    RAISE EXCEPTION '#1125: el cuerpo de eliminar_pedido_completo no quedo como se esperaba';
  END IF;

  SELECT p.prosecdef, p.proowner::regrole::text AS owner, p.proconfig, p.proacl::text AS acl
    INTO r FROM pg_proc p WHERE p.oid = v_oid;
  IF NOT r.prosecdef OR r.owner <> 'postgres' OR r.proconfig IS DISTINCT FROM ARRAY['search_path=public'] THEN
    RAISE EXCEPTION '#1125: SECURITY DEFINER / owner / search_path cambiaron: % % %', r.prosecdef, r.owner, r.proconfig;
  END IF;
  IF r.acl IS DISTINCT FROM (SELECT acl FROM _acl_1125) THEN
    RAISE EXCEPTION '#1125: el ACL cambio: % -> %', (SELECT acl FROM _acl_1125), r.acl;
  END IF;
  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('public', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION '#1125: los permisos de EXECUTE no son authenticated si, anon y public no';
  END IF;
  IF (SELECT count(*) FROM pg_proc
       WHERE proname = 'eliminar_pedido_completo' AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION '#1125: hay mas de una sobrecarga de eliminar_pedido_completo';
  END IF;
END
$verif$;

DROP TABLE _acl_1125;
