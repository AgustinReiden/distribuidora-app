-- Migración 332 (aplicada en prod el 2026-10-09).
-- #1034 · el vale blanco lo ven admin, encargado y quien lo cargó
-- #1049 · pedido_items no se escribe por REST
-- #1014 · el encargado lee proveedores
--
-- ── #1034 ────────────────────────────────────────────────────────────────────
-- En un vale blanco (tipo_factura = 'VB') el precio de cada línea y el total del
-- pedido SON el costo (`origen_precio = 'costo_interno'`, mig 317). Hasta acá
-- `mt_pedidos_select` dejaba leer un VB a quien lo cargó (`usuario_id`) y a quien
-- lo repartió (`transportista_id`). Los VB nuevos nacen entregados y sin
-- transportista, pero los 75 que convirtió la 320 vinieron de ruta y lo
-- conservan: 2 transportistas leían 74 pedidos, 205 líneas a costo y el historial
-- del total lista→costo.
--
-- Decisión del dueño (2026-10-09): un VB lo ven admin, encargado y el que lo
-- cargó —ése sigue viendo su total y sus líneas, como hasta ahora—; nadie más.
-- La RLS filtra filas, no columnas: "no ver el total" es no ver la fila. Por eso
-- el cambio va en el predicado de `pedidos`: la rama del transportista deja de
-- abrir los VB. "Quien lo cargó" es `usuario_id`, el de toda la app (mig 219:
-- la venta es de quien la carga).
--
--   * `pedido_items` y `pedido_historial` repiten la regla en su EXISTS. Se
--     escribe explícita en las dos (las subconsultas de una policy pasan por la
--     RLS de `pedidos` igual, pero así se lee lo que hacen).
--   * `puede_leer_pedido` y el inline de `deuda_previa`/`deuda_previa_detalle`
--     son copias DEFINER del predicado (#1009) y el check SEG-B
--     (`auditoria_predicado_pedidos`, mig 322) exige que digan lo mismo que la
--     policy: cambian juntas, en esta migración.
--   * `obtener_resumen_cuenta_cliente` es DEFINER y su `consumo_interno` sumaba
--     TODOS los VB del cliente para cualquiera que viera la ficha (transportista
--     incluido): un preventista que cargaba un VB de un ítem leía el costo como
--     la diferencia. Ahora admin y encargado ven todo; el resto, sólo lo que cargó.
--     Mismo alcance que la ficha del front, que lee `pedidos` por REST.
--
-- ── #1049 ────────────────────────────────────────────────────────────────────
-- `authenticated` (y `anon`) tenían INSERT y UPDATE sobre `pedido_items`, y
-- ningún trigger de INSERT pisa `costo_unitario_al_crear`: un preventista podía
-- insertar por REST una línea con el costo que quisiera en un pedido propio del
-- día. Y el trigger de UPDATE (`pedido_items_proteger_columnas`) era un oráculo:
-- escribir el costo exacto no daba error y cualquier otro valor daba 42501.
--
-- Relevado el 2026-10-09: nada escribe `pedido_items` por REST —ni el front, ni
-- la cola offline, ni las edge functions (la mig 243 ya decía que el INSERT
-- crudo no tenía un caller legítimo)—. Las diez funciones que la escriben
-- (crear_pedido_completo y su versión del bot, actualizar_pedido_items,
-- anular_salvedad, registrar_salvedad, sustituir/dividir_regalo_pedido,
-- registrar_origen_precio_items, cambiar_tipo_factura_pedido,
-- consolidar_condiciones) son SECURITY DEFINER de postgres y no dependen de este
-- privilegio. Se revoca INSERT y UPDATE de la tabla entera: el costo lo escribe
-- sólo el servidor, con `costo_valuacion` (COSTO-D), y el UPDATE falla por
-- privilegio antes de llegar al trigger, sea cual sea el valor —sin oráculo—.
-- Un REVOKE de tabla se lleva también los privilegios por columna.
-- `mt_pedido_items_insert`/`_update` y los triggers de guarda quedan como están:
-- sin el privilegio no se alcanzan, y si algún día vuelve el GRANT, siguen ahí.
--
-- ── #1014 ────────────────────────────────────────────────────────────────────
-- El encargado lee las seis tablas de compras desde la mig 316, pero no
-- `proveedores` (`es_admin() OR depósito`): en /compras veía "Sin proveedor" en
-- 183 de 191 compras y el selector del alta de compra le salía vacío. Mismo
-- predicado que `mt_compras_select`. La escritura sigue sólo de admin.

-- ── #1034 · policies ─────────────────────────────────────────────────────────

ALTER POLICY mt_pedidos_select ON public.pedidos
  USING (
    (es_encargado_o_admin()
     OR usuario_id = auth.uid()
     OR (transportista_id = auth.uid() AND tipo_factura IS DISTINCT FROM 'VB'))
    AND sucursal_id = current_sucursal_id()
  );

ALTER POLICY mt_pedido_items_select ON public.pedido_items
  USING (
    EXISTS (
      SELECT 1 FROM pedidos p
       WHERE p.id = pedido_items.pedido_id
         AND (es_encargado_o_admin()
              OR p.usuario_id = auth.uid()
              OR (p.transportista_id = auth.uid() AND p.tipo_factura IS DISTINCT FROM 'VB'))
    )
    AND sucursal_id = current_sucursal_id()
  );

ALTER POLICY mt_pedido_historial_select ON public.pedido_historial
  USING (
    sucursal_id = current_sucursal_id()
    AND EXISTS (
      SELECT 1 FROM pedidos p
       WHERE p.id = pedido_historial.pedido_id
         AND (es_encargado_o_admin()
              OR p.usuario_id = auth.uid()
              OR (p.transportista_id = auth.uid() AND p.tipo_factura IS DISTINCT FROM 'VB'))
    )
  );

-- ── #1034 · las copias DEFINER del predicado (SEG-B) ─────────────────────────

CREATE OR REPLACE FUNCTION public.puede_leer_pedido(p_pedido_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM pedidos pe
     WHERE pe.id = p_pedido_id
       AND pe.sucursal_id = current_sucursal_id()
       AND (   es_encargado_o_admin()
            OR pe.usuario_id = auth.uid()
            OR (pe.transportista_id = auth.uid() AND pe.tipo_factura IS DISTINCT FROM 'VB'))
  );
$function$;

CREATE OR REPLACE FUNCTION public.deuda_previa(p pedidos)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH ref AS (
    -- Solo `p.id` viene del caller; el resto se relee. Ver LA GUARDA arriba.
    SELECT pe.cliente_id, pe.created_at, pe.id, pe.sucursal_id
    FROM pedidos pe
    WHERE pe.id = p.id
      AND pe.sucursal_id = current_sucursal_id()
      -- #1009: y sólo si el caller puede leer el pedido. Es el predicado de
      -- mt_pedidos_select, inline por costo (ver la migración).
      AND (pe.usuario_id = auth.uid() OR (pe.transportista_id = auth.uid() AND pe.tipo_factura IS DISTINCT FROM 'VB') OR es_encargado_o_admin())
  )
  SELECT GREATEST(0, ROUND(
      COALESCE((
        SELECT SUM(GREATEST(0, p2.total - COALESCE(p2.monto_pagado, 0)))
        FROM pedidos p2, ref
        WHERE p2.cliente_id  = ref.cliente_id
          AND p2.sucursal_id = ref.sucursal_id
          AND p2.estado NOT IN ('cancelado', 'anulado')
          AND (p2.created_at, p2.id) < (ref.created_at, ref.id)
      ), 0)
    - COALESCE((
        SELECT SUM(pg.monto)
        FROM pagos pg, ref
        WHERE pg.cliente_id  = ref.cliente_id
          AND pg.sucursal_id = ref.sucursal_id
          AND pg.pedido_id IS NULL
          AND pg.created_at < ref.created_at
      ), 0)
  , 2));
$function$;

CREATE OR REPLACE FUNCTION public.deuda_previa_detalle(p pedidos)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH ref AS (
    -- Misma guarda que deuda_previa (mig 215): del caller solo se usa `p.id`.
    SELECT pe.cliente_id, pe.created_at, pe.id, pe.sucursal_id
    FROM pedidos pe
    WHERE pe.id = p.id
      AND pe.sucursal_id = current_sucursal_id()
      -- #1009: y sólo si el caller puede leer el pedido. Es el predicado de
      -- mt_pedidos_select, inline por costo (ver la migración).
      AND (pe.usuario_id = auth.uid() OR (pe.transportista_id = auth.uid() AND pe.tipo_factura IS DISTINCT FROM 'VB') OR es_encargado_o_admin())
  ),
  boletas AS (
    SELECT p2.id,
           COALESCE(p2.fecha, p2.created_at::date) AS fecha,
           ROUND(p2.total - COALESCE(p2.monto_pagado, 0), 2) AS monto
    FROM pedidos p2, ref
    WHERE p2.cliente_id  = ref.cliente_id
      AND p2.sucursal_id = ref.sucursal_id
      AND p2.estado NOT IN ('cancelado', 'anulado')
      AND (p2.created_at, p2.id) < (ref.created_at, ref.id)
      AND p2.total - COALESCE(p2.monto_pagado, 0) >= 0.01
    ORDER BY p2.created_at, p2.id
  )
  SELECT COALESCE(
    jsonb_agg(jsonb_build_object('id', id, 'fecha', fecha, 'monto', monto)),
    '[]'::jsonb
  )
  FROM boletas;
$function$;

CREATE OR REPLACE FUNCTION public.auditoria_predicado_pedidos(p_qual text DEFAULT NULL::text, p_n_select integer DEFAULT NULL::integer)
 RETURNS TABLE(problema text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  WITH esperado AS (
    SELECT
      -- mig 332 (#1034): la rama del transportista no abre los vales blancos.
      '((es_encargado_o_admin() OR (usuario_id = auth.uid()) OR ((transportista_id = auth.uid()) AND ((tipo_factura)::text IS DISTINCT FROM ''VB''::text))) AND (sucursal_id = current_sucursal_id()))'::text
        AS qual,
      'pe.sucursal_id = current_sucursal_id() AND ( es_encargado_o_admin() OR pe.usuario_id = auth.uid() OR (pe.transportista_id = auth.uid() AND pe.tipo_factura IS DISTINCT FROM ''VB''))'::text
        AS helper,
      -- El inline son dos piezas: la sucursal (la guarda de la 215) y el rol
      -- (la 314). Se buscan por separado para que un comentario entre las dos
      -- no cuente como cambio de criterio.
      'pe.sucursal_id = current_sucursal_id()'::text
        AS inline_sucursal,
      'AND (pe.usuario_id = auth.uid() OR (pe.transportista_id = auth.uid() AND pe.tipo_factura IS DISTINCT FROM ''VB'') OR es_encargado_o_admin())'::text
        AS inline_rol
  ),
  vivo AS (
    SELECT
      COALESCE(p_qual,
        (SELECT qual FROM pg_policies
          WHERE schemaname = 'public' AND tablename = 'pedidos'
            AND policyname = 'mt_pedidos_select')) AS qual,
      COALESCE(p_n_select,
        (SELECT count(*)::int FROM pg_policies
          WHERE schemaname = 'public' AND tablename = 'pedidos'
            AND cmd IN ('SELECT', 'ALL') AND permissive = 'PERMISSIVE')) AS n_select
  ),
  cuerpo AS (
    SELECT f.firma,
           regexp_replace(COALESCE(
             (SELECT p.prosrc FROM pg_proc p WHERE p.oid = to_regprocedure(f.firma)), ''),
             '\s+', ' ', 'g') AS src
      FROM unnest(ARRAY[
        'public.puede_leer_pedido(bigint)',
        'public.deuda_previa(public.pedidos)',
        'public.deuda_previa_detalle(public.pedidos)',
        'public.simular_salvedad_promo_impacto(bigint,bigint,integer)',
        'public.simular_salvedades_promo_impacto(bigint,jsonb)'
      ]) AS f(firma)
  )
  SELECT 'mt_pedidos_select cambió: dice ' || COALESCE(v.qual, '(no existe)')
    FROM vivo v, esperado e
   WHERE v.qual IS DISTINCT FROM e.qual
  UNION ALL
  SELECT format('pedidos tiene %s policies PERMISSIVE de SELECT (se esperaba 1): la visibilidad ya no es sólo mt_pedidos_select', v.n_select)
    FROM vivo v
   WHERE v.n_select IS DISTINCT FROM 1
  UNION ALL
  SELECT 'puede_leer_pedido ya no copia el predicado de mt_pedidos_select'
    FROM cuerpo c, esperado e
   WHERE c.firma = 'public.puede_leer_pedido(bigint)'
     AND position(e.helper IN c.src) = 0
  UNION ALL
  SELECT c.firma || ' ya no tiene el predicado inline de mt_pedidos_select'
    FROM cuerpo c, esperado e
   WHERE c.firma IN ('public.deuda_previa(public.pedidos)', 'public.deuda_previa_detalle(public.pedidos)')
     AND (position(e.inline_sucursal IN c.src) = 0 OR position(e.inline_rol IN c.src) = 0)
  UNION ALL
  SELECT c.firma || ' ya no pasa por puede_leer_pedido(p_pedido_id)'
    FROM cuerpo c
   WHERE c.firma LIKE 'public.simular_%'
     AND position('public.puede_leer_pedido(p_pedido_id)' IN c.src) = 0;
$function$;

-- ── #1034 · consumo interno de la ficha ──────────────────────────────────────

CREATE OR REPLACE FUNCTION public.obtener_resumen_cuenta_cliente(p_cliente_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN json_build_object('error', 'No autenticado');
  END IF;

  -- Mismo predicado que la política mt_clientes_select (migs 298 y #999).
  IF NOT EXISTS (
    SELECT 1 FROM clientes c
    WHERE c.id = p_cliente_id
      AND c.sucursal_id = current_sucursal_id()
      AND (
        NOT EXISTS (SELECT 1 FROM perfiles p WHERE p.id = auth.uid() AND p.rol = 'preventista')
        OR (
          (
            NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
            OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                       WHERE cp.cliente_id = c.id AND cp.preventista_id = auth.uid())
          )
          AND (
            NOT c.reservado_admin
            OR EXISTS (SELECT 1 FROM pedidos pe
                       WHERE pe.cliente_id = c.id AND pe.usuario_id = auth.uid())
          )
        )
      )
      AND NOT EXISTS (SELECT 1 FROM perfiles pd WHERE pd.id = auth.uid() AND pd.rol = 'deposito')
  ) THEN
    RAISE EXCEPTION 'Cliente % no encontrado o sin permiso para ver su cuenta', p_cliente_id
      USING ERRCODE = '42501';
  END IF;

  -- Un canje (canal 'cambio', total 0) no es un pedido del cliente: no cuenta en
  -- pedidos, compras, pendientes de pago ni en la fecha del ultimo (326, #1033).
  SELECT json_build_object(
    'saldo_actual', COALESCE(c.saldo_cuenta, 0),
    'limite_credito', COALESCE(c.limite_credito, 0),
    'credito_disponible', COALESCE(c.limite_credito, 0) - COALESCE(c.saldo_cuenta, 0),
    'total_pedidos', (SELECT COUNT(*) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND canal <> 'cambio'
                         AND tipo_factura IS DISTINCT FROM 'VB'),
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND canal <> 'cambio'
                         AND tipo_factura IS DISTINCT FROM 'VB'),
    'total_pagos', (SELECT COALESCE(SUM(monto), 0) FROM pagos WHERE cliente_id = p_cliente_id),
    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id
                                  AND canal <> 'cambio' AND estado_pago != 'pagado'),
    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND canal <> 'cambio'
                         AND tipo_factura IS DISTINCT FROM 'VB'),
    'ultimo_pago', (SELECT MAX(created_at) FROM pagos WHERE cliente_id = p_cliente_id),
    -- mig 332 (#1034): el total de un VB es su costo. Admin y encargado ven el
    -- consumo interno entero; el resto, sólo los vales que cargó (el alcance de
    -- mt_pedidos_select para un VB).
    'consumo_interno', (SELECT json_build_object('monto', COALESCE(SUM(total), 0), 'pedidos', COUNT(*))
                          FROM pedidos
                         WHERE cliente_id = p_cliente_id AND tipo_factura = 'VB'
                           AND estado IS DISTINCT FROM 'cancelado'
                           AND (es_encargado_o_admin() OR usuario_id = auth.uid()))
  ) INTO resultado
  FROM clientes c
  WHERE c.id = p_cliente_id;

  RETURN resultado;
END;
$function$;

-- ── #1034 · las RPCs que autorizaban al transportista por su cuenta ──────────
-- La RLS no alcanza a las DEFINER que deciden solas. Dos le abrían el VB a quien
-- lo repartió (revisión adversarial del 2026-10-09):
--
--   * `registrar_salvedad`: al que no es admin ni encargado lo autoriza con
--     `transportista_id = auth.uid()`. Sobre un VB le devolvía `monto_afectado`
--     (cantidad × precio de la línea = costo) y `nuevo_total_pedido`, y además le
--     dejaba MODIFICAR el vale. Se parchea la definición viva —no se reescribe
--     entera— para no pisar lo que otra rama le haya cambiado (molde de la 193):
--     el texto del guard tiene que aparecer exactamente una vez.
--   * `bot_mi_recorrido` (sólo el bot, sin EXECUTE para la app): lista las
--     paradas del recorrido del transportista con `p.total`, para cualquier
--     fecha. Los VB que él no cargó salen de la lista.

DO $parche$
DECLARE
  v_fn    CONSTANT regprocedure := 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure;
  v_viejo CONSTANT text := 'WHERE id = p_pedido_id AND transportista_id = v_usuario_id AND sucursal_id = v_sucursal';
  v_nuevo CONSTANT text := 'WHERE id = p_pedido_id AND transportista_id = v_usuario_id AND sucursal_id = v_sucursal'
    || E'\n         -- mig 332 (#1034): un vale blanco es costo; quien lo repartió no lo ve'
    || E'\n         -- ni le registra salvedades (mismo alcance que mt_pedidos_select).'
    || E'\n         AND tipo_factura IS DISTINCT FROM ''VB''';
  v_def   text := pg_get_functiondef(v_fn);
  v_veces int;
BEGIN
  v_veces := (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig 332 · el guard del transportista aparece % veces en registrar_salvedad (se esperaba 1): la función cambió, revisar el parche a mano', v_veces;
  END IF;
  EXECUTE replace(v_def, v_viejo, v_nuevo);
END
$parche$;

CREATE OR REPLACE FUNCTION public.bot_mi_recorrido(p_transportista_id uuid, p_sucursal_id bigint, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH r AS (
    SELECT
      id,
      fecha::text AS fecha,
      estado,
      total_pedidos,
      pedidos_entregados,
      total_facturado,
      total_cobrado
    FROM recorridos
    WHERE transportista_id = p_transportista_id
      AND fecha = p_fecha
      AND sucursal_id = p_sucursal_id
    ORDER BY id DESC
    LIMIT 1
  )
  SELECT json_build_object(
    'recorrido', COALESCE((SELECT row_to_json(r.*) FROM r), 'null'::json),
    'pedidos', COALESCE(
      (
        SELECT json_agg(
          json_build_object(
            'pedido_id',      rp.pedido_id,
            'orden_entrega',  rp.orden_entrega,
            'estado_entrega', rp.estado_entrega,
            'cliente_id',     p.cliente_id,
            'cliente_nombre', COALESCE(c.nombre_fantasia, c.razon_social, '(sin nombre)'),
            'direccion',      c.direccion,
            'total',          p.total,
            'estado_pago',    p.estado_pago
          )
          ORDER BY rp.orden_entrega ASC NULLS LAST, rp.id ASC
        )
        FROM recorrido_pedidos rp
        JOIN pedidos p ON p.id = rp.pedido_id
        LEFT JOIN clientes c ON c.id = p.cliente_id
        WHERE rp.recorrido_id = (SELECT id FROM r)
          -- mig 332 (#1034): el total de un VB es su costo. El que lo repartió
          -- no lo ve, salvo que lo haya cargado él (mt_pedidos_select).
          AND (p.tipo_factura IS DISTINCT FROM 'VB' OR p.usuario_id = p_transportista_id)
      ),
      '[]'::json
    )
  );
$function$;

-- ── #1049 · pedido_items no se escribe por REST ──────────────────────────────

REVOKE INSERT, UPDATE ON public.pedido_items FROM authenticated, anon;

-- ── #1014 · el encargado lee proveedores ─────────────────────────────────────

ALTER POLICY mt_proveedores_select ON public.proveedores
  USING (
    (es_encargado_o_admin()
     OR EXISTS (SELECT 1 FROM perfiles
                 WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
    AND sucursal_id = current_sucursal_id()
  );

-- ── Verificación ─────────────────────────────────────────────────────────────

DO $verif$
DECLARE
  v_problemas text;
  v_qual text;
BEGIN
  -- SEG-B en verde con el predicado nuevo: la policy, el helper y los dos
  -- inline dicen lo mismo.
  SELECT string_agg(problema, ' | ') INTO v_problemas FROM public.auditoria_predicado_pedidos();
  IF v_problemas IS NOT NULL THEN
    RAISE EXCEPTION '#1034 · SEG-B en rojo después de la migración: %', v_problemas;
  END IF;

  -- Y sigue mordiendo: la policy vieja (sin el filtro de VB) ya no pasa.
  IF NOT EXISTS (SELECT 1 FROM public.auditoria_predicado_pedidos(
       '((es_encargado_o_admin() OR (usuario_id = auth.uid()) OR (transportista_id = auth.uid())) AND (sucursal_id = current_sucursal_id()))', 1)) THEN
    RAISE EXCEPTION '#1034 · SEG-B no se entera si la policy vuelve a dejar ver los VB al transportista';
  END IF;

  SELECT qual INTO v_qual FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'pedido_items' AND policyname = 'mt_pedido_items_select';
  IF position('''VB''' IN v_qual) = 0 THEN
    RAISE EXCEPTION '#1034 · mt_pedido_items_select no filtra los VB: %', v_qual;
  END IF;

  SELECT qual INTO v_qual FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'pedido_historial' AND policyname = 'mt_pedido_historial_select';
  IF position('''VB''' IN v_qual) = 0 THEN
    RAISE EXCEPTION '#1034 · mt_pedido_historial_select no filtra los VB: %', v_qual;
  END IF;

  IF has_table_privilege('authenticated', 'public.pedido_items', 'INSERT')
     OR has_table_privilege('authenticated', 'public.pedido_items', 'UPDATE')
     OR has_table_privilege('anon', 'public.pedido_items', 'INSERT')
     OR has_table_privilege('anon', 'public.pedido_items', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.pedido_items', 'costo_unitario_al_crear', 'INSERT')
     OR has_column_privilege('authenticated', 'public.pedido_items', 'costo_unitario_al_crear', 'UPDATE') THEN
    RAISE EXCEPTION '#1049 · authenticated/anon siguen pudiendo escribir pedido_items';
  END IF;

  -- La lectura de pedido_items (mig 327) no se tocó.
  IF NOT has_column_privilege('authenticated', 'public.pedido_items', 'precio_unitario', 'SELECT')
     OR has_column_privilege('authenticated', 'public.pedido_items', 'costo_unitario_al_crear', 'SELECT') THEN
    RAISE EXCEPTION '#1049 · la lectura de pedido_items cambió sin querer';
  END IF;

  -- CREATE OR REPLACE conserva los GRANT: las dos de CI siguen sin EXECUTE para
  -- la app (314, #1020) y las tres que el front llama lo siguen teniendo.
  IF has_function_privilege('authenticated', 'public.puede_leer_pedido(bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.auditoria_predicado_pedidos(text,integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.obtener_resumen_cuenta_cliente(integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.deuda_previa(public.pedidos)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.obtener_resumen_cuenta_cliente(integer)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.deuda_previa(public.pedidos)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.deuda_previa_detalle(public.pedidos)', 'EXECUTE') THEN
    RAISE EXCEPTION '#1034 · cambiaron los EXECUTE de las funciones reescritas';
  END IF;

  IF position('AND sucursal_id = v_sucursal' || E'\n'
              || '         -- mig 332 (#1034): un vale blanco es costo; quien lo repartió no lo ve'
       IN pg_get_functiondef('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure)) = 0
     OR position('AND tipo_factura IS DISTINCT FROM ''VB'''
       IN pg_get_functiondef('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION '#1034 · registrar_salvedad no quedó con el filtro de VB en el guard del transportista';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.bot_mi_recorrido(uuid,bigint,date)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.bot_mi_recorrido(uuid,bigint,date)', 'EXECUTE') THEN
    RAISE EXCEPTION '#1034 · cambiaron los EXECUTE de registrar_salvedad o bot_mi_recorrido';
  END IF;

  SELECT qual INTO v_qual FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'proveedores' AND policyname = 'mt_proveedores_select';
  IF position('es_encargado_o_admin()' IN v_qual) = 0 OR position('current_sucursal_id()' IN v_qual) = 0 THEN
    RAISE EXCEPTION '#1014 · mt_proveedores_select no quedó con el encargado y la sucursal: %', v_qual;
  END IF;
END
$verif$;
