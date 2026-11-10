-- 486 · Una sola fuente del rol, el personal fuera de audit_logs y lecturas acotadas (#1519).
--
-- Tarjeta 8 de #1524. Cuatro hallazgos de la reauditoría del 10/11.
--
-- SEG-02 · VTA-08 · EL ROL POR SUCURSAL TENÍA DOS FUENTES
--   usuario_sucursales.rol ('mismo' = el de perfiles, o un rol propio de esa sucursal) lo leían
--   _rol_en_sucursal, _notificar_sucursal_roles, obtener_sucursales_usuario, reporte_stock_red,
--   escanear-factura y el front; perfiles.rol lo leen los es_*, toda la RLS y las RPCs de venta.
--   Las 23 filas dicen 'mismo', así que hoy coinciden. Decisión del dueño (10/11), en dos pasos:
--   · esta migración deja de leer la columna en todos lados, la fija en 'mismo' con un CHECK y
--     le saca p_rol a asignar_usuario_sucursal, que aceptaba cualquier valor;
--   · el DROP COLUMN va en #1525, cuando el bundle que no la pide esté en todos los equipos: el
--     front de antes de esta migración la pide por REST al arrancar, y sin la columna mostraría
--     «sin sucursal».
--   Cómo queda cada lector (el resultado es el mismo que hoy, porque todo es 'mismo'):
--   · _rol_en_sucursal(uid, suc) da perfiles.rol si el usuario es de esa sucursal, o NULL;
--   · _notificar_sucursal_roles avisa a los admin y encargados por perfiles.rol;
--   · obtener_sucursales_usuario devuelve en 'rol' el de perfiles, y nada para un desactivado;
--   · reporte_stock_red exige perfiles.rol = 'admin' (la rama de us.rol era la misma condición);
--   · actualizar_pedido_items decide el envío con v_user_role, que ya es perfiles.rol del que
--     edita. Es la única línea que se toca de la función, por ancla sobre el cuerpo vivo.
--   handle_new_user sigue escribiendo 'mismo', que es lo que deja el CHECK; la saca #1525.
--
-- GTO-1 · EL SUELDO, EL CUIL Y EL TELÉFONO DE UN EMPLEADO EN audit_logs
--   empleado_arreglos y empleado_liquidaciones no tienen sucursal_id, así que audit_log_changes
--   etiqueta sus filas con la sucursal activa de quien escribe, y mt_audit_logs_select se las
--   dejaba leer por REST a cualquier admin de esa sucursal. Las de empleados guardan el CUIL y el
--   teléfono. Las tablas de personal (empleados y empleado_*) quedan sólo para el admin que
--   tiene todas las sucursales, el mismo que ve a un empleado «de las dos» (_empleado_visible).
--   Para eso nace es_admin_de_todas_las_sucursales(): la policy se evalúa como el usuario, y
--   _tiene_todas_las_sucursales() no tiene EXECUTE para authenticated. La etiqueta no se toca:
--   con la policy ya no decide quién lee una fila de personal, y la vista audit_logs_detallado
--   es security_invoker, así que pasa por la misma policy.
--
-- SEG-04 · EL PREVENTISTA VEÍA PAGOS Y SUSTITUCIONES DE BOLETAS QUE NO VE
--   La rama del preventista de mt_pagos_select pedía sólo que viera el cliente, y desde la 358
--   ve todo cliente al que alguna vez le vendió: veía los cobros de boletas ajenas. Decisión del
--   dueño (10/11): ve los pagos de las boletas que puede ver (la RLS de pedidos) y los créditos
--   sueltos (pedido_id NULL) de los clientes que opera (sin asignar o asignados a él, y no
--   reservados: la rama de operar de mt_clientes_update). El saldo le sigue llegando igual: es
--   clientes.saldo_cuenta. mt_sust_select daba toda la sucursal: ahora, sólo las sustituciones de
--   los pedidos que el usuario ve.
--
-- GTO-10 · FUGAS MENORES DE PERSONAL
--   · cliente_admite_adelanto_sueldo contestaba por un cliente de cualquier sucursal: ahora sólo
--     por uno de la sucursal activa. Sale de "tablas" de scripts/rpcs-definer-permitidas.json.
--   · obtener_faltantes_rendiciones le mostraba al transportista a qué otro empleado se le cargó
--     una línea de su rendición: ahora la ve sin el empleado («a cargo de un empleado»). El monto
--     queda, porque es parte de lo que él tiene que entregar.
--   · empleados_para_elegir le daba al encargado el usuario_id de todo empleado: ahora va sólo si
--     quien llama ya ve ese perfil (las policies de SELECT de perfiles). El front lo usa con los
--     de la sucursal activa: no cargarse un gasto a sí mismo y el vehículo del chofer.
--
-- Ensayo: scripts/test-permisos-rol-personal-pagos-1519.sql. Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisa: los cuerpos, las policies y los datos que había en prod el 10/11
-- ---------------------------------------------------------------------------
DO $premisa$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT e.firma, e.md5, (SELECT md5(p.prosrc) FROM pg_proc p WHERE p.oid = to_regprocedure(e.firma)) AS vivo
      FROM (VALUES
        ('public._rol_en_sucursal(uuid,bigint)', '03b43259c9554937148aafb30b3579cb'),
        ('public._notificar_sucursal_roles(bigint,uuid,character varying,text,text,character varying,bigint,jsonb)', '8d625145ef2e5a52ca79b1b23b3255ca'),
        ('public.obtener_sucursales_usuario()', '3e37e19a7c679f4e8b854cea546c418e'),
        ('public.asignar_usuario_sucursal(uuid,bigint,character varying,boolean)', '4784a6c33349c3049b371317ecd0f3d4'),
        ('public.reporte_stock_red(bigint)', 'e2fb9290645f5d0bf41af418a5b17562'),
        ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', '65ce7ebc6a57b3175228c06f80f6764e'),
        ('public.cliente_admite_adelanto_sueldo(bigint)', 'b7a6df08d99e20b63ca7778c2c76ba44'),
        ('public.empleados_para_elegir()', '426c6867753a91e533b95f0d83861f17'),
        ('public.obtener_faltantes_rendiciones(date,date,uuid)', '824d5918ddb378151d8960869590a80e')
      ) AS e(firma, md5)
  LOOP
    IF r.vivo IS DISTINCT FROM r.md5 THEN
      RAISE EXCEPTION 'premisa: % tiene md5 % (se esperaba %)', r.firma, r.vivo, r.md5;
    END IF;
  END LOOP;

  IF to_regprocedure('public.es_admin_de_todas_las_sucursales()') IS NOT NULL
     OR to_regprocedure('public.asignar_usuario_sucursal(uuid,bigint,boolean)') IS NOT NULL THEN
    RAISE EXCEPTION 'premisa: es_admin_de_todas_las_sucursales() o asignar_usuario_sucursal(uuid,bigint,boolean) ya existen';
  END IF;

  FOR r IN
    SELECT e.tabla, e.policy, e.md5, p.cmd, p.roles::text AS roles, p.permissive, md5(p.qual) AS qual, p.with_check
      FROM (VALUES ('audit_logs', 'mt_audit_logs_select', md5('(es_admin() AND (sucursal_id = current_sucursal_id()))')),
                   ('pagos', 'mt_pagos_select', '4a535f5532563465feb167de05eacf73'),
                   ('pedido_item_sustituciones', 'mt_sust_select', md5('(sucursal_id = current_sucursal_id())'))
           ) AS e(tabla, policy, md5)
      LEFT JOIN pg_policies p ON p.schemaname = 'public' AND p.tablename = e.tabla AND p.policyname = e.policy
  LOOP
    IF r.cmd IS DISTINCT FROM 'SELECT' OR r.roles IS DISTINCT FROM '{authenticated}'
       OR r.permissive IS DISTINCT FROM 'PERMISSIVE' OR r.qual IS DISTINCT FROM r.md5 OR r.with_check IS NOT NULL THEN
      RAISE EXCEPTION 'premisa: la policy %.% no es la del 10/11 (%, %, %, md5 USING %)',
        r.tabla, r.policy, r.cmd, r.roles, r.permissive, r.qual;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM public.usuario_sucursales WHERE rol IS DISTINCT FROM 'mismo') THEN
    RAISE EXCEPTION 'premisa: hay filas de usuario_sucursales con un rol propio: decidir qué rol vale antes de fijarlo';
  END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conrelid = 'public.usuario_sucursales'::regclass AND conname = 'usuario_sucursales_rol_check')
     IS DISTINCT FROM 'CHECK (((rol)::text = ANY ((ARRAY[''mismo''::character varying, ''admin''::character varying, ''encargado''::character varying, ''preventista''::character varying, ''transportista''::character varying, ''deposito''::character varying])::text[])))' THEN
    RAISE EXCEPTION 'premisa: el CHECK de usuario_sucursales.rol no es el del 10/11';
  END IF;
