-- 378 (número final al aplicar) · #1182 y #1183: la cartera mira el rol
--
-- #1182 · Un preventista base con el extra transportista no veía el cliente de un
--   pedido que reparte y no vendió: mt_clientes_select le aplica el filtro de cartera
--   por rol base, y el embed cliente:clientes(...) del pedido volvía NULL (hoja de
--   ruta sin nombre ni dirección; con búsqueda, !inner sacaba el pedido). Rama nueva
--   "reparto": ve el cliente de un pedido con transportista_id = (SELECT auth.uid())
--   que no sea VB (mismo alcance que mt_pedidos_select). El subselect es a propósito:
--   lo vuelve initPlan; con auth.uid() pelado el planner recorría todos los pedidos de
--   la sucursal por fila y la lista de clientes de un preventista pasaba de ~156 a
--   ~272 ms. Ver no es operar: mt_clientes_update, pedidos_cliente_asignado/_reservado
--   y esClienteOperable no cambian. Espejos: obtener_resumen_cuenta_cliente y
--   verificar_duplicado_cliente (DEFINER: el filtro VB va explícito porque no pasan
--   por la RLS de pedidos). Efecto declarado: en verificar_duplicado_cliente, un
--   vecino visible por reparto ya no dispara 'cliente_duplicado_oculto' (igual que el
--   historial de la 358).
-- #1183 · cp_insert sólo pide preventista_id = auth.uid() y el trigger no miraba el
--   rol: un transportista se asignaba un huérfano por REST y lo sacaba de la vista de
--   todos los preventistas. El trigger exige _actua_como_preventista (mig 377) al
--   final del camino de sesión no admin, donde ya vale NEW.preventista_id = auth.uid().
--   Admin, server (auth.uid() NULL) y la reasignación por zona (depth > 1) siguen
--   saliendo antes. El encargado deja de poder autoasignarse por REST.
--
-- NO CAMBIA: grants de tabla, cp_insert, el bot, mt_clientes_update, el front, la
--   rama de historial de la 358. No hay función ni tabla nueva.
-- Ensayo: scripts/test-cartera-chofer-y-asignacion-1182-1183.sql.

SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION pg_temp.cc_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · #1182: la policy (guarda del estado previo: el md5 que vigila la 377)
-- ---------------------------------------------------------------------------
DO $guarda_policy$
BEGIN
  IF (SELECT md5(qual) FROM pg_policies WHERE schemaname = 'public'
        AND tablename = 'clientes' AND policyname = 'mt_clientes_select')
     IS DISTINCT FROM 'c2d80685d0b68199da4c855b352a9737' THEN
    RAISE EXCEPTION 'mt_clientes_select cambió desde el relevamiento: revisar a mano';
  END IF;
END
$guarda_policy$;

ALTER POLICY mt_clientes_select ON public.clientes
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (
      -- Roles que no son preventista ven todos los clientes de su sucursal
      NOT EXISTS (
        SELECT 1 FROM public.perfiles p
        WHERE p.id = auth.uid() AND p.rol = 'preventista'
      )
      -- Operar: huérfanos + los míos, menos los reservados
      OR (
        (
          NOT EXISTS (
            SELECT 1 FROM public.cliente_preventistas cp
            WHERE cp.cliente_id = clientes.id
          )
          OR EXISTS (
            SELECT 1 FROM public.cliente_preventistas cp
            WHERE cp.cliente_id = clientes.id AND cp.preventista_id = auth.uid()
          )
        )
        AND NOT clientes.reservado_admin
      )
      -- Historial (358): cualquier cliente al que ya le vendió
      OR EXISTS (
        SELECT 1 FROM public.pedidos pe
        WHERE pe.cliente_id = clientes.id AND pe.usuario_id = auth.uid()
      )
      -- Reparto (#1182): el cliente de un pedido que reparte, sin VB.
      -- (SELECT auth.uid()) a propósito: initPlan, no SubPlan por fila.
      OR EXISTS (
        SELECT 1 FROM public.pedidos pe
        WHERE pe.cliente_id = clientes.id AND pe.transportista_id = (SELECT auth.uid())
          AND pe.tipo_factura IS DISTINCT FROM 'VB'
      )
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.perfiles pd
      WHERE pd.id = auth.uid() AND pd.rol = 'deposito'
    )
  );

