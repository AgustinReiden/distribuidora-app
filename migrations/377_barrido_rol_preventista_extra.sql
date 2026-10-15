-- #1179 · Barrido de perfiles.rol = 'preventista' antes de admitir el
-- preventista como rol extra en perfil_roles.
--
-- EL PROBLEMA
--   perfil_roles_rol_check sólo admite 'transportista', pero el día que se
--   amplíe, las piezas que deciden por perfiles.rol = 'preventista' no tratarían
--   como preventista a quien tenga otro rol base y el preventista como extra.
--   El criterio del barrido es buscar lo que fallaría ABIERTO: lo que le
--   saltearía un control a ese usuario. Las 19 funciones del issue y la policy
--   se clasificaron una por una (2026-10-14, prod y origin/main 90707162):
--
--   · Fallan abiertas → se arreglan acá: los dos triggers BEFORE INSERT de
--     pedidos, pedidos_cliente_reservado() y pedidos_cliente_asignado(). Miran
--     el rol de un uuid explícito (NEW.usuario_id; o auth.uid() → creado_por →
--     usuario_id, que en el bot es service_role sin auth.uid()), así que el
--     extra se saltearía el reservado y la cartera. No sirven es_preventista()
--     ni tiene_rol_extra(): miran auth.uid() y current_sucursal_id(), no al
--     autor ni a la sucursal del pedido. De ahí el helper nuevo,
--     _actua_como_preventista(uuid, sucursal).
--   · Visibilidad, correcta como está (decisión 2: unión de roles):
--     mt_clientes_select y sus espejos (verificar_duplicado_cliente,
--     obtener_resumen_cuenta_cliente). Un rol base no preventista ve toda la
--     sucursal (214), salvo depósito, que no ve clientes (mt_clientes_select lo
--     excluye; con el extra preventista seguiría sin verlos, falla cerrado), y
--     no la pierde por sumar el extra. Operar lo filtran
--     mt_clientes_update y clientes_proteger_columnas_preventista (375) y, desde
--     acá, los triggers de pedidos. Sólo recibe un COMMENT.
--   · Rol base a propósito: zonas (_duenio_zona, asignar_preventista_zona,
--     clientes_alta_en_zona_propia), rendimiento_preventistas y el bot
--     (bot_digest_*, bot_aviso_atrasados_destinatarios, bot_admin_*,
--     bot_riesgo_por_preventista, bot_ventas_por_preventista). Las dudosas, que
--     fallan cerradas, quedan por rol base (decisión 3): calcular_comisiones,
--     obtener_geolocalizacion_preventistas, cambiar_cliente_pedido,
--     actualizar_preventista_pedido y los asignables del front.
--   · Falsos positivos de la búsqueda: bot_historico_pedidos_cliente,
--     bot_productos_dejados_cliente y bot_productos_recurrentes_cliente deciden
--     por p_rol, que el bot ya resuelve con el extra (bot_resolver_usuario +
--     rolEfectivo).
--   · Fallan cerradas, fuera de alcance: el candado v_user_role NOT IN (...) de
--     crear_pedido_completo, crear_pedido_completo_bot, actualizar_pedido_items
--     y registrar_visita_cliente, y el front, que decide por el rol primario a
--     propósito (permisos.ts).
--
-- EL ARREGLO (decisiones del dueño, 2026-10-14: A, unión de roles, dudosas por
-- rol base)
--   1 · _actua_como_preventista(usuario, sucursal): rol base preventista, o el
--       extra 'preventista' de esa sucursal sin ser admin ni encargado.
--       SECURITY INVOKER y de server: la llaman triggers DEFINER de postgres,
--       así que se revoca a las tres (PUBLIC, anon, authenticated). Recibe un
--       uuid y contesta por el rol de otro usuario: no puede quedar al alcance
--       de una sesión. No mira activo, igual que los triggers de hoy.
--   2 · Los dos triggers lo llaman con NEW.sucursal_id (NOT NULL, sin
--       default). Parche por ancla sobre la definición viva, escrita contra los
--       md5 de pg_get_functiondef de prod del 2026-10-14:
--         pedidos_cliente_asignado  213b1de525eabce75ac783009adf3828
--         pedidos_cliente_reservado cea4888cf7df3f514f80e80b55062ed8
--       Cada fragmento tiene que aparecer exactamente una vez o la migración
--       aborta. Mensajes, SQLSTATE y el resto del cuerpo no cambian.
--   3 · COMMENT de mt_clientes_select (por qué decide por perfiles.rol) y de
--       perfil_roles_rol_check (qué falta para ampliarlo). El CHECK queda en
--       'transportista' (decisión 1, opción A).
--
-- NO CAMBIA
--   · Ningún GRANT de tabla. Los triggers no se recrean y siguen sin EXECUTE
--     para authenticated ni anon (CREATE OR REPLACE conserva el ACL; el REVOKE
--     va igual y el $verif$ lo vigila).
--   · La qual de mt_clientes_select (el $verif$ vigila su md5).
--   · SEG-A: el helper no es DEFINER y los triggers no tienen EXECUTE para
--     authenticated. STK-*, COSTO-D, PRECIO-A: no se mueve stock, costo ni
--     precio.
--   · Hoy no cambia el resultado para nadie: las 5 filas de perfil_roles de
--     prod son de base preventista con extra transportista.
--
-- Pendientes aparte, fuera de esta migración:
--   · #1182, el caso inverso: un preventista base con extra transportista no ve
--     el cliente de un pedido que reparte y no le vendió;
--   · #1183, la asignación de clientes no mira el rol: cp_insert y
--     cliente_preventistas_no_ajeno dejan a cualquier autenticado de la
--     sucursal asignarse un cliente huérfano.
--
-- Ensayo: scripts/test-rol-preventista-extra-1179.sql (falla antes, pasa
-- después). Siguen OK: test-roles-columnas-caja-1170-1171-1175.sql,
-- test-resumen-cuenta-1044.sql y test-permisos-cuenta-costos.sql.

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 1 · El helper
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._actua_como_preventista(p_usuario uuid, p_sucursal bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles p
     WHERE p.id = p_usuario
       AND (p.rol = 'preventista'
            OR (p.rol NOT IN ('admin', 'encargado')
                AND EXISTS (SELECT 1 FROM public.perfil_roles pr
                             WHERE pr.usuario_id = p.id
                               AND pr.sucursal_id = p_sucursal
                               AND pr.rol = 'preventista'))));
