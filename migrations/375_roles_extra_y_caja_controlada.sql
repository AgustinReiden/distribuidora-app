-- #1170, #1171 y #1175 · Los roles extra en los triggers de columnas, y la caja
-- controlada que un PATCH del chofer o del vendedor podía reabrir.
--
-- EL BUG
--   · #1170 · pedidos_proteger_columnas entra a la rama del transportista
--     cuando es_transportista() da true, y da true también por el rol extra de
--     perfil_roles (trampa 4). Un preventista con extra transportista cae en
--     esa rama en SUS pedidos, que sólo deja cambiar estado, fecha_entrega y
--     updated_at: guardar notas o fecha_entrega_programada desde
--     ModalEditarPedido o «Notas» le da 42501 «Un transportista solo puede
--     confirmar la entrega». En prod: fe9d6d6b, con 18 pedidos propios
--     pendientes.
--   · #1171 · clientes_proteger_columnas_preventista decide por perfiles.rol =
--     'preventista', y mt_clientes_update exime con el mismo predicado. Quien
--     tenga otro rol base y el preventista como rol extra pasa la policy por
--     es_preventista() y queda sin allow-list ni filtro de asignación. Hoy es
--     latente: perfil_roles_rol_check sólo admite 'transportista'.
--   · #1175 · anular_control_por_cambio_fecha_entrega (DEFINER, AFTER UPDATE)
--     borra el rendiciones_control del día cuando cambian fecha_entrega,
--     transportista_id o el estado, sea cual sea su estado. El chofer (rama
--     del transportista) y el preventista dueño (rama general) podían
--     disparar ese borrado por REST: mover la fecha de un entregado, cambiarle
--     el chofer, desmarcarlo, o marcar entregado hacia un día ya controlado. Y
--     el chofer podía cambiar la fecha_entrega de un pedido de baja, que desde
--     #1149 conserva su transportista_id. Borrar un control confirmada o
--     resuelta reabre el día para rendicion_dia_cerrada y, si era el último,
--     baja ultima_fecha_caja_cerrada. En prod nunca pasó: 289 controles y 289
--     INSERT auditados desde el 15-05, 0 DELETE.
--
-- EL ARREGLO (decisiones del dueño, 2026-10-14: #1170 a, #1171 b, #1175 a,
-- con el guard de caja común a todas las ramas)
--   1 · control_rendicion_cerrado(transportista, sucursal, fecha): helper
--       DEFINER nuevo, booleano y sin montos, porque pedidos_proteger_columnas
--       corre como authenticated y mt_rendiciones_control_select sólo deja
--       leer a admin y encargado. rendicion_dia_cerrada no sirve: mira el día
--       y no al chofer, y rechazaría entregas legítimas de otro chofer. No
--       lleva guard de rol: devolverle false a alguien dejaría el guard de caja
--       abierto para él. Va a la lista blanca de SEG-A en la migración
--       siguiente, que se aplica justo después de ésta.
--   2 · pedidos_proteger_columnas():
--       (a) #1175, bloque común después del alta y antes de partir en ramas
--           (admin, encargado y server ya salieron arriba). Rechaza con 42501:
--           un cambio de fecha_entrega en un pedido de baja, y todo cambio
--           que haría borrar un control confirmada o resuelta. Espeja las DOS
--           condiciones de anular_control_por_cambio_fecha_entrega. No se mete
--           en los cambios de ESTADO de una baja: esos los rechaza
--           pedidos_guard_baja (corre después, por orden alfabético) con su
--           propio mensaje.
--       (b) #1170: la rama del transportista rige sólo en los pedidos a los
--           que el usuario llega como chofer, no como vendedor
--           (OLD.usuario_id IS DISTINCT FROM auth.uid()). En un pedido propio
--           rige la regla general, como para cualquier preventista; lo que eso
--           le habilita de más (fecha_entrega, transportista_id y estado de un
--           pedido propio que él mismo lleva) lo cubre el guard de caja.
--   3 · clientes_proteger_columnas_preventista(): decide con la regla de la
--       policy, es_preventista() AND NOT es_encargado_o_admin(), y no con
--       perfiles.rol.
--   4 · mt_clientes_update: la exención pasa de NOT EXISTS (perfiles ... rol =
--       'preventista') a es_encargado_o_admin(). Bajo es_preventista() da lo
--       mismo para todos los usuarios de hoy.
--   anular_control_por_cambio_fecha_entrega NO se toca: el server y el admin
--   conservan el borrado, que es parte del diseño. Sólo recibe un COMMENT.
--
-- NO CAMBIA
--   · Ningún GRANT de tabla ni grants-rest.json. Los triggers no se recrean
--     (BEFORE INSERT OR UPDATE / BEFORE UPDATE, sin OF).
--   · STK-F / STK-D / COSTO-D / PRECIO-A: no se mueve stock, costo ni precio.
--   · Esto NO habilita a ampliar perfil_roles_rol_check: mt_clientes_select y
--     unas 17 funciones siguen decidiendo por perfiles.rol = 'preventista'
--     (issue aparte).
--
-- Riesgo conocido: un replay offline que marca entregado hacia un día cuyo
-- control ya está confirmado ahora falla con el 42501 del guard (antes borraba
-- el control sin aviso). El mensaje dice que lo haga un encargado.
--
-- Ensayo: scripts/test-roles-columnas-caja-1170-1171-1175.sql (falla antes,
-- pasa después).

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 1. control_rendicion_cerrado
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.control_rendicion_cerrado(
  p_transportista_id uuid, p_sucursal_id bigint, p_fecha date)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  -- #1175: lo llama pedidos_proteger_columnas (INVOKER, como authenticated),
  -- que no ve rendiciones_control por RLS. Booleano, sin montos. Misma
  -- naturaleza que rendicion_dia_cerrada (lista blanca de SEG-A).
  SELECT EXISTS (SELECT 1 FROM rendiciones_control
                  WHERE transportista_id = p_transportista_id
                    AND sucursal_id = p_sucursal_id
                    AND fecha = p_fecha
                    AND estado IN ('confirmada', 'resuelta'));