-- ---------------------------------------------------------------------------
-- 2 · #1182: espejos (parche por ancla sobre el cuerpo vivo, md5 del 2026-10-15)
-- ---------------------------------------------------------------------------
DO $espejos$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.obtener_resumen_cuenta_cliente(integer)'::regprocedure);
  IF md5(v_def) <> '4a45d5171bd6f7caf0a3171de012adc1' THEN
    RAISE EXCEPTION 'obtener_resumen_cuenta_cliente cambió desde el relevamiento: revisar a mano';
  END IF;
  v_def := pg_temp.cc_parchar(v_def,
$o$        OR EXISTS (SELECT 1 FROM pedidos pe
                   WHERE pe.cliente_id = c.id AND pe.usuario_id = auth.uid())
$o$,
$n$        OR EXISTS (SELECT 1 FROM pedidos pe
                   WHERE pe.cliente_id = c.id AND pe.usuario_id = auth.uid())
        -- Reparto (#1182): el cliente de un pedido que reparte, sin VB
        OR EXISTS (SELECT 1 FROM pedidos pe
                   WHERE pe.cliente_id = c.id AND pe.transportista_id = auth.uid()
                     AND pe.tipo_factura IS DISTINCT FROM 'VB')
$n$, 'obtener_resumen_cuenta_cliente');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.verificar_duplicado_cliente(numeric,numeric,text,bigint)'::regprocedure);
  IF md5(v_def) <> 'ac811cf827500de36cf2768d1a5fe5d1' THEN
    RAISE EXCEPTION 'verificar_duplicado_cliente cambió desde el relevamiento: revisar a mano';
  END IF;
  v_def := pg_temp.cc_parchar(v_def,
$o$      OR EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = v_uid)
      INTO v_visible$o$,
$n$      OR EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = v_uid)
      -- Reparto (#1182): el cliente de un pedido que reparte, sin VB
      OR EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.transportista_id = v_uid
                   AND pe.tipo_factura IS DISTINCT FROM 'VB')
      INTO v_visible$n$, 'verificar_duplicado_cliente');
  EXECUTE v_def;
END
$espejos$;

-- ---------------------------------------------------------------------------
-- 3 · #1183: el trigger de asignación mira el rol del asignado
--     Ancla: el bloque 'Solo un administrador…' + RETURN NEW final. Ahí ya vale
--     NEW.preventista_id = auth.uid(), así que el mensaje 'no podés asignarte' es exacto
--     y el que asigna a un tercero sigue recibiendo 'Solo un administrador…'.
-- ---------------------------------------------------------------------------
DO $asigna$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.cliente_preventistas_no_ajeno()'::regprocedure);
  IF md5(v_def) <> 'c627d16fea96c87ae3f4ffe324a6df01' THEN
    RAISE EXCEPTION 'cliente_preventistas_no_ajeno cambió desde el relevamiento: revisar a mano';
  END IF;
  v_def := pg_temp.cc_parchar(v_def,
$o$  IF NEW.preventista_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Solo un administrador puede asignarle un cliente a otro preventista.'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;$o$,
$n$  IF NEW.preventista_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Solo un administrador puede asignarle un cliente a otro preventista.'
      USING ERRCODE = '42501';
  END IF;

  -- #1183: sólo tiene clientes asignados quien actúa como preventista en la
  -- sucursal del cliente (rol base preventista o el extra de esa sucursal; ni
  -- admin ni encargado). cp_insert sólo exige preventista_id = auth.uid(): sin
  -- esto un transportista se asignaba un huérfano por REST y lo sacaba de la
  -- vista de todos los preventistas. Admin, server (auth.uid() NULL) y la
  -- reasignación por zona (pg_trigger_depth() > 1) salen antes.
  IF NOT public._actua_como_preventista(NEW.preventista_id, v_sucursal) THEN
    RAISE EXCEPTION 'Sólo un preventista puede tener clientes asignados: no podés asignarte el cliente #%.',
      NEW.cliente_id
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;$n$, 'cliente_preventistas_no_ajeno');
  EXECUTE v_def;
END
$asigna$;

-- Trigger: sin EXECUTE para nadie de sesión (CREATE OR REPLACE conserva el ACL; va igual).
REVOKE EXECUTE ON FUNCTION public.cliente_preventistas_no_ajeno() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4 · Comentarios
-- ---------------------------------------------------------------------------
COMMENT ON POLICY mt_clientes_select ON public.clientes IS
'Decide por perfiles.rol = ''preventista'' a propósito (#1179, unión de roles). Para el '
'preventista base: operar (huérfanos + los suyos, sin reservados), historial (358: ya le '
'vendió) y reparto (#1182: el cliente de un pedido con transportista_id = (SELECT auth.uid()), '
'sin VB; el subselect es por rendimiento). Ver no es operar: lo deciden mt_clientes_update, '
'clientes_proteger_columnas_preventista y los triggers de pedidos. Espejos: '
'verificar_duplicado_cliente y obtener_resumen_cuenta_cliente; si cambia uno, cambian los otros.';

