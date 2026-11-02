-- Permisos por sucursal: lo que quedó de #1291 y #1272 (#1374) y las RPCs definer
-- que leían o escribían otra sucursal (#1334). Tarjeta 3 del plan #1378.
--
-- QUÉ CAMBIA
--   · cliente_preventistas_no_ajeno (#1374): el admin sólo le asigna a un cliente
--     a alguien de la sucursal del cliente. El trigger salía con es_admin() antes
--     de mirar nada. Esto cierra además un caso que el issue no nombra: la segunda
--     rama de cp_insert (preventista_id = auth.uid()) no mira el cliente, y un
--     admin de Tucumán se asignaba a sí mismo un cliente de Taco Pozo.
--   · aplicar_control_stock (#1374): el detalle de la planilla ya cargada (fecha,
--     número de control, cantidad de ajustes) sale sólo si es de la sucursal activa.
--   · guardar_analisis_mensual (#1334): la sucursal tiene que ser del admin, y la
--     Red (NULL) sólo la escribe el admin de todas.
--   · ultima_fecha_caja_cerrada, rendicion_dia_cerrada y control_rendicion_cerrado
--     (#1334): sólo contestan por las sucursales del que llama, sea cual sea su rol.
--   · reporte_ventas_por_cliente (#1334): meta.preventista_nombre sale sólo si el
--     perfil es de las sucursales del reporte o vendió en ellas. El que dejó la
--     sucursal sigue teniendo nombre, como en el desplegable de vendedores.
--   · auditoria_definer_sin_rol: sólo los tres md5 de su lista blanca (SEG-A).
--
-- POR QUÉ LEVANTAN EN VEZ DE DEVOLVER false
--   Las tres de la caja las llaman guards: `IF rendicion_dia_cerrada(...) THEN
--   RAISE`, `v_limite IS NOT NULL AND fecha <= v_limite`. Un false o un NULL para
--   una sucursal ajena abriría la caja cerrada. Con el 42501 el camino se corta.
--   Tampoco se les puede sacar el EXECUTE: pedidos_proteger_columnas y
--   pagos_guard_anulacion_caja_cerrada son INVOKER, y el front las usa.
--
-- QUÉ SE REVISÓ (el 02/11, por la lista blanca de SEG-A, como en la 425)
--   · ultima_fecha_caja_cerrada.
--     Qué cambió: levanta 42501 si hay sesión y la sucursal no es del que llama. El
--     SELECT es el mismo, y sigue devolviendo una fecha, sin montos.
--     Quién la llama: el front (fecha mínima de un pago, con la sucursal activa),
--     guard_pago_fecha_cerrada, pagos_guard_anulacion_caja_cerrada (INVOKER),
--     _pedido_en_caja_cerrada (registrar_salvedad, anular_salvedad),
--     actualizar_forma_pago_pago, cambiar_tipo_factura_pedido,
--     cancelar_pedido_con_stock e imputar_credito_a_pedido_impl.
--   · rendicion_dia_cerrada.
--     Qué cambió: lo mismo, sobre COALESCE(p_sucursal_id, current_sucursal_id()). Con
--     las dos NULL sigue dando false, antes del chequeo.
--     Quién la llama: el front (ModalPagosMasivos, ModalEntregaYPagoMasivos),
--     marcar_entrega_y_pago_masivo_impl, marcar_pagos_masivo_impl,
--     registrar_pago_cliente_fifo_impl y registrar_pago_combinado_cliente_fifo_impl.
--   · control_rendicion_cerrado.
--     Qué cambió: lo mismo; el transportista sólo filtra dentro de esa sucursal, y
--     por eso queda en scripts/rpcs-definer-permitidas.json con ese motivo.
--     Quién la llama: pedidos_proteger_columnas (INVOKER), _guardar_gasto,
--     _anular_gasto, marcar_entrega_y_pago_masivo_impl y marcar_entregas_masivo.
--   Por qué las tres siguen exentas sin un guard de rol: no hay rol que excluir. Las
--   llaman guards de todos los roles (el chofer y el preventista, por los triggers
--   INVOKER), y el front con cualquiera de los que cobran. Lo que se acota es la
--   sucursal, y contestan menos que antes. Un guard que sólo nombre un helper
--   serviría únicamente para engañar la heurística (ver la 425).
--
--   Todos los llamadores pasan current_sucursal_id(), o la sucursal de una fila que
--   ya se filtró por ella; pedidos y pagos sólo se tocan por REST en la sucursal
--   activa (mt_pedidos_update, mt_pagos_delete). current_sucursal_id() valida el
--   header contra usuario_sucursales, así que esa sucursal siempre es del que llama,
--   o NULL. Por eso se pide estar en la sucursal y no que sea la activa. Con
--   auth.uid() NULL (server, bot, cron, MCP) nada cambia.
--   Único caso que ahora se corta: el encargado que edita un gasto suyo de rendición
--   en una sucursal que ya no tiene (_guardar_gasto, sucursal de la fila, sin
--   mirarla para el encargado). Hoy pasaba por un descuido, y es correcto que no.
--
-- QUÉ NO CAMBIA, Y POR QUÉ
--   · La policy cp_insert: el trigger corre antes y cubre sus dos ramas, con un
--     mensaje que se puede leer. La misma condición en la policy no cerraría el
--     caso de la segunda rama.
--   · guardar_meta_gerencial (COM-3, #1321) y registrar_origen_precio_items (#1329)
--     ya estaban acotadas. El ensayo las mira.
--   · reporte_stock_red: global a propósito, decisión del dueño (02/11, #1334).
--   · El admin puede asignarle un cliente a quien no actúa como preventista: lo que
--     cambia es la sucursal, no el rol (ver la 378).
--
-- PREMISAS: md5(prosrc) de prod del 02/11 de cada función que se toca. Si alguna
-- cambió, la migración falla sin tocar nada. Aplicar desde el contenido LF.
--
-- Ensayo: scripts/test-permisos-sucursal-1374-1334.sql

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ------------------------------------------------------------------ premisas -
DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.aplicar_control_stock(jsonb,text,uuid)',                 'bb51dc1cb6b7cb1cff4bcc3e6230749b'),
      ('public.cliente_preventistas_no_ajeno()',                        'f7c0232abec1dbf7126992c8113cfdab'),
      ('public.guardar_analisis_mensual(bigint,date,text,jsonb)',       '73990e666e8c9505c90429e0a77e4e80'),
      ('public.reporte_ventas_por_cliente(date,date,uuid,bigint)',      '508b53c6340ee3cf2f7aa133b51b9e60'),
      ('public.ultima_fecha_caja_cerrada(bigint)',                      '9528437b731a1dfc3d16acedf10f8bc2'),
      ('public.rendicion_dia_cerrada(date,bigint)',                     'b3434c512abbe0187f20056b94ead40e'),
      ('public.control_rendicion_cerrado(uuid,bigint,date)',            'ca6c8fb7fc3fd9f9cef46a211779b2f9'),
      ('public.auditoria_definer_sin_rol()',                            '08ab4305cd549f0e221a2f059bd000c8')
    ) AS t(firma, hash)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) <> r.hash THEN
      RAISE EXCEPTION '% cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
  END LOOP;
END
$premisas$;

-- ------------------------------------------------- parches por ancla (#1374) -
-- Sobre la definición viva: cada ancla tiene que estar exactamente una vez.
DO $parches$
DECLARE
  r     record;
  v_def text;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.cliente_preventistas_no_ajeno()',
       $viejo$  IF es_admin() THEN
    RETURN NEW;
  END IF;

  -- Reasignación por zona (mig 359): la inserta un trigger, no el usuario.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;
$viejo$,
       $nuevo$  -- Reasignación por zona (mig 359): la inserta un trigger, no el usuario. Va
  -- antes que el admin: un dueño de zona que dejó la sucursal no frena un cambio
  -- de zona.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  -- #1374: el admin elige a quién, pero entre los de la sucursal del cliente.
  -- cp_insert acota el cliente y no al preventista, y su segunda rama
  -- (preventista_id = auth.uid()) deja pasar a un admin con un cliente ajeno:
  -- esto cubre las dos. La FK de preventista_id va a perfiles, sin sucursal.
  IF es_admin() THEN
    IF NOT EXISTS (SELECT 1
                     FROM clientes c
                     JOIN usuario_sucursales us ON us.sucursal_id = c.sucursal_id
                    WHERE c.id = NEW.cliente_id
                      AND us.usuario_id = NEW.preventista_id) THEN
      RAISE EXCEPTION 'El preventista no es de la sucursal del cliente #%: no se le puede asignar.',
        NEW.cliente_id
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;
$nuevo$),

      ('public.aplicar_control_stock(jsonb,text,uuid)',
       $viejo$    SELECT s.id, s.fecha, s.total_items INTO v_previa
      FROM control_stock_sesiones s
     WHERE s.planilla_id = p_planilla_id;
$viejo$,
       $nuevo$    /* #1374 · El id es único en toda la base, pero esta función no pasa por
       RLS: el detalle de la planilla anterior sale sólo si es de esta sucursal. */
    SELECT s.id, s.fecha, s.total_items INTO v_previa
      FROM control_stock_sesiones s
     WHERE s.planilla_id = p_planilla_id
       AND s.sucursal_id = v_sucursal_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Esta planilla ya se cargó en otra sucursal: no se vuelve a aplicar. Para volver a contar, descargá una planilla nueva.';
    END IF;
$nuevo$),

      ('public.guardar_analisis_mensual(bigint,date,text,jsonb)',
       $viejo$    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  INSERT INTO reportes_mensuales$viejo$,
       $nuevo$    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;
  -- #1334: la sucursal es del admin, y la Red (NULL) la escribe el admin de todas.
  IF auth.uid() IS NOT NULL AND NOT comision_regla_alcanzable(p_sucursal_id) THEN
    RAISE EXCEPTION 'Acceso denegado: el análisis de otra sucursal, o de la Red, no lo puede guardar este usuario'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO reportes_mensuales$nuevo$),

      ('public.reporte_ventas_por_cliente(date,date,uuid,bigint)',
       $viejo$    SELECT nombre INTO v_prev_nombre FROM perfiles WHERE id = p_preventista_id;
$viejo$,
       $nuevo$    -- #1334: el nombre sale si es de las sucursales del reporte, o si vendió en
    -- ellas (el que se fue sigue en el desplegable de vendedores). Un perfil
    -- ajeno da lo mismo que un id que no existe.
    SELECT pf.nombre INTO v_prev_nombre
      FROM perfiles pf
     WHERE pf.id = p_preventista_id
       AND (auth.uid() IS NULL
            OR EXISTS (SELECT 1 FROM usuario_sucursales us
                        WHERE us.usuario_id = p_preventista_id
                          AND us.sucursal_id = ANY(v_sucursales))
            OR EXISTS (SELECT 1 FROM pedidos pe
                        WHERE pe.usuario_id = p_preventista_id
                          AND pe.sucursal_id = ANY(v_sucursales)));
$nuevo$)
    ) AS t(firma, viejo, nuevo)
  LOOP
    v_def := pg_get_functiondef(r.firma::regprocedure);
    IF (length(v_def) - length(replace(v_def, r.viejo, ''))) / length(r.viejo) <> 1 THEN
      RAISE EXCEPTION 'el ancla de % no aparece exactamente una vez: revisar a mano', r.firma;
    END IF;
    EXECUTE replace(v_def, r.viejo, r.nuevo);
  END LOOP;
END
$parches$;

-- ------------------------------------------------------- la caja (#1334) -
-- Pasan de sql a plpgsql: en sql no se puede levantar. El EXECUTE no cambia.
CREATE OR REPLACE FUNCTION public.ultima_fecha_caja_cerrada(p_sucursal_id bigint)
 RETURNS date
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- #1334: sólo de las sucursales del que llama. Levanta porque la usan los
  -- guards, y un NULL les abriría la caja cerrada. El server (auth.uid() NULL) no
  -- pasa por acá.
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM usuario_sucursales us
        WHERE us.usuario_id = auth.uid() AND us.sucursal_id = p_sucursal_id) THEN
    RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id
      USING ERRCODE = '42501';
  END IF;

  RETURN (SELECT MAX(fecha)
            FROM rendiciones_control
           WHERE sucursal_id = p_sucursal_id
             AND estado IN ('confirmada','resuelta'));
END;
$function$;

CREATE OR REPLACE FUNCTION public.rendicion_dia_cerrada(p_fecha date, p_sucursal_id bigint DEFAULT NULL::bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal bigint;
BEGIN
  v_sucursal := COALESCE(p_sucursal_id, current_sucursal_id());
  IF v_sucursal IS NULL THEN
    RETURN false;
  END IF;

  -- #1334: sólo de las sucursales del que llama. Levanta porque la usan los
  -- guards, y un false les abriría la caja cerrada. El server (auth.uid() NULL)
  -- no pasa por acá.
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM usuario_sucursales us
        WHERE us.usuario_id = auth.uid() AND us.sucursal_id = v_sucursal) THEN
    RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', v_sucursal
      USING ERRCODE = '42501';
  END IF;

  RETURN EXISTS (
    SELECT 1 FROM rendiciones_control
    WHERE fecha = p_fecha
      AND sucursal_id = v_sucursal
      AND estado IN ('confirmada', 'resuelta')
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.control_rendicion_cerrado(p_transportista_id uuid, p_sucursal_id bigint, p_fecha date)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- #1175: lo llama pedidos_proteger_columnas (INVOKER, como authenticated),
  -- que no ve rendiciones_control por RLS. Booleano, sin montos. Misma
  -- naturaleza que rendicion_dia_cerrada (lista blanca de SEG-A).
  -- #1334: sólo de las sucursales del que llama. Levanta porque la usan los
  -- guards, y un false les abriría el control cerrado. El server (auth.uid()
  -- NULL) no pasa por acá.
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM usuario_sucursales us
        WHERE us.usuario_id = auth.uid() AND us.sucursal_id = p_sucursal_id) THEN
    RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id
      USING ERRCODE = '42501';
  END IF;

  RETURN EXISTS (SELECT 1 FROM rendiciones_control
                  WHERE transportista_id = p_transportista_id
                    AND sucursal_id = p_sucursal_id
                    AND fecha = p_fecha
                    AND estado IN ('confirmada', 'resuelta'));
END;
$function$;

-- ------------------------------------------------- SEG-A: los tres md5 nuevos -
-- Revisado: siguen siendo un booleano o una fecha, sin montos, y ahora contestan
-- menos que antes. Sin guard de rol a propósito: las llaman guards de todos los
-- roles, y uno que sólo nombre un helper engañaría la heurística (ver la 425).
DO $sega$
DECLARE
  r     record;
  v_def text := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.ultima_fecha_caja_cerrada(bigint)',           '9528437b731a1dfc3d16acedf10f8bc2', 'cd39eceb6d9f4372c49a267151fb5c08'),
      ('public.rendicion_dia_cerrada(date,bigint)',          'b3434c512abbe0187f20056b94ead40e', '96bf9397648d73a7b77a2f84eb45cf24'),
      ('public.control_rendicion_cerrado(uuid,bigint,date)', 'ca6c8fb7fc3fd9f9cef46a211779b2f9', 'f6817668b4d37888aab2ea3e7addb645')
    ) AS t(firma, viejo, nuevo)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) <> r.nuevo THEN
      RAISE EXCEPTION '% quedó con otro cuerpo (md5 %): revisar antes de eximirla',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
    IF (length(v_def) - length(replace(v_def, r.viejo, ''))) / length(r.viejo) <> 1 THEN
      RAISE EXCEPTION 'el md5 viejo de % no aparece exactamente una vez en la lista blanca', r.firma;
    END IF;
    v_def := replace(v_def, r.viejo, r.nuevo);
  END LOOP;

  EXECUTE v_def;
END
$sega$;

REVOKE ALL ON FUNCTION public.auditoria_definer_sin_rol() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_definer_sin_rol() TO service_role;

-- ---------------------------------------------------------------- verificación -
DO $verif$
DECLARE
  v_sobran text;
BEGIN
  IF (SELECT count(*) FROM public.auditoria_definer_sin_rol()) <> 0 THEN
    RAISE EXCEPTION 'SEG-A no quedó en 0: %',
      (SELECT string_agg(firma || ' (' || motivo || ')', '; ') FROM public.auditoria_definer_sin_rol());
  END IF;

  -- Lo que sale de scripts/rpcs-definer-permitidas.json tiene que verse acotado.
  SELECT string_agg(x->>'firma' || '.' || (x->>'parametro'), ', ') INTO v_sobran
    FROM jsonb_array_elements(public.auditoria_rpcs_definer()->'parametros') x
   WHERE NOT (x->>'acotado')::boolean
     AND (x->>'nombre' || '.' || (x->>'parametro')) = ANY(ARRAY[
           'control_rendicion_cerrado.p_sucursal_id',
           'guardar_analisis_mensual.p_sucursal_id',
           'rendicion_dia_cerrada.p_sucursal_id',
           'reporte_ventas_por_cliente.p_preventista_id',
           'ultima_fecha_caja_cerrada.p_sucursal_id']);
  IF v_sobran IS NOT NULL THEN
    RAISE EXCEPTION 'el gate sigue viendo sin acotar: %', v_sobran;
  END IF;

  -- CREATE OR REPLACE conserva los grants: esto lo comprueba.
  IF NOT has_function_privilege('authenticated', 'public.ultima_fecha_caja_cerrada(bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rendicion_dia_cerrada(date,bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.control_rendicion_cerrado(uuid,bigint,date)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.ultima_fecha_caja_cerrada(bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rendicion_dia_cerrada(date,bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.control_rendicion_cerrado(uuid,bigint,date)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cliente_preventistas_no_ajeno()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.auditoria_definer_sin_rol()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.auditoria_definer_sin_rol()', 'EXECUTE') THEN
    RAISE EXCEPTION 'un grant quedó distinto del que tenía';
  END IF;
END
$verif$;

COMMIT;