$fn$;

REVOKE ALL ON FUNCTION public.control_rendicion_cerrado(uuid, bigint, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.control_rendicion_cerrado(uuid, bigint, date) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. pedidos_proteger_columnas: guard de caja común (#1175) y la rama del
--    chofer sólo para pedidos ajenos (#1170). Copiada de pg_get_functiondef de
--    prod (2026-10-14, md5 de prosrc ea77b0fc777fff28505411fe255e41d4).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pedidos_proteger_columnas()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_bloqueadas text;
BEGIN
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;

  -- ---- Alta: la venta es de quien la carga (mig 219, issue #549) ----------
  IF TG_OP = 'INSERT' THEN
    IF NEW.usuario_id IS NOT NULL AND NEW.usuario_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'Un pedido se atribuye a quien lo carga: no podés crear uno a nombre de otro usuario (usuario_id %). Solo un administrador o encargado puede hacerlo.',
        NEW.usuario_id
        USING ERRCODE = '42501';
    END IF;

    -- Mig 233 (a): `creado_por` es la autoría de la CARGA. Misma regla.
    IF NEW.creado_por IS NOT NULL AND NEW.creado_por IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'No podés registrar un pedido como cargado por otro usuario (creado_por %). Solo un administrador o encargado puede hacerlo.',
        NEW.creado_por
        USING ERRCODE = '42501';
    END IF;

    -- Mig 233 (b): se ASIGNA, no se rechaza (molde de pagos_forzar_usuario, 190b).
    IF NEW.usuario_id IS NULL THEN
      NEW.usuario_id := auth.uid();
    END IF;

    RETURN NEW;
  END IF;

  -- ---- De acá abajo es UPDATE (usa OLD) ----------------------------------

  -- #1175. Un cambio de ESTADO de una baja lo rechaza pedidos_guard_baja
  -- (corre después, por orden alfabético) con su propio mensaje: acá no se
  -- toca, para no taparlo.
  IF NOT (OLD.estado IN ('cancelado','anulado') AND NEW.estado IS DISTINCT FROM OLD.estado) THEN
    -- (1) Una baja no cambia la fecha de entrega.
    IF OLD.estado IN ('cancelado','anulado')
       AND NEW.fecha_entrega IS DISTINCT FROM OLD.fecha_entrega THEN
      RAISE EXCEPTION 'El pedido #% está %: su fecha de entrega no se cambia. Si hay que corregirla, pedíselo a un encargado o administrador.',
        OLD.id, OLD.estado USING ERRCODE = '42501';
    END IF;
    -- (2) Ningún cambio desde la app borra un control cerrado. Espeja las DOS
    -- condiciones de anular_control_por_cambio_fecha_entrega (mismo ::date,
    -- misma sesión): si cambia una, cambiá la otra. El server (DEFINER) y el
    -- admin/encargado no pasan por acá y siguen borrando por diseño.
    IF OLD.fecha_entrega IS NOT NULL AND OLD.transportista_id IS NOT NULL
       AND (NEW.fecha_entrega IS NULL
            OR OLD.fecha_entrega::date IS DISTINCT FROM NEW.fecha_entrega::date
            OR (NEW.estado = 'cancelado' AND OLD.estado = 'entregado')
            OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id)
       AND public.control_rendicion_cerrado(OLD.transportista_id, OLD.sucursal_id, OLD.fecha_entrega::date) THEN
      RAISE EXCEPTION 'La rendición del % de ese transportista ya fue controlada: este cambio la reabriría. Pedile a un encargado o administrador que lo haga.',
        to_char(OLD.fecha_entrega::date, 'DD/MM/YYYY') USING ERRCODE = '42501';
    END IF;
    IF NEW.fecha_entrega IS NOT NULL AND NEW.transportista_id IS NOT NULL AND NEW.estado = 'entregado'
       AND (OLD.fecha_entrega IS NULL
            OR OLD.fecha_entrega::date IS DISTINCT FROM NEW.fecha_entrega::date
            OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id)
       AND public.control_rendicion_cerrado(NEW.transportista_id, NEW.sucursal_id, NEW.fecha_entrega::date) THEN
      RAISE EXCEPTION 'La rendición del % de ese transportista ya fue controlada: este cambio la reabriría. Pedile a un encargado o administrador que lo haga.',
        to_char(NEW.fecha_entrega::date, 'DD/MM/YYYY') USING ERRCODE = '42501';
    END IF;
  END IF;

  -- #1170: la rama del chofer es para los pedidos a los que llega SÓLO como
  -- chofer. es_transportista() da true por el rol extra (trampa 4): en un
  -- pedido propio rige la regla del vendedor, como para cualquier preventista.
  IF es_transportista() AND OLD.usuario_id IS DISTINCT FROM auth.uid() THEN
    SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
    FROM jsonb_each(to_jsonb(OLD)) o
    JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
    WHERE o.value IS DISTINCT FROM n.value
      AND o.key NOT IN ('estado', 'fecha_entrega', 'updated_at');

    IF v_bloqueadas IS NOT NULL THEN
      RAISE EXCEPTION 'Un transportista solo puede confirmar la entrega. Columnas rechazadas: %',
        v_bloqueadas
        USING ERRCODE = '42501';
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado AND NEW.estado <> 'entregado' THEN
      RAISE EXCEPTION 'Un transportista solo puede marcar la entrega, no pasar el pedido a "%"',
        NEW.estado
        USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
  END IF;

  -- #1155: 'fecha' (la del pedido, no la de entrega) sólo la cambian admin y
  -- encargado: la venta por vendedor y la comisión se atribuyen por ella
  -- (migs 241/318), y la vigencia de la promo en la edición también (#1137).
  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key IN (
      'total', 'total_neto', 'total_iva', 'total_real', 'monto_pagado',
      'estado_pago', 'cliente_id', 'sucursal_id', 'usuario_id', 'creado_por',
      'preventista_id', 'tipo_factura', 'stock_descontado', 'offline_id',
      'fecha'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'No tenes permiso para modificar estas columnas de pedidos: %',
      v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.pedidos_proteger_columnas() FROM PUBLIC, anon, authenticated;

-- Conserva la descripción que ya tenía (prod, 2026-10-14) y le suma el aviso.
COMMENT ON FUNCTION public.anular_control_por_cambio_fecha_entrega() IS
  'Trigger: anula rendiciones_control de los días afectados cuando cambia fecha_entrega, estado=cancelado o transportista de un pedido entregado. Espejo de sus condiciones en pedidos_proteger_columnas (#1175): si cambia una, cambiá la otra.';

-- ---------------------------------------------------------------------------
-- 3. clientes_proteger_columnas_preventista: la regla de la policy (#1171).
--    Copiada de pg_get_functiondef de prod (2026-10-14, md5 de prosrc
--    38c522039b3de7cb523959d3e092c9eb).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clientes_proteger_columnas_preventista()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_bloqueadas text;
BEGIN
  -- RPCs SECURITY DEFINER, service_role, conexiones directas: exentas.
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  -- Cascadas desde otros triggers (saldo_cuenta desde pedidos): exentas.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  -- #1171: la misma regla que mt_clientes_update. es_preventista() da true
  -- también a admin/encargado (trampa 4) y al rol extra de perfil_roles.
  IF es_encargado_o_admin() OR NOT es_preventista() THEN
    RETURN NEW;
  END IF;

  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key NOT IN (
      'razon_social', 'direccion', 'aclaracion_direccion', 'latitud',
      'longitud', 'telefono', 'contacto', 'horarios_atencion', 'rubro', 'notas',
      -- Mig 140: el horario canónico se carga junto con los días.
      'dias_atencion', 'horarios_atencion_original',
      -- Mig 157: escape del horario obligatorio al cargar un pedido.
      'sin_horario_fijo',
      -- Mig 233: `place_id` (mig 151) es la evidencia de qué lugar eligió el
      -- preventista en el autocompletado. Viaja en el mismo patch que
      -- `direccion`/`latitud`/`longitud` y cambia con ellos; sin esta línea,
      -- corregir una dirección desde el buscador devolvía 42501.
      'place_id'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'Un preventista no puede modificar estas columnas de clientes: %',
      v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.clientes_proteger_columnas_preventista() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. mt_clientes_update: la exención por es_encargado_o_admin() (#1171).
--    Expresión viva de prod (mig 359) con ese único cambio; USING y WITH CHECK
--    iguales.
-- ---------------------------------------------------------------------------
ALTER POLICY mt_clientes_update ON public.clientes
  USING (
    es_preventista() AND sucursal_id = current_sucursal_id() AND (
      es_encargado_o_admin()
      OR (NOT reservado_admin AND (
            NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = clientes.id)
         OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                     WHERE cp.cliente_id = clientes.id AND cp.preventista_id = auth.uid()))))
  )
  WITH CHECK (
    es_preventista() AND sucursal_id = current_sucursal_id() AND (
      es_encargado_o_admin()
      OR (NOT reservado_admin AND (
            NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = clientes.id)
         OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                     WHERE cp.cliente_id = clientes.id AND cp.preventista_id = auth.uid()))))
  );

-- ---------------------------------------------------------------------------
-- 5. Verificación estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f_hlp text := 'public.control_rendicion_cerrado(uuid,bigint,date)';
  f_ped text := 'public.pedidos_proteger_columnas()';
  f_cli text := 'public.clientes_proteger_columnas_preventista()';
  f_anu text := 'public.anular_control_por_cambio_fecha_entrega()';
  v_ped text := pg_get_functiondef(f_ped::regprocedure);
  v_cli text := pg_get_functiondef(f_cli::regprocedure);
  r     record;
BEGIN
  IF position('OLD.usuario_id IS DISTINCT FROM auth.uid()' IN v_ped) = 0
     OR (length(v_ped) - length(replace(v_ped, 'control_rendicion_cerrado', ''))) / length('control_rendicion_cerrado') <> 2
     OR position('NEW.estado IS DISTINCT FROM OLD.estado' IN v_ped) = 0
     OR v_ped LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION 'pedidos_proteger_columnas no quedó como se esperaba';
  END IF;

  IF NOT has_function_privilege('authenticated', f_hlp::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', f_hlp::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'control_rendicion_cerrado: authenticated tiene que tener EXECUTE y anon no';
  END IF;
  IF has_function_privilege('authenticated', f_ped::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', f_ped::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', f_cli::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', f_cli::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'una función de trigger quedó con EXECUTE para authenticated o anon';
  END IF;

  IF position('perfiles' IN v_cli) > 0 OR position('es_preventista()' IN v_cli) = 0 THEN
    RAISE EXCEPTION 'clientes_proteger_columnas_preventista sigue decidiendo por perfiles';
  END IF;

  SELECT qual, with_check INTO r FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'clientes' AND policyname = 'mt_clientes_update';
  IF NOT FOUND OR r.qual LIKE '%p.rol = ''preventista''%' OR r.with_check LIKE '%p.rol = ''preventista''%'
     OR r.qual NOT LIKE '%es_encargado_o_admin()%' OR r.with_check NOT LIKE '%es_encargado_o_admin()%' THEN
    RAISE EXCEPTION 'mt_clientes_update no quedó como se esperaba';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pedidos'::regclass
                    AND tgname = 'trg_pedidos_anular_control')
     OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = f_anu::regprocedure) <> '31dc5e6f1406250505d7bf6db1759e46' THEN
    RAISE EXCEPTION 'anular_control_por_cambio_fecha_entrega o su trigger cambiaron';
  END IF;

  -- Una sola sobrecarga del helper (PGRST203).
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname = 'control_rendicion_cerrado') <> 1 THEN
    RAISE EXCEPTION 'hay más de una sobrecarga de control_rendicion_cerrado';
  END IF;
END
$verif$;