COMMENT ON FUNCTION public.cliente_preventistas_no_ajeno() IS
'Trigger BEFORE INSERT/UPDATE de cliente_preventistas. Sesión no admin: el cliente es de la '
'sucursal activa, no tiene otro dueño, el asignado es uno mismo y actúa como preventista ahí '
'(_actua_como_preventista, #1183). Admin, server y reasignación por zona salen antes.';

COMMENT ON CONSTRAINT perfil_roles_rol_check ON public.perfil_roles IS
'Sólo ''transportista'' como rol extra (#1179, opción A). Los triggers de pedidos '
'(reservado y cartera) y la asignación de clientes (cliente_preventistas_no_ajeno, #1183) '
'ya contemplan el extra preventista con _actua_como_preventista. '
'Para que el extra pueda vender falta: (1) los candados v_user_role de '
'crear_pedido_completo, crear_pedido_completo_bot, actualizar_pedido_items y '
'registrar_visita_cliente; (2) el front: permisos.ts, isPreventista en App.tsx, '
'esClienteOperable en src/utils/clienteOperable.ts y ModalUsuario; (3) decidir '
'comisión (calcular_comisiones), GPS (obtener_geolocalizacion_preventistas), zonas '
'y digest del bot, que hoy son por rol base. '
'Ojo: ampliar el CHECK abre, vía es_preventista(), mt_pagos_select (todos los pagos '
'de la sucursal), mt_pagos_insert, cdc_select y mt_clientes_insert.';

-- ---------------------------------------------------------------------------
-- Verificación estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f_res text := 'public.obtener_resumen_cuenta_cliente(integer)';
  f_dup text := 'public.verificar_duplicado_cliente(numeric,numeric,text,bigint)';
  f_trg text := 'public.cliente_preventistas_no_ajeno()';
BEGIN
  IF (SELECT md5(qual) FROM pg_policies WHERE schemaname = 'public'
        AND tablename = 'clientes' AND policyname = 'mt_clientes_select')
     IS DISTINCT FROM 'f715c80865fe01f8c0ab11f1a7c8a835' THEN
    RAISE EXCEPTION 'mt_clientes_select no quedó con la qual ensayada';
  END IF;
  IF position('transportista_id = auth.uid()' IN pg_get_functiondef(f_res::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'obtener_resumen_cuenta_cliente no copia la rama de reparto';
  END IF;
  IF position('transportista_id = v_uid' IN pg_get_functiondef(f_dup::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'verificar_duplicado_cliente no copia la rama de reparto';
  END IF;
  IF position('_actua_como_preventista' IN (SELECT prosrc FROM pg_proc WHERE oid = f_trg::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'cliente_preventistas_no_ajeno no llama a _actua_como_preventista';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
        AND proname IN ('obtener_resumen_cuenta_cliente','verificar_duplicado_cliente','cliente_preventistas_no_ajeno')) <> 3 THEN
    RAISE EXCEPTION 'apareció una sobrecarga de un espejo o del trigger';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f_trg::regprocedure)
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = f_res::regprocedure)
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = f_dup::regprocedure) THEN
    RAISE EXCEPTION 'alguna función dejó de ser SECURITY DEFINER';
  END IF;
  IF has_function_privilege('anon', f_trg::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', f_trg::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', f_res::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', f_dup::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'ACL: el trigger quedó alcanzable por sesión, o un espejo por anon';
  END IF;
  IF NOT has_function_privilege('authenticated', f_res::regprocedure, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', f_dup::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'ACL: los espejos perdieron EXECUTE para authenticated';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.cliente_preventistas'::regclass
                   AND tgname = 'trg_cliente_preventistas_no_ajeno' AND tgenabled = 'O'
                   AND tgfoid = f_trg::regprocedure) THEN
    RAISE EXCEPTION 'trg_cliente_preventistas_no_ajeno no está enganchado y habilitado';
  END IF;
  IF position('Pendiente aparte' IN coalesce(obj_description(
       (SELECT oid FROM pg_constraint WHERE conname = 'perfil_roles_rol_check'
          AND conrelid = 'public.perfil_roles'::regclass), 'pg_constraint'), '')) > 0 THEN
    RAISE EXCEPTION 'el comentario de perfil_roles_rol_check sigue con el pendiente de #1183';
  END IF;
END
$verif$;