$$;

REVOKE ALL ON FUNCTION public._actua_como_preventista(uuid, bigint) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._actua_como_preventista(uuid, bigint) IS
'#1179. ¿p_usuario actúa como preventista en la sucursal p_sucursal? Rol base '
'preventista, o el extra ''preventista'' de perfil_roles en esa sucursal sin ser '
'admin ni encargado. Para un uuid que no es auth.uid(): un trigger sobre NEW, el '
'bot con service_role. Para auth.uid() usar es_preventista() AND NOT '
'es_encargado_o_admin() (trampa 4: es_preventista() da true a admin y encargado). '
'De server: sin EXECUTE para PUBLIC, anon ni authenticated; si la llama una policy '
'o una RPC INVOKER da 42501. No mira perfiles.activo.';

-- ---------------------------------------------------------------------------
-- 2 · Los triggers de pedidos, parche por ancla
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

DO $reservado$
DECLARE
  v_def text := pg_get_functiondef('public.pedidos_cliente_reservado()'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$     AND EXISTS (SELECT 1 FROM perfiles p WHERE p.id = NEW.usuario_id AND p.rol IN ('preventista'))$q$,
$q$     AND public._actua_como_preventista(NEW.usuario_id, NEW.sucursal_id)$q$,
    'pedidos_cliente_reservado rol del vendedor');
  EXECUTE v_def;
END
$reservado$;