END
$premisa$;

-- ===========================================================================
-- SEG-02 · VTA-08 · el rol es perfiles.rol en toda sucursal
-- ===========================================================================
ALTER TABLE public.usuario_sucursales DROP CONSTRAINT usuario_sucursales_rol_check;
ALTER TABLE public.usuario_sucursales ADD CONSTRAINT usuario_sucursales_rol_mismo CHECK (rol = 'mismo');
COMMENT ON COLUMN public.usuario_sucursales.rol IS
  'Sin uso desde la 486 (#1519): el rol es perfiles.rol en toda sucursal, más los extra de perfil_roles. '
  'Queda fija en ''mismo'' para no cortar a un bundle viejo que la pide; se dropea en #1525.';

CREATE OR REPLACE FUNCTION public._rol_en_sucursal(p_uid uuid, p_suc bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- El rol del usuario si es de esa sucursal; NULL si no lo es. Desde la 486
  -- (#1519) el rol es uno solo, perfiles.rol, en toda sucursal.
  SELECT p.rol
  FROM usuario_sucursales us
  JOIN perfiles p ON p.id = us.usuario_id
  WHERE us.usuario_id = p_uid AND us.sucursal_id = p_suc
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public._notificar_sucursal_roles(p_sucursal_id bigint, p_excluir_uid uuid, p_tipo character varying, p_titulo text, p_mensaje text, p_entidad_tipo character varying, p_entidad_id bigint, p_payload jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  INSERT INTO notificaciones (usuario_id, sucursal_id, tipo, titulo, mensaje, entidad_tipo, entidad_id, payload)
  SELECT DISTINCT us.usuario_id, p_sucursal_id, p_tipo, p_titulo, p_mensaje, p_entidad_tipo, p_entidad_id, p_payload
  FROM usuario_sucursales us
  JOIN perfiles p ON p.id = us.usuario_id
  WHERE us.sucursal_id = p_sucursal_id
    AND p.rol IN ('admin', 'encargado')
    AND p.activo IS NOT FALSE
    AND us.usuario_id <> COALESCE(p_excluir_uid, '00000000-0000-0000-0000-000000000000'::uuid);
$function$;

CREATE OR REPLACE FUNCTION public.obtener_sucursales_usuario()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- 'rol' es perfiles.rol, el mismo en toda sucursal (486, #1519). Un desactivado
  -- no tiene ningún rol (#1474): no le devuelve sucursales.
  RETURN (
    SELECT jsonb_agg(jsonb_build_object(
      'sucursal_id', us.sucursal_id,
      'nombre', s.nombre,
      'rol', p.rol,
      'es_default', us.es_default
    ))
    FROM usuario_sucursales us
    JOIN sucursales s ON s.id = us.sucursal_id
    JOIN perfiles p ON p.id = us.usuario_id
    WHERE us.usuario_id = auth.uid() AND s.activa = true AND COALESCE(p.activo, true)
  );
END;
$function$;

-- La firma pierde p_rol: el rol no se asigna por sucursal. Nadie la llama con él
-- (ni el front ni las edge functions), y dos sobrecargas darían PGRST203.
DROP FUNCTION public.asignar_usuario_sucursal(uuid, bigint, character varying, boolean);

CREATE FUNCTION public.asignar_usuario_sucursal(p_usuario_id uuid, p_sucursal_id bigint, p_es_default boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede asignar sucursales');
  END IF;

  -- Sin esto, un admin de la sucursal 1 se agrega a sí mismo a la 2 y
  -- current_sucursal_id() lo autoriza a partir de ahí.
  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo podés asignar usuarios a una sucursal a la que pertenecés');
  END IF;

  -- #1291: y sin esto se trae a un usuario de otra sucursal con su uuid, y desde
  -- ahí lo ve entero (su email, su bot, su historial). Como cambiarle el rol o
  -- el activo (404), lo hace un admin de todas sus sucursales.
  IF NOT admin_abarca_sucursales_de(p_usuario_id) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Ese usuario no es de tus sucursales, o también trabaja en otras: lo asigna un admin de todas sus sucursales');
  END IF;

  -- Sin rol: es perfiles.rol en toda sucursal (486, #1519).
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default)
  VALUES (p_usuario_id, p_sucursal_id, p_es_default)
  ON CONFLICT (usuario_id, sucursal_id) DO UPDATE
    SET es_default = EXCLUDED.es_default;

  IF p_es_default THEN
    UPDATE usuario_sucursales SET es_default = false
     WHERE usuario_id = p_usuario_id AND sucursal_id <> p_sucursal_id;
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.asignar_usuario_sucursal(uuid, bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.asignar_usuario_sucursal(uuid, bigint, boolean) TO authenticated, service_role;

-- reporte_stock_red y actualizar_pedido_items: parche por ancla sobre el cuerpo
-- VIVO, no una copia. Si el ancla no aparece exactamente una vez, no aplica nada.
DO $parche_stock_red$
DECLARE
  v_def   text := pg_get_functiondef('public.reporte_stock_red(bigint)'::regprocedure);
  v_ancla text := $ancla$    -- Admin global, o admin en alguna sucursal asignada ('mismo' resuelve al
    -- rol global, igual que _rol_en_sucursal). Rol CRUDO: nunca
    -- es_preventista()/es_transportista(), que dan true para admin y encargado.
    v_es_admin := (v_rol = 'admin') OR EXISTS (
      SELECT 1 FROM usuario_sucursales us
      WHERE us.usuario_id = auth.uid()
        AND (CASE WHEN us.rol = 'mismo' THEN v_rol ELSE us.rol END) = 'admin');$ancla$;
  v_nuevo text := $nuevo$    -- Admin por perfiles.rol, el único rol desde la 486 (#1519): el de cada
    -- sucursal era el mismo. Rol CRUDO: nunca es_preventista()/es_transportista(),
    -- que dan true para admin y encargado.
    v_es_admin := (v_rol = 'admin');$nuevo$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla) <> 1 THEN
    RAISE EXCEPTION 'reporte_stock_red cambió: el ancla del rol de admin no aparece exactamente una vez';
  END IF;
  EXECUTE replace(v_def, v_ancla, v_nuevo);
END
$parche_stock_red$;

DO $parche_edicion$
DECLARE
  v_def   text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)'::regprocedure);
  v_ancla text := $ancla$  -- envio_historial_y_rol (#1232): quien decide el envio es el rol de la
  -- sucursal activa, el mismo que usa el front para mostrar el dialogo
  -- (effectiveRol = usuario_sucursales.rol, 'mismo' = perfiles.rol); sin fila
  -- en la sucursal, perfiles.rol. Solo para el envio: el resto de la funcion
  -- sigue con v_user_role.
  v_es_preventista := COALESCE(public._rol_en_sucursal(p_usuario_id, v_sucursal), v_user_role)
                        NOT IN ('admin', 'encargado');$ancla$;
  v_nuevo text := $nuevo$  -- envio_historial_y_rol (#1232): quien decide el envio es el rol del que
  -- edita, el mismo que usa el front para mostrar el dialogo. Desde la 486
  -- (#1519) es uno solo en toda sucursal, perfiles.rol: v_user_role.
  v_es_preventista := v_user_role NOT IN ('admin', 'encargado');$nuevo$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla) <> 1 THEN
    RAISE EXCEPTION 'actualizar_pedido_items cambió: el ancla del rol del envío no aparece exactamente una vez';
  END IF;
  EXECUTE replace(v_def, v_ancla, v_nuevo);
END
$parche_edicion$;

-- ===========================================================================
-- GTO-1 · el personal en audit_logs, sólo para quien tiene todas las sucursales
-- ===========================================================================
CREATE FUNCTION public.es_admin_de_todas_las_sucursales()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- Admin activo y asignado a todas las sucursales activas: el que ve a un
  -- empleado «de las dos» (_empleado_visible). Para policies, que se evalúan
  -- como el usuario: _tiene_todas_las_sucursales() no tiene EXECUTE para
  -- authenticated (GTO-1, #1519).
  SELECT public.es_admin() AND public._tiene_todas_las_sucursales();
$function$;

REVOKE EXECUTE ON FUNCTION public.es_admin_de_todas_las_sucursales() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.es_admin_de_todas_las_sucursales() TO authenticated, service_role;

-- empleados y empleado_*: el sueldo, el CUIL, el teléfono y las liquidaciones.
ALTER POLICY mt_audit_logs_select ON public.audit_logs
  USING (es_admin() AND sucursal_id = current_sucursal_id()
         AND (tabla NOT LIKE 'empleado%' OR es_admin_de_todas_las_sucursales()));
COMMENT ON POLICY mt_audit_logs_select ON public.audit_logs IS
  'Las filas de personal (empleados y empleado_*: sueldo, CUIL, teléfono, liquidaciones) sólo las lee el admin '
  'de todas las sucursales (GTO-1, #1519). Una tabla de personal nueva con auditoría se llama empleado_*, o se suma acá.';

-- ===========================================================================
-- SEG-04 · el preventista ve los pagos de sus boletas y las sustituciones de sus pedidos
-- ===========================================================================
ALTER POLICY mt_pagos_select ON public.pagos
  USING (sucursal_id = current_sucursal_id()
         AND (es_encargado_o_admin()
              OR (es_transportista() AND pedido_id IS NOT NULL
                  AND EXISTS (SELECT 1 FROM pedidos pd
                               WHERE pd.id = pagos.pedido_id AND pd.transportista_id = auth.uid()
                                 AND pd.sucursal_id = current_sucursal_id()))
              -- Las boletas que ve (la RLS de pedidos) y los créditos sueltos de
              -- los clientes que opera: sin asignar o suyos, y no reservados.
              OR (es_preventista()
                  AND ((pedido_id IS NOT NULL
                        AND EXISTS (SELECT 1 FROM pedidos pd WHERE pd.id = pagos.pedido_id))
                       OR (pedido_id IS NULL
                           AND EXISTS (SELECT 1 FROM clientes c
                                        WHERE c.id = pagos.cliente_id AND NOT c.reservado_admin
                                          AND (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp
                                                            WHERE cp.cliente_id = c.id)
                                               OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                                                           WHERE cp.cliente_id = c.id
                                                             AND cp.preventista_id = auth.uid()))))))));

ALTER POLICY mt_sust_select ON public.pedido_item_sustituciones
  USING (sucursal_id = current_sucursal_id()
         AND EXISTS (SELECT 1 FROM pedidos pd WHERE pd.id = pedido_item_sustituciones.pedido_id));

-- ===========================================================================
-- GTO-10 · fugas menores de personal
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.cliente_admite_adelanto_sueldo(p_cliente_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un admin o el encargado eligen un empleado' USING ERRCODE = '42501';
  END IF;
  -- Sólo por un cliente de la sucursal activa (GTO-10, #1519): con el id de uno
  -- de otra sucursal se sabía si era la cuenta de un empleado.
  RETURN EXISTS (SELECT 1
                   FROM empleados e
                   JOIN clientes c ON c.id = e.cliente_id
                  WHERE e.cliente_id = p_cliente_id AND e.activo
                    AND c.sucursal_id = public.current_sucursal_id());
END
$function$;

CREATE OR REPLACE FUNCTION public.empleados_para_elegir()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actual bigint := public.current_sucursal_id();
BEGIN
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un admin o el encargado eligen un empleado' USING ERRCODE = '42501';
  END IF;
  -- El usuario_id va sólo si quien llama ya ve ese perfil, con las reglas de las
  -- policies de SELECT de perfiles (GTO-10, #1519). El front lo usa con los de la
  -- sucursal activa: no cargarse un gasto a sí mismo y el vehículo del chofer.
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('id', e.id, 'nombre', e.nombre,
                                        'usuario_id', CASE WHEN public.perfil_de_sucursal_activa(e.usuario_id)
                                                             OR public.admin_comparte_sucursal_con(e.usuario_id)
                                                           THEN e.usuario_id END,
                                        'vehiculo_id', e.vehiculo_id, 'activo', e.activo)
                     ORDER BY e.nombre, e.id)
      FROM empleados e
     WHERE v_actual IS NOT NULL AND (e.sucursal_id = v_actual OR e.de_las_dos)), '[]'::jsonb);
END
$function$;

DO $parche_faltantes$
DECLARE
  v_def   text := pg_get_functiondef('public.obtener_faltantes_rendiciones(date,date,uuid)'::regprocedure);
  v_ancla text := $ancla$           'empleado', CASE WHEN e.id IS NULL THEN NULL
                            ELSE jsonb_build_object('id', e.id, 'nombre', e.nombre) END,$ancla$;
  v_nuevo text := $nuevo$           -- Al transportista no se le dice a qué otro empleado se le cargó
           -- una línea de su rendición (GTO-10, #1519): la ve sin empleado.
           'empleado', CASE WHEN e.id IS NULL THEN NULL
                            WHEN es_encargado_o_admin() OR e.usuario_id = auth.uid()
                              THEN jsonb_build_object('id', e.id, 'nombre', e.nombre) END,$nuevo$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla) <> 1 THEN
    RAISE EXCEPTION 'obtener_faltantes_rendiciones cambió: el ancla del empleado no aparece exactamente una vez';
  END IF;
  EXECUTE replace(v_def, v_ancla, v_nuevo);
END
$parche_faltantes$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, las policies y los permisos quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT e.firma, e.md5, (SELECT md5(p.prosrc) FROM pg_proc p WHERE p.oid = to_regprocedure(e.firma)) AS vivo
      FROM (VALUES
        ('public._rol_en_sucursal(uuid,bigint)', '7c3ecc88f4563d27544e3f2abeb53c44'),
        ('public._notificar_sucursal_roles(bigint,uuid,character varying,text,text,character varying,bigint,jsonb)', 'b8e8ff8eef31f6a5088fb5ed7c0aa758'),
        ('public.obtener_sucursales_usuario()', '2594242963c392a305ba602ec6f51737'),
        ('public.asignar_usuario_sucursal(uuid,bigint,boolean)', 'd8799feaf27a9e19294ca4e98a85bcfa'),
        ('public.reporte_stock_red(bigint)', '02e17a7211a997305507e19124223a4d'),
        ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'ffeb5f8e91a22f1718cdb928b2eb1dcb'),
        ('public.es_admin_de_todas_las_sucursales()', 'ee682b69792f91a86d61bfef244936dc'),
        ('public.cliente_admite_adelanto_sueldo(bigint)', 'ff9dbfbca24a7953a41ca6e027d8dc75'),
        ('public.empleados_para_elegir()', 'a98796d334cc393afacafc069ccbb078'),
        ('public.obtener_faltantes_rendiciones(date,date,uuid)', 'febc22280482b1420e9d36104420071c')
      ) AS e(firma, md5)
  LOOP
    IF r.vivo IS DISTINCT FROM r.md5 THEN
      RAISE EXCEPTION '% no quedó como en el repo: md5 % (se esperaba %)', r.firma, r.vivo, r.md5;
    END IF;
  END LOOP;

  IF to_regprocedure('public.asignar_usuario_sucursal(uuid,bigint,character varying,boolean)') IS NOT NULL THEN
    RAISE EXCEPTION 'quedó la firma vieja de asignar_usuario_sucursal';
  END IF;

  FOR r IN
    SELECT e.firma,
           has_function_privilege('authenticated', e.firma, 'EXECUTE') AS auth_ok,
           has_function_privilege('anon', e.firma, 'EXECUTE') AS anon_ok
      FROM (VALUES ('public.asignar_usuario_sucursal(uuid,bigint,boolean)'),
                   ('public.es_admin_de_todas_las_sucursales()')) AS e(firma)
  LOOP
    IF NOT r.auth_ok OR r.anon_ok THEN
      RAISE EXCEPTION '%: EXECUTE de authenticated %, de anon %', r.firma, r.auth_ok, r.anon_ok;
    END IF;
  END LOOP;

  FOR r IN
    SELECT e.tabla, e.policy, e.md5, md5(p.qual) AS qual
      FROM (VALUES ('audit_logs', 'mt_audit_logs_select', 'c740acc1955ec47b39bd9059a67322ce'),
                   ('pagos', 'mt_pagos_select', '9f772cf80b56f49a4973ada145746083'),
                   ('pedido_item_sustituciones', 'mt_sust_select', 'b2435b416a91006009dcecbea386c24d')
           ) AS e(tabla, policy, md5)
      LEFT JOIN pg_policies p ON p.schemaname = 'public' AND p.tablename = e.tabla AND p.policyname = e.policy
  LOOP
    IF r.qual IS DISTINCT FROM r.md5 THEN
      RAISE EXCEPTION 'la policy %.% no quedó como en el repo: md5 USING %', r.tabla, r.policy, r.qual;
    END IF;
  END LOOP;

  -- Ninguna función lee ya el rol de usuario_sucursales.
  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE pronamespace = 'public'::regnamespace
                AND prosrc ~ '(\mus\d?\.rol\M|usuario_sucursales\.rol\M)') THEN
    RAISE EXCEPTION 'quedó una función que lee usuario_sucursales.rol: %',
      (SELECT string_agg(oid::regprocedure::text, ', ') FROM pg_proc
        WHERE pronamespace = 'public'::regnamespace
          AND prosrc ~ '(\mus\d?\.rol\M|usuario_sucursales\.rol\M)');
  END IF;

  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conrelid = 'public.usuario_sucursales'::regclass AND conname = 'usuario_sucursales_rol_mismo')
     IS DISTINCT FROM 'CHECK (((rol)::text = ''mismo''::text))' THEN
    RAISE EXCEPTION 'el CHECK usuario_sucursales_rol_mismo no quedó como en el repo';
  END IF;
END
$post$;

COMMIT;