DO $asignado$
DECLARE
  v_def text := pg_get_functiondef('public.pedidos_cliente_asignado()'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$  -- `perfiles.rol` crudo: es_preventista() incluye a admin y encargado.
  IF NOT EXISTS (
    SELECT 1 FROM perfiles p WHERE p.id = v_autor AND p.rol = 'preventista'
  ) THEN
$q$,
$q$  -- Actúa como preventista en la sucursal del pedido: rol base preventista, o el
  -- extra de esa sucursal sin ser admin ni encargado (#1179). No es_preventista():
  -- da true a admin y encargado y mira auth.uid(), no al autor.
  IF NOT public._actua_como_preventista(v_autor, NEW.sucursal_id) THEN
$q$,
    'pedidos_cliente_asignado rol del autor');
  EXECUTE v_def;
END
$asignado$;

-- Triggers: no necesitan EXECUTE para nadie (los invoca el executor).
REVOKE EXECUTE ON FUNCTION public.pedidos_cliente_reservado(), public.pedidos_cliente_asignado()
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3 · Comentarios
-- ---------------------------------------------------------------------------
COMMENT ON POLICY mt_clientes_select ON public.clientes IS
'Decide por perfiles.rol = ''preventista'' a propósito (#1179, unión de roles): el '
'filtro de cartera y reservado rige a quien es preventista por rol base. Un rol '
'base que ya ve toda la sucursal no pierde vista al sumar el preventista como '
'extra. Operar lo deciden mt_clientes_update, clientes_proteger_columnas_preventista '
'y los triggers de pedidos (pedidos_cliente_reservado, pedidos_cliente_asignado, '
'con _actua_como_preventista). Espejos de este predicado: verificar_duplicado_cliente '
'y obtener_resumen_cuenta_cliente; si cambia uno, cambian los otros.';

COMMENT ON CONSTRAINT perfil_roles_rol_check ON public.perfil_roles IS
'Sólo ''transportista'' como rol extra (#1179, opción A). Los triggers de pedidos '
'(reservado y cartera) ya contemplan el extra preventista con _actua_como_preventista. '
'Para que el extra pueda vender falta: (1) los candados v_user_role de '
'crear_pedido_completo, crear_pedido_completo_bot, actualizar_pedido_items y '
'registrar_visita_cliente; (2) el front: permisos.ts, isPreventista en App.tsx, '
'esClienteOperable en src/utils/clienteOperable.ts y ModalUsuario; (3) decidir '
'comisión (calcular_comisiones), GPS (obtener_geolocalizacion_preventistas), zonas '
'y digest del bot, que hoy son por rol base. Pendiente aparte: la asignación de '
'clientes (cp_insert / cliente_preventistas_no_ajeno) no mira el rol (#1183). '
'Ojo: ampliar el CHECK abre, vía es_preventista(), mt_pagos_select (todos los pagos '
'de la sucursal), mt_pagos_insert, cdc_select y mt_clientes_insert.';

-- ---------------------------------------------------------------------------
-- Verificación estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f_h   text := 'public._actua_como_preventista(uuid,bigint)';
  v_trg text;
  v_src text;
  v_uid uuid;
  v_suc bigint;
BEGIN
  -- El helper: una sola sobrecarga, INVOKER y sin EXECUTE de sesión.
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname = '_actua_como_preventista') <> 1 THEN
    RAISE EXCEPTION '_actua_como_preventista: tiene que haber exactamente una sobrecarga';
  END IF;
  IF (SELECT prosecdef FROM pg_proc WHERE oid = f_h::regprocedure) THEN
    RAISE EXCEPTION '_actua_como_preventista quedó SECURITY DEFINER';
  END IF;
  IF has_function_privilege('anon', f_h::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', f_h::regprocedure, 'EXECUTE')
     OR has_function_privilege('public', f_h::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION '_actua_como_preventista quedó alcanzable por PUBLIC, anon o authenticated';
  END IF;

  -- Los triggers: llaman al helper, no miran p.rol crudo, siguen enganchados y
  -- sin EXECUTE de sesión.
  FOREACH v_trg IN ARRAY ARRAY['pedidos_cliente_reservado', 'pedidos_cliente_asignado'] LOOP
    v_src := (SELECT prosrc FROM pg_proc WHERE oid = ('public.' || v_trg || '()')::regprocedure);
    IF position('_actua_como_preventista' IN v_src) = 0
       OR position('p.rol = ''preventista''' IN v_src) > 0
       OR position('p.rol IN (''preventista'')' IN v_src) > 0 THEN
      RAISE EXCEPTION '%: no llama a _actua_como_preventista o sigue mirando p.rol crudo', v_trg;
    END IF;
    IF has_function_privilege('anon', ('public.' || v_trg || '()')::regprocedure, 'EXECUTE')
       OR has_function_privilege('authenticated', ('public.' || v_trg || '()')::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedó con EXECUTE para anon o authenticated', v_trg;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pedidos'::regclass
                      AND tgname = 'trg_' || v_trg AND tgenabled = 'O'
                      AND tgfoid = ('public.' || v_trg || '()')::regprocedure) THEN
      RAISE EXCEPTION 'trg_% no está enganchado y habilitado en pedidos', v_trg;
    END IF;
  END LOOP;

  -- La policy no cambió y el CHECK sigue igual.
  IF (SELECT md5(qual) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'clientes'
         AND policyname = 'mt_clientes_select') IS DISTINCT FROM 'c2d80685d0b68199da4c855b352a9737' THEN
    RAISE EXCEPTION 'la qual de mt_clientes_select cambió';
  END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conrelid = 'public.perfil_roles'::regclass AND conname = 'perfil_roles_rol_check')
     IS DISTINCT FROM 'CHECK ((rol = ''transportista''::text))' THEN
    RAISE EXCEPTION 'perfil_roles_rol_check cambió';
  END IF;

  -- Datos reales: un preventista base activo en su sucursal → true.
  SELECT us.usuario_id, us.sucursal_id INTO v_uid, v_suc
    FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
   WHERE p.rol = 'preventista' AND p.activo ORDER BY us.usuario_id, us.sucursal_id LIMIT 1;
  IF v_uid IS NULL OR NOT public._actua_como_preventista(v_uid, v_suc) THEN
    RAISE EXCEPTION '_actua_como_preventista: el preventista base % no da true en la sucursal %', v_uid, v_suc;
  END IF;
  -- Un admin → false.
  SELECT us.usuario_id, us.sucursal_id INTO v_uid, v_suc
    FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
   WHERE p.rol = 'admin' AND p.activo ORDER BY us.usuario_id, us.sucursal_id LIMIT 1;
  IF v_uid IS NULL OR public._actua_como_preventista(v_uid, v_suc) THEN
    RAISE EXCEPTION '_actua_como_preventista: el admin % no da false en la sucursal %', v_uid, v_suc;
  END IF;
  -- Un transportista base sin extra → false.
  SELECT us.usuario_id, us.sucursal_id INTO v_uid, v_suc
    FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
   WHERE p.rol = 'transportista' AND p.activo
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = p.id)
   ORDER BY us.usuario_id, us.sucursal_id LIMIT 1;
  IF v_uid IS NULL OR public._actua_como_preventista(v_uid, v_suc) THEN
    RAISE EXCEPTION '_actua_como_preventista: el transportista sin extra % no da false en la sucursal %', v_uid, v_suc;
  END IF;
END
$verif$;
