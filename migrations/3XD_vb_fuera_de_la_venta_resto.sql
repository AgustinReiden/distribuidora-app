-- ============================================================================
-- 3XD — el vale blanco (VB) sale de la venta: bot, jornadas, rendimiento,
--       alertas, ritmo de compra y resúmenes de cuenta
-- ============================================================================
-- El número real se pone al aplicar (Trampa 3 del CLAUDE.md): hoy la última en
-- prod es la 310 y otras sesiones tienen su propio 3XA/3XB/3XC.
--
-- QUÉ ES ESTO
-- -----------
-- El VB pasa de forma de pago a TIPO DE COMPROBANTE (`pedidos.tipo_factura`
-- = 'VB'): consumo interno hacia una empresa propia, a costo, nace entregado,
-- no es deuda y NO es venta. La definición de "venta por vendedor" (mig 241)
-- gana una cuarta pata:
--
--     estado = 'entregado' · canal <> 'cambio' · tipo_factura <> 'VB'
--     · por pedidos.fecha · atribuida a pedidos.usuario_id
--
-- Esta migración la aplica en el resto de las funciones de `public` que
-- contestan "cuánto se vendió" (o "cuándo compró", "qué lleva", "cuánto rindió")
-- y que NO son de las otras migraciones del paquete (reporte_gerencial,
-- posicion_fiscal, reporte_rentabilidad, calcular_comisiones,
-- reporte_ventas_por_preventista, obtener_estadisticas_pedidos,
-- avance_metas_preventista, reporte_ventas_por_cliente, auditoria_integridad).
--
-- Hoy no hay ningún VB (pedidos.tipo_factura = 'VB' → 0 filas) ni ningún cliente
-- con tipo_factura_default = 'VB', así que aplicar esto NO mueve ningún número:
-- recién se nota cuando la migración de backfill (3XC) convierta los 193
-- pedidos de vale blanco. Por eso puede ir antes que el front.
--
-- EL PREDICADO: `tipo_factura IS DISTINCT FROM 'VB'`
-- --------------------------------------------------
-- `pedidos.tipo_factura` es nullable (tiene default 'ZZ' pero no NOT NULL; hoy
-- 0 nulos en 6850 filas). Un `<> 'VB'` pelado sacaría también un NULL, que es
-- un comprobante común sin tipo, no un vale. `IS DISTINCT FROM` es el
-- equivalente null-safe de `COALESCE(tipo_factura, 'ZZ') <> 'VB'`. En cambio
-- `clientes.tipo_factura_default` SÍ es NOT NULL: ahí va el `<> 'VB'` común.
--
-- INVENTARIO: TODAS las funciones de `public` que filtran estado = 'entregado'
-- sobre `pedidos` (pg_get_functiondef ~* 'entregado', medido en prod el
-- 2026-10-08, 61 funciones), clasificadas. Se agregó además el barrido de las
-- que leen pedidos/pedido_items SIN decir 'entregado' (28 más).
-- ----------------------------------------------------------------------------
-- A) VENTA — las cubre ESTA migración (se reescriben abajo):
--      bot_digest_preventista            ("tomado": el VB no cuenta como pedido tomado)
--      bot_ficha_producto
--      bot_historico_pedidos_cliente     (sin 'entregado': pedidos no cancelados)
--      bot_metricas_admin_dia
--      bot_mis_clientes                  (sin 'entregado': última compra + N17)
--      bot_mis_ventas
--      bot_productos_dejados_cliente
--      bot_productos_recurrentes_cliente (sin 'entregado': qué lleva el cliente)
--      bot_productos_sin_venta_con_stock
--      bot_ranking_preventistas_por_producto
--      bot_resumen_cliente_visita        (sin 'entregado': último pedido)
--      bot_riesgo_por_preventista        (N17 le llega vía clientes_ritmo_compra)
--      bot_stock_y_ventas
--      bot_ventas_periodo
--      clientes_ritmo_compra             (N17: excluye clientes VB)
--      jornada_preventista_detalle
--      jornada_transportista_detalle
--      jornadas_preventista
--      jornadas_transportista
--      obtener_resumen_cuenta_cliente    (sin 'entregado': total_compras)
--      obtener_resumen_cuenta_cliente_bot
--      rendimiento_preventistas
--      reporte_alerta_detalle
-- B) VENTA — de OTRO agente/migración del paquete (NO se tocan acá):
--      auditoria_integridad, avance_metas_preventista, calcular_comisiones,
--      obtener_estadisticas_pedidos, posicion_fiscal, reporte_gerencial,
--      reporte_rentabilidad, reporte_ventas_por_cliente,
--      reporte_ventas_por_preventista
-- C) DELEGAN en una canónica (check BOT-B de auditoria_integridad): NO se
--    duplica el filtro inline, heredan el de B):
--      bot_ranking_clientes      → reporte_ventas_por_cliente
--      bot_ventas_por_preventista → reporte_ventas_por_preventista
--      bot_clientes_atrasados    → clientes_ritmo_compra + reporte_alerta_detalle
--                                  (N17 le llega por ahí; no se reescribe)
-- D) NO SON VENTA (miran el estado del pedido o la deuda, no cuánto se vendió);
--    no se tocan acá. Las que tocan el ciclo de vida del VB (crear, cancelar,
--    convertir, rendir, marcar entregas, salvedades, notas de crédito) son del
--    paquete de lógica (3XA) y de rendiciones:
--      Ciclo de vida / ruta / stock:
--        actualizar_pedido_items, actualizar_recorrido_entrega, anular_salvedad,
--        aplicar_cambio_de_parada, aplicar_orden_ruta, cambiar_cliente_pedido,
--        cambiar_tipo_factura_pedido, cambiar_transportista_recorrido,
--        cancelar_pedido_con_stock, crear_nota_credito_venta_impl,
--        crear_pedido_cambio_en_ruta, crear_pedido_completo,
--        dividir_regalo_pedido, hojas_de_ruta_deposito,
--        marcar_entrega_y_pago_masivo_impl, marcar_entregas_masivo,
--        marcar_no_entregado, recalcular_recorrido, sustituir_regalo_pedido,
--        bot_mi_recorrido, bot_recorrido_resumen
--      Triggers de guarda: pedido_items_guard_estado, pedidos_proteger_columnas,
--        productos_rechazar_borrado_con_historial, validar_cambio_unidades_por_bulto
--      Rendiciones: crear_rendicion_por_fecha, crear_rendicion_recorrido,
--        obtener_detalle_rendicion, obtener_resumen_rendiciones,
--        obtener_pagos_rendicion_cliente, obtener_pedidos_ctacte_pendientes
--      Deuda / cobranza (un VB nunca debe: total - monto_pagado = 0 por
--        construcción, §3.2 del diseño): obtener_deudores_mora,
--        reporte_cuentas_por_cobrar (todas sus ramas miran saldo > 0),
--        deuda_previa, deuda_previa_detalle, bot_pendientes_pago,
--        aplicar_credito_cliente, desafectar_sobrepago_pedido,
--        imputar_credito_a_pedido_impl, marcar_pagos_masivo_impl,
--        registrar_pago_*_impl
--      Actividad, no venta: obtener_geolocalizacion_preventistas (dónde estaba
--        el preventista al cargar; un VB cargado cuenta como actividad real),
--        registrar_geolocalizacion_pedido, pedido_bundle_para_promo (sólo
--        pedidos con promo; un VB no lleva)
--      Otros: _consumir_lotes_fefo, _restaurar_lotes_fefo, bot_buscar_cliente
--        (selector operativo: un cliente VB tiene que poder buscarse para
--        cargarle el vale), cerrar_recorridos_vencidos, crear_recorrido,
--        crear_pedido_idempotente, eliminar_pedido_completo,
--        actualizar_preventista_pedido, registrar_origen_precio_items,
--        registrar_salvedad, simular_salvedad(es)_promo_impacto,
--        verificar_duplicado_cliente
-- Ninguna de venta quedó sin dueño: no hay una "E" que cubrir.
--
-- QUÉ NO SE TOCA A PROPÓSITO
--   · `bot_ventas_periodo.en_curso`: cuenta 'asignado'/'pendiente'; un VB nace
--     entregado y nunca pasa por ahí.
--   · `bot_metricas_admin_dia.pendientes_*`, `cxc_vencido`: son deuda/entrega
--     pendiente; un VB nunca está pendiente ni debe.
--   · `jornadas_*.pendientes`: se filtra igual por consistencia (ver abajo),
--     aunque un VB nunca esté pendiente.
--   · El canal faltante en `obtener_resumen_cuenta_cliente(_bot)`,
--     `bot_historico_pedidos_cliente`, `bot_productos_recurrentes_cliente` y
--     `bot_resumen_cliente_visita` (no miran `canal <> 'cambio'`) es otro bug,
--     fuera de este alcance: va a un issue. Acá sólo se agrega el filtro VB.
--
-- REGLAS DE ESCRITURA
-- -------------------
-- Cada función es copia LITERAL de pg_get_functiondef de prod (2026-10-08) más
-- el cambio mínimo; no se "mejora" nada más. CREATE OR REPLACE conserva dueño,
-- SECURITY DEFINER, search_path y los GRANT/REVOKE vigentes; no se toca ninguno
-- (el DO final lo verifica: ninguna queda alcanzable por PUBLIC ni anon).
-- Ninguna cambia de firma ni de RETURNS: no hay DROP.
--
-- ORDEN: 3XA → 3XB y 3XD (entre sí en cualquier orden: ninguna toca una
-- función de la otra ni de la 3XA) → front → 3XC.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 0 · Premisas: nada cambió en prod desde que se copiaron las definiciones.
--     Un CREATE OR REPLACE sobre un cuerpo que otra sesión cambió después
--     revertiría ese cambio en silencio (molde de la 3XB). md5(prosrc) del
--     cuerpo copiado el 2026-10-08; el ensayo final sólo mira la forma.
-- ----------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.bot_digest_preventista(uuid,bigint,date)',                                   'b403416bafb4146c5eff7de7daa7c461'),
        ('public.bot_ficha_producto(bigint,bigint)',                                          '30ba048ba738aee56a155a3bd4d1ec85'),
        ('public.bot_historico_pedidos_cliente(bigint,uuid,text,bigint,integer,integer)',     'b55161385d57e6e01edced02e369d8d1'),
        ('public.bot_metricas_admin_dia(date,bigint)',                                        'fcfa28972de2cc9cfa60c793427d9244'),
        ('public.bot_mis_clientes(uuid,bigint,boolean,integer,integer)',                      'cd1deca5d0f31f9b98330c738e6083b2'),
        ('public.bot_mis_ventas(uuid,date,date,bigint,integer)',                              'a4ba12a6d80aa7f107e03aff95dfde90'),
        ('public.bot_productos_dejados_cliente(bigint,uuid,text,bigint)',                     'cfb386eed8386f72b4f7c14222aa0b34'),
        ('public.bot_productos_recurrentes_cliente(bigint,uuid,text,bigint,integer,integer)', '0d4723c19448c6f39bccd081610d0bf4'),
        ('public.bot_productos_sin_venta_con_stock(bigint,integer,integer)',                  'fec7561dbab8d57f73e4e759466e194a'),
        ('public.bot_ranking_preventistas_por_producto(bigint[],date,date,bigint,integer)',   'c25d25432365b5b0cda4b37e512aa8a5'),
        ('public.bot_resumen_cliente_visita(bigint,uuid,text,bigint)',                        '7f5e4f5cd3bec9de5210dd1a88ed7608'),
        ('public.bot_riesgo_por_preventista(bigint)',                                         'c609a9a46beeffc719ce87625c3e08d6'),
        ('public.bot_stock_y_ventas(bigint,text,text,text,text,integer)',                     '7a25f37843302ded68b964e840e2a145'),
        ('public.bot_ventas_periodo(date,date,bigint,integer)',                               '4b400e99a83b51f863789466f40592a2'),
        ('public.clientes_ritmo_compra(bigint,text,uuid,uuid,bigint)',                        '4ddbaf4de62729ba1c98feef52ba3d82'),
        ('public.jornada_preventista_detalle(date,uuid)',                                     '0f267ad361828b5a89fc2862394aef1f'),
        ('public.jornada_transportista_detalle(date,uuid)',                                   '9921a31c8482ce53f36b3fbf695281d0'),
        ('public.jornadas_preventista(date,date,uuid)',                                       'f8cc05459c90260dc8b18f30b172f763'),
        ('public.jornadas_transportista(date,date,uuid)',                                     '994d2e4e9d30877a4aab2ad549728d9f'),
        ('public.obtener_resumen_cuenta_cliente(integer)',                                    '3d38ef86d01568cd25696f9c19d6c2a2'),
        ('public.obtener_resumen_cuenta_cliente_bot(integer)',                                'b483cfa7700953a38713b15fa1aec361'),
        ('public.rendimiento_preventistas(bigint,date)',                                      '431af925bff0d6470cd71d36d20ccfa8'),
        ('public.reporte_alerta_detalle(bigint,text,date,date,boolean)',                      '4462325712570694e1b98f014b71491e')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION '3XD · % cambió en prod desde que se copió (md5 %, esperado %): rehacer la copia sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;


-- ----------------------------------------------------------------------------
-- bot_digest_preventista — "lo de ayer" son los pedidos TOMADOS; un VB no es un
-- pedido que el preventista salió a tomar.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_digest_preventista(p_perfil_id uuid, p_sucursal_id bigint, p_fecha date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_inicio_mes DATE := date_trunc('month', p_fecha)::date;
  v_dia        json;
  v_mes        json;
  v_atrasados  json;
BEGIN
  IF p_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'bot_digest_preventista: sucursal requerida';
  END IF;
  -- Falla cerrado: el resumen de cartera es de un preventista activo, nadie más.
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = p_perfil_id AND rol = 'preventista' AND activo) THEN
    RAISE EXCEPTION 'bot_digest_preventista: % no es un preventista activo', p_perfil_id;
  END IF;
  -- Y de ESTA sucursal hoy: bot_usuarios.sucursal_id es una foto que puede
  -- quedar vieja si lo pasan a otra.
  IF NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = p_perfil_id AND sucursal_id = p_sucursal_id) THEN
    RAISE EXCEPTION 'bot_digest_preventista: % no pertenece a la sucursal %', p_perfil_id, p_sucursal_id;
  END IF;

  -- Lo de AYER son los pedidos que TOMÓ, no venta: la venta se reconoce con la
  -- entrega (241) y en prod el 72 % se entrega al dia siguiente (medido el
  -- 2026-10-08: de 45 pedidos del 7/10, 1 entregado a la mañana). Contado como
  -- venta, el resumen diria "ayer no vendiste" casi todos los dias.
  -- Un vale blanco (consumo interno) no es un pedido tomado: fuera (3XD).
  SELECT json_build_object('pedidos', COUNT(*), 'total', COALESCE(SUM(total), 0))
    INTO v_dia
    FROM pedidos
   WHERE usuario_id = p_perfil_id AND sucursal_id = p_sucursal_id
     AND fecha = p_fecha AND estado <> 'cancelado' AND canal <> 'cambio'
     AND tipo_factura IS DISTINCT FROM 'VB';
  -- Lo del mes si es venta, con la definicion de la 241.
  v_mes := bot_mis_ventas(p_perfil_id, v_inicio_mes, p_fecha, p_sucursal_id, 0);
  v_atrasados := bot_clientes_atrasados(p_sucursal_id, 'preventista', p_perfil_id, NULL, false, false, 5);

  RETURN json_build_object(
    'fecha', p_fecha,
    'mis_ventas', json_build_object(
      'dia_tomados_pedidos', (v_dia ->> 'pedidos')::int,
      'dia_tomados_total',   (v_dia ->> 'total')::numeric,
      'mes_desde',   v_inicio_mes,
      'mes_total',   (v_mes ->> 'total_ventas')::numeric,
      'mes_pedidos', (v_mes ->> 'pedidos_count')::int,
      'mes_clientes', (v_mes ->> 'clientes_distintos')::int
    ),
    'mis_atrasados', json_build_object(
      'clientes_en_cartera',     (v_atrasados ->> 'clientes_en_cartera')::int,
      'atrasados',               (v_atrasados ->> 'atrasados')::int,
      'monto_mensual_en_riesgo', (v_atrasados ->> 'monto_mensual_en_riesgo')::numeric,
      'clientes',                v_atrasados -> 'clientes'
    )
  );
END;
$function$;


-- ----------------------------------------------------------------------------
-- bot_ficha_producto — unidades entregadas (venta) de un producto.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_ficha_producto(p_producto_id bigint, p_sucursal_id bigint)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
  -- Ultimos 30 dias = hoy y los 29 anteriores.
  v_desde   DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 29;
BEGIN
  WITH ventas AS (
    SELECT pi.cantidad, COALESCE(pi.es_bonificacion, false) AS regalo, pe.fecha
      FROM pedido_items pi
      JOIN pedidos pe ON pe.id = pi.pedido_id
     WHERE pi.producto_id = p_producto_id
       AND pe.sucursal_id = p_sucursal_id
       AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
       AND pe.tipo_factura IS DISTINCT FROM 'VB'
  )
  SELECT json_build_object(
    'producto', json_build_object(
      'id', p.id,
      'codigo', p.codigo,
      'nombre', p.nombre,
      'precio', p.precio,
      'precio_sin_iva', p.precio_sin_iva,
      'stock', p.stock,
      'stock_minimo', p.stock_minimo,
      'categoria', p.categoria,
      'proveedor_id', p.proveedor_id
    ),
    'ventas_30d_cantidad',
      (SELECT COALESCE(SUM(cantidad), 0)::INTEGER FROM ventas WHERE NOT regalo AND fecha >= v_desde),
    'regaladas_30d_cantidad',
      (SELECT COALESCE(SUM(cantidad), 0)::INTEGER FROM ventas WHERE regalo AND fecha >= v_desde),
    'ultima_venta', (SELECT MAX(fecha) FROM ventas WHERE NOT regalo),
    'criterio', 'Unidades entregadas (venta), ultimos 30 dias por fecha del pedido. Las regaladas van aparte.'
  ) INTO resultado
  FROM productos p
  WHERE p.id = p_producto_id
    AND p.sucursal_id = p_sucursal_id;
  RETURN resultado;
END;
$function$;


-- ----------------------------------------------------------------------------
-- bot_historico_pedidos_cliente — pedidos no cancelados del cliente. Sólo el
-- filtro VB (el canal faltante es otro bug → issue).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_historico_pedidos_cliente(p_cliente_id bigint, p_perfil_id uuid, p_rol text, p_sucursal_id bigint, p_dias integer DEFAULT 90, p_limit integer DEFAULT 20)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
  -- mt_pedidos_select: admin y encargado ven todos los pedidos de la sucursal;
  -- cualquier otro rol, solo los que cargo o reparte (296).
  v_ve_todo BOOLEAN := p_rol IN ('admin', 'encargado');
  -- Ultimos N dias = hoy y los N-1 anteriores.
  v_desde   DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - (p_dias - 1);
BEGIN
  IF p_rol = 'preventista' THEN
    IF NOT (
      EXISTS(SELECT 1 FROM cliente_preventistas
             WHERE cliente_id = p_cliente_id AND preventista_id = p_perfil_id)
      OR NOT EXISTS(SELECT 1 FROM cliente_preventistas
                    WHERE cliente_id = p_cliente_id)
    ) THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'pedidos_count', 0,
        'pedidos', '[]'::JSON, 'error', 'Cliente asignado a otro preventista');
    END IF;

    -- Reservado a administracion (mig 214). El historial propio SI se ve: es la
    -- excepcion que evita que sus pedidos viejos queden sin cliente.
    IF EXISTS(SELECT 1 FROM clientes c WHERE c.id = p_cliente_id AND c.reservado_admin)
       AND NOT EXISTS(SELECT 1 FROM pedidos pe
                      WHERE pe.cliente_id = p_cliente_id AND pe.usuario_id = p_perfil_id)
    THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'pedidos_count', 0,
        'pedidos', '[]'::JSON, 'error', 'Cliente reservado a administración');
    END IF;
  END IF;

  WITH ventana AS (
    SELECT id, fecha, total, estado, estado_pago, created_at
    FROM pedidos
    WHERE cliente_id = p_cliente_id AND sucursal_id = p_sucursal_id
      AND fecha >= v_desde
      AND COALESCE(estado, '') <> 'cancelado'
      AND tipo_factura IS DISTINCT FROM 'VB'
      AND (v_ve_todo OR usuario_id = p_perfil_id OR transportista_id = p_perfil_id)
  ),
  ultimos_pedidos AS (
    SELECT * FROM ventana ORDER BY fecha DESC, created_at DESC LIMIT p_limit
  ),
  pedidos_con_items AS (
    SELECT up.id, up.fecha, up.total, up.estado, up.estado_pago, up.created_at,
      (SELECT json_agg(json_build_object('producto_id', p.id, 'codigo', p.codigo,
        'nombre', p.nombre, 'cantidad', pi.cantidad, 'subtotal', pi.subtotal)
        ORDER BY pi.subtotal DESC)
       FROM pedido_items pi JOIN productos p ON p.id = pi.producto_id
       WHERE pi.pedido_id = up.id) AS items
    FROM ultimos_pedidos up
  )
  SELECT json_build_object(
    'cliente_id', p_cliente_id,
    'pedidos_count', (SELECT COUNT(*) FROM ventana),
    'pedidos_mostrados', (SELECT COUNT(*) FROM pedidos_con_items),
    'rango_dias', p_dias,
    'desde', v_desde,
    'total_periodo', (SELECT COALESCE(SUM(total), 0) FROM ventana),
    'criterio', 'Pedidos no cancelados (tomados y entregados), por fecha del pedido.',
    'alcance', CASE WHEN v_ve_todo THEN 'todos' ELSE 'propios' END,
    'pedidos', COALESCE(
      (SELECT json_agg(row_to_json(p.*) ORDER BY p.fecha DESC, p.created_at DESC) FROM pedidos_con_items p),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$function$;


-- ----------------------------------------------------------------------------
-- bot_metricas_admin_dia — ventas del día, promedio de 7 días y entregado del
-- día. Los tres CTE de pedidos (dia, 7d, entregado) sin VB; las pendientes de
-- entrega/pago no (un VB nunca está pendiente ni debe).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_metricas_admin_dia(p_fecha date, p_sucursal_id bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH
  pedidos_dia AS (
    SELECT id, total, cliente_id, sucursal_id
    FROM pedidos
    WHERE fecha = p_fecha
      AND estado <> 'cancelado'
      AND tipo_factura IS DISTINCT FROM 'VB'
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  pedidos_7d AS (
    SELECT total
    FROM pedidos
    WHERE fecha >= p_fecha - INTERVAL '7 days'
      AND fecha <  p_fecha
      AND estado <> 'cancelado'
      AND tipo_factura IS DISTINCT FROM 'VB'
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  ventas_dia AS (
    SELECT
      COUNT(*)                                                   AS pedidos,
      COALESCE(SUM(total), 0)::numeric(14,2)                     AS total,
      CASE
        WHEN COUNT(*) > 0 THEN (COALESCE(SUM(total), 0) / COUNT(*))::numeric(14,2)
        ELSE 0::numeric(14,2)
      END                                                        AS ticket_promedio
    FROM pedidos_dia
  ),
  entregado_dia AS (
    SELECT
      COUNT(*)                                                   AS pedidos,
      COALESCE(SUM(total), 0)::numeric(14,2)                     AS total
    FROM pedidos
    WHERE fecha = p_fecha
      AND estado = 'entregado' AND canal <> 'cambio'
      AND tipo_factura IS DISTINCT FROM 'VB'
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  promedio_7d AS (
    SELECT
      ROUND(COUNT(*) / 7.0, 2)                                   AS pedidos_dia_avg,
      ROUND(COALESCE(SUM(total), 0) / 7.0, 2)                    AS total_dia_avg
    FROM pedidos_7d
  ),
  top_clientes AS (
    SELECT
      pd.cliente_id,
      COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, '(sin nombre)') AS nombre,
      COALESCE(c.es_comodin, false)                              AS es_comodin,
      COUNT(*)                                                   AS pedidos,
      SUM(pd.total)::numeric(14,2)                               AS total
    FROM pedidos_dia pd
    LEFT JOIN clientes c ON c.id = pd.cliente_id
    GROUP BY pd.cliente_id, c.nombre_fantasia, c.razon_social, c.es_comodin
    ORDER BY SUM(pd.total) DESC
    LIMIT 5
  ),
  top_productos AS (
    SELECT
      pi.producto_id,
      pr.nombre,
      pr.codigo,
      SUM(pi.cantidad)::int                                      AS cantidad,
      SUM(pi.cantidad * pi.precio_unitario)::numeric(14,2)       AS monto
    FROM pedido_items pi
    JOIN pedidos_dia  pd ON pd.id = pi.pedido_id
    LEFT JOIN productos pr ON pr.id = pi.producto_id
    GROUP BY pi.producto_id, pr.nombre, pr.codigo
    ORDER BY SUM(pi.cantidad) DESC
    LIMIT 5
  ),
  pendientes_entrega AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COALESCE(SUM(total), 0)::numeric(14,2)                     AS monto
    FROM pedidos
    WHERE estado IN ('pendiente', 'en_preparacion', 'asignado', 'en_reparto')
      AND fecha >= p_fecha - INTERVAL '14 days'
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  pendientes_pago AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COALESCE(SUM(total - COALESCE(monto_pagado, 0)), 0)::numeric(14,2) AS saldo
    FROM pedidos
    WHERE estado_pago IN ('pendiente', 'parcial')
      AND estado <> 'cancelado'
      AND total > COALESCE(monto_pagado, 0)
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  stock_critico_base AS (
    SELECT
      id, codigo, nombre, stock, stock_minimo,
      ROW_NUMBER() OVER (
        ORDER BY (COALESCE(stock_minimo, 10) - COALESCE(stock, 0)) DESC, id ASC
      ) AS rn
    FROM productos
    WHERE COALESCE(stock, 0) <= COALESCE(stock_minimo, 10)
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  stock_critico AS (
    SELECT
      (SELECT COUNT(*) FROM stock_critico_base)::int AS count,
      COALESCE(
        (SELECT json_agg(
          json_build_object(
            'id',           s.id,
            'codigo',       s.codigo,
            'nombre',       s.nombre,
            'stock',        s.stock,
            'stock_minimo', s.stock_minimo
          )
          ORDER BY s.rn
        )
        FROM stock_critico_base s
        WHERE s.rn <= 5),
        '[]'::json
      ) AS top
  ),
  cxc AS (
    SELECT
      COUNT(*) FILTER (WHERE saldo_cuenta > 0)::int              AS clientes_con_saldo,
      COALESCE(SUM(saldo_cuenta) FILTER (WHERE saldo_cuenta > 0), 0)::numeric(14,2) AS deuda_total
    FROM clientes
    WHERE activo = TRUE
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  cxc_vencido AS (
    SELECT
      COUNT(*)::int                                              AS pedidos_vencidos,
      COALESCE(SUM(p.total - COALESCE(p.monto_pagado, 0)), 0)::numeric(14,2) AS monto_vencido
    FROM pedidos p
    JOIN clientes c ON c.id = p.cliente_id
    WHERE p.estado <> 'cancelado'
      AND p.estado_pago IN ('pendiente', 'parcial')
      AND p.total > COALESCE(p.monto_pagado, 0)
      AND p.fecha + (COALESCE(c.dias_credito, 30) || ' days')::interval < CURRENT_DATE
      AND (p_sucursal_id IS NULL OR p.sucursal_id = p_sucursal_id)
  ),
  rendiciones_pendientes AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COALESCE(MAX(CURRENT_DATE - r.fecha), 0)::int              AS dias_mas_vieja
    FROM rendiciones r
    LEFT JOIN rendiciones_control rc
      ON  rc.fecha = r.fecha
      AND rc.transportista_id = r.transportista_id
      AND rc.sucursal_id = r.sucursal_id
    WHERE rc.id IS NULL
      AND r.fecha < CURRENT_DATE - INTERVAL '2 days'
      AND (p_sucursal_id IS NULL OR r.sucursal_id = p_sucursal_id)
  ),
  recorridos_hoy AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COUNT(*) FILTER (WHERE estado = 'en_curso')::int           AS en_curso,
      COALESCE(SUM(total_pedidos), 0)::int                       AS total_paradas
    FROM recorridos
    WHERE fecha = CURRENT_DATE
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  )
  SELECT json_build_object(
    'fecha',                  p_fecha,
    'sucursal_id',            p_sucursal_id,
    'ventas_dia',             (SELECT row_to_json(v) FROM ventas_dia v),
    'entregado_dia',          (SELECT row_to_json(e) FROM entregado_dia e),
    'promedio_7d',            (SELECT row_to_json(p) FROM promedio_7d p),
    'delta_pct',
      CASE
        WHEN (SELECT total_dia_avg FROM promedio_7d) > 0 THEN
          ROUND(
            (((SELECT total FROM ventas_dia) - (SELECT total_dia_avg FROM promedio_7d))
             / (SELECT total_dia_avg FROM promedio_7d) * 100)::numeric, 1
          )
        ELSE NULL
      END,
    'top_clientes',           COALESCE((SELECT json_agg(row_to_json(t)) FROM top_clientes t), '[]'::json),
    'top_productos',          COALESCE((SELECT json_agg(row_to_json(t)) FROM top_productos t), '[]'::json),
    'pendientes_entrega',     (SELECT row_to_json(x) FROM pendientes_entrega x),
    'pendientes_pago',        (SELECT row_to_json(x) FROM pendientes_pago x),
    'stock_critico',          (SELECT row_to_json(x) FROM stock_critico x),
    'cuentas_por_cobrar',     (SELECT row_to_json(x) FROM cxc x),
    'cxc_vencido',            (SELECT row_to_json(x) FROM cxc_vencido x),
    'rendiciones_pendientes', (SELECT row_to_json(x) FROM rendiciones_pendientes x),
    'recorridos_hoy',         (SELECT row_to_json(x) FROM recorridos_hoy x)
  );
$function$;


-- ----------------------------------------------------------------------------
-- bot_mis_clientes — N17: un cliente VB (consumo interno) no es cartera de
-- nadie: sin "ventas" aparecería como cliente que dejó de comprar. Y la última
-- compra no cuenta un vale (si el cliente se des-VB-ea después, su historia de
-- vales no es compra).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_mis_clientes(p_preventista_id uuid, p_sucursal_id bigint, p_con_deuda boolean DEFAULT false, p_sin_pedidos_dias integer DEFAULT NULL::integer, p_limit integer DEFAULT 20)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH base AS (
    SELECT
      c.id,
      c.codigo,
      c.nombre_fantasia,
      c.razon_social,
      c.saldo_cuenta,
      c.zona,
      (
        SELECT MAX(p.fecha)
        FROM pedidos p
        WHERE p.cliente_id = c.id
          AND p.estado <> 'cancelado'
          AND p.canal <> 'cambio' -- 300: la comanda de un canje no es una compra
          AND p.tipo_factura IS DISTINCT FROM 'VB' -- 3XD: el vale blanco no es una compra
      ) AS ultima_compra
    FROM clientes c
    JOIN cliente_preventistas cp ON cp.cliente_id = c.id
    WHERE cp.preventista_id = p_preventista_id
      AND c.sucursal_id = p_sucursal_id
      AND c.activo = TRUE
      AND c.tipo_factura_default <> 'VB' -- 3XD (N17): consumo interno, no es cartera
      AND (NOT p_con_deuda OR c.saldo_cuenta > 0)
  ),
  filtrado AS (
    SELECT
      b.*,
      CASE
        WHEN b.ultima_compra IS NULL THEN NULL
        ELSE (CURRENT_DATE - b.ultima_compra::date)
      END AS dias_desde_ultima
    FROM base b
    WHERE p_sin_pedidos_dias IS NULL
       OR b.ultima_compra IS NULL
       OR (CURRENT_DATE - b.ultima_compra::date) >= p_sin_pedidos_dias
  ),
  paged AS (
    SELECT *
    FROM filtrado
    ORDER BY nombre_fantasia ASC NULLS LAST, id ASC
    LIMIT p_limit
  )
  SELECT json_build_object(
    'total', (SELECT COUNT(*) FROM filtrado),
    'clientes', COALESCE(
      (SELECT json_agg(row_to_json(p)) FROM paged p),
      '[]'::json
    )
  );
$function$;


-- ----------------------------------------------------------------------------
-- bot_mis_ventas — "cuánto vendió Fulano": la definición canónica (241 + VB).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_mis_ventas(p_preventista_id uuid, p_desde date, p_hasta date, p_sucursal_id bigint, p_limit integer DEFAULT 10)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE resultado JSON;
BEGIN
  WITH ventas_filtradas AS (
    SELECT p.id, p.cliente_id, p.total
    FROM pedidos p
    WHERE p.sucursal_id = p_sucursal_id
      AND p.usuario_id  = p_preventista_id
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND p.estado = 'entregado' AND p.canal <> 'cambio'
      AND p.tipo_factura IS DISTINCT FROM 'VB'
  ),
  top_clientes AS (
    SELECT c.id AS cliente_id, c.codigo AS cliente_codigo,
      c.nombre_fantasia, c.razon_social, c.es_comodin,
      SUM(v.total) AS total_comprado, COUNT(*) AS pedidos
    FROM ventas_filtradas v JOIN clientes c ON c.id = v.cliente_id
    GROUP BY c.id, c.codigo, c.nombre_fantasia, c.razon_social, c.es_comodin
    ORDER BY SUM(v.total) DESC LIMIT p_limit
  )
  SELECT json_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'preventista_id', p_preventista_id,
    'total_ventas', (SELECT COALESCE(SUM(total), 0) FROM ventas_filtradas),
    'pedidos_count', (SELECT COUNT(*) FROM ventas_filtradas),
    'ticket_promedio', (SELECT CASE WHEN COUNT(*) > 0 THEN ROUND(AVG(total), 2) ELSE 0 END FROM ventas_filtradas),
    'clientes_distintos', (SELECT COUNT(DISTINCT cliente_id) FROM ventas_filtradas),
    'top_clientes', COALESCE((SELECT json_agg(row_to_json(tc.*)) FROM top_clientes tc), '[]'::JSON)
  ) INTO resultado;
  RETURN resultado;
END;
$function$;


-- ----------------------------------------------------------------------------
-- bot_productos_dejados_cliente — qué dejó de llevar un cliente: entregas de
-- venta (el contador de "al menos 6 entregas" y las últimas 10).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_productos_dejados_cliente(p_cliente_id bigint, p_perfil_id uuid, p_rol text, p_sucursal_id bigint)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entregas INT;
BEGIN
  IF p_rol = 'preventista' THEN
    IF NOT (
      EXISTS(SELECT 1 FROM cliente_preventistas
             WHERE cliente_id = p_cliente_id AND preventista_id = p_perfil_id)
      OR NOT EXISTS(SELECT 1 FROM cliente_preventistas WHERE cliente_id = p_cliente_id)
    ) THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'productos', '[]'::json,
        'error', 'Cliente asignado a otro preventista');
    END IF;
    IF EXISTS(SELECT 1 FROM clientes c WHERE c.id = p_cliente_id AND c.reservado_admin)
       AND NOT EXISTS(SELECT 1 FROM pedidos pe
                      WHERE pe.cliente_id = p_cliente_id AND pe.usuario_id = p_perfil_id)
    THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'productos', '[]'::json,
        'error', 'Cliente reservado a administración');
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_entregas
    FROM pedidos
   WHERE cliente_id = p_cliente_id AND sucursal_id = p_sucursal_id
     AND estado = 'entregado' AND canal <> 'cambio'
     AND tipo_factura IS DISTINCT FROM 'VB';

  IF v_entregas < 6 THEN
    RETURN json_build_object('cliente_id', p_cliente_id, 'entregas', v_entregas,
      'productos', '[]'::json,
      'nota', 'Historial corto: hacen falta al menos 6 entregas para saber que dejo de llevar.');
  END IF;

  RETURN (
    WITH ult AS (
      SELECT id, fecha, row_number() OVER (ORDER BY fecha DESC, id DESC) AS n
        FROM pedidos
       WHERE cliente_id = p_cliente_id AND sucursal_id = p_sucursal_id
         AND estado = 'entregado' AND canal <> 'cambio'
         AND tipo_factura IS DISTINCT FROM 'VB'
       ORDER BY fecha DESC, id DESC
       LIMIT 10
    ),
    items AS (
      SELECT DISTINCT u.n, u.fecha, pi.producto_id
        FROM ult u JOIN pedido_items pi ON pi.pedido_id = u.id
       WHERE NOT COALESCE(pi.es_bonificacion, false)
    ),
    cuenta AS (
      SELECT producto_id,
             COUNT(*) FILTER (WHERE n > 3) AS veces_antes,
             COUNT(*) FILTER (WHERE n <= 3) AS veces_ultimas,
             MAX(fecha) AS ultima_vez
        FROM items GROUP BY producto_id
    ),
    base AS (SELECT COUNT(*) FILTER (WHERE n > 3) AS antes FROM ult)
    SELECT json_build_object(
      'cliente_id', p_cliente_id,
      'entregas', v_entregas,
      'criterio', 'Habitual: estuvo en al menos la mitad de las entregas 4 a 10 (contando desde la ultima). Dejado: no aparece en las ultimas 3.',
      'productos', COALESCE((
        SELECT json_agg(json_build_object(
                 'producto_id', p.id, 'codigo', p.codigo, 'nombre', p.nombre,
                 'veces_en_entregas_anteriores', c.veces_antes,
                 'entregas_anteriores', b.antes,
                 'ultima_vez', c.ultima_vez,
                 'activo', p.activo)
               ORDER BY c.veces_antes DESC, p.nombre)
          FROM cuenta c CROSS JOIN base b JOIN productos p ON p.id = c.producto_id
         WHERE c.veces_ultimas = 0 AND c.veces_antes * 2 >= b.antes AND p.activo
      ), '[]'::json)
    )
  );
END;
$function$;


-- ----------------------------------------------------------------------------
-- bot_productos_recurrentes_cliente — qué lleva el cliente. Sólo el filtro VB
-- (el canal faltante es otro bug → issue).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_productos_recurrentes_cliente(p_cliente_id bigint, p_perfil_id uuid, p_rol text, p_sucursal_id bigint, p_dias integer DEFAULT 90, p_limit integer DEFAULT 10)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
  -- Hechos si, montos no (296): cuantas veces el cliente llevo el producto sale
  -- de todos sus pedidos; unidades y facturado, solo de los que el ve en la app.
  v_ve_todo BOOLEAN := p_rol IN ('admin', 'encargado');
BEGIN
  IF p_rol = 'preventista' THEN
    IF NOT (
      EXISTS(SELECT 1 FROM cliente_preventistas
             WHERE cliente_id = p_cliente_id AND preventista_id = p_perfil_id)
      OR NOT EXISTS(SELECT 1 FROM cliente_preventistas
                    WHERE cliente_id = p_cliente_id)
    ) THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'productos', '[]'::JSON,
        'error', 'Cliente asignado a otro preventista');
    END IF;

    -- Reservado a administracion (mig 214), con la misma excepcion de historial.
    IF EXISTS(SELECT 1 FROM clientes c WHERE c.id = p_cliente_id AND c.reservado_admin)
       AND NOT EXISTS(SELECT 1 FROM pedidos pe
                      WHERE pe.cliente_id = p_cliente_id AND pe.usuario_id = p_perfil_id)
    THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'productos', '[]'::JSON,
        'error', 'Cliente reservado a administración');
    END IF;
  END IF;

  WITH items_periodo AS (
    SELECT pi.producto_id, pi.cantidad, pi.subtotal, pe.id AS pedido_id,
      (v_ve_todo OR pe.usuario_id = p_perfil_id OR pe.transportista_id = p_perfil_id) AS visible
    FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
    WHERE pe.cliente_id = p_cliente_id AND pe.sucursal_id = p_sucursal_id
      AND pe.created_at > now() - (p_dias || ' days')::INTERVAL
      AND COALESCE(pe.estado, '') NOT IN ('cancelado', 'anulado')
      AND pe.tipo_factura IS DISTINCT FROM 'VB'
  ),
  ranked AS (
    SELECT p.id, p.codigo, p.nombre, p.precio,
      COUNT(DISTINCT ip.pedido_id) AS pedidos_con_producto,
      COALESCE(SUM(ip.cantidad) FILTER (WHERE ip.visible), 0) AS unidades_totales,
      COALESCE(SUM(ip.subtotal) FILTER (WHERE ip.visible), 0) AS facturado_total
    FROM items_periodo ip JOIN productos p ON p.id = ip.producto_id
    WHERE p.activo -- mig 284: un inactivo no se sugiere para volver a vender
    GROUP BY p.id, p.codigo, p.nombre, p.precio
    -- El desempate va por las unidades visibles: ordenar por las de todos
    -- dejaria inferir el volumen ajeno por el orden de la lista.
    ORDER BY COUNT(DISTINCT ip.pedido_id) DESC,
             COALESCE(SUM(ip.cantidad) FILTER (WHERE ip.visible), 0) DESC
    LIMIT p_limit
  )
  SELECT json_build_object(
    'cliente_id', p_cliente_id, 'rango_dias', p_dias,
    'montos', CASE WHEN v_ve_todo THEN 'todos' ELSE 'propios' END,
    'productos', COALESCE((SELECT json_agg(row_to_json(r.*)) FROM ranked r), '[]'::JSON)
  ) INTO resultado;
  RETURN resultado;
END;
$function$;


-- ----------------------------------------------------------------------------
-- bot_productos_sin_venta_con_stock — sin ninguna unidad entregada (venta).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_productos_sin_venta_con_stock(p_sucursal_id bigint, p_dias integer DEFAULT 30, p_limit integer DEFAULT 30)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH params AS (
    SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - (p_dias - 1) AS desde
  ),
  ultima AS (
    SELECT pi.producto_id, MAX(pe.fecha) AS ultima_venta,
           BOOL_OR(pe.fecha >= pr.desde) AS vendio_en_ventana
      FROM pedido_items pi
      JOIN pedidos pe ON pe.id = pi.pedido_id, params pr
     WHERE pe.sucursal_id = p_sucursal_id
       AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
       AND pe.tipo_factura IS DISTINCT FROM 'VB'
       AND NOT COALESCE(pi.es_bonificacion, false)
     GROUP BY pi.producto_id
  ),
  lista AS (
    SELECT p.id, p.codigo, p.nombre, p.categoria, pv.nombre AS proveedor,
           p.stock, p.precio, (p.stock * COALESCE(p.precio, 0)) AS valor_a_precio_venta,
           u.ultima_venta
      FROM productos p
      LEFT JOIN ultima u ON u.producto_id = p.id
      LEFT JOIN proveedores pv ON pv.id = p.proveedor_id
     WHERE p.sucursal_id = p_sucursal_id
       AND p.activo
       AND COALESCE(p.stock, 0) > 0
       AND COALESCE(u.vendio_en_ventana, false) = false
  )
  SELECT json_build_object(
    'dias', p_dias,
    'criterio', 'Productos activos con stock y sin ninguna unidad entregada (venta, sin regalos) en la ventana. Valor a precio de venta.',
    'productos_count', (SELECT COUNT(*) FROM lista),
    'valor_total_a_precio_venta', (SELECT COALESCE(SUM(valor_a_precio_venta), 0) FROM lista),
    'productos', COALESCE((
      SELECT json_agg(row_to_json(t.*))
        FROM (SELECT * FROM lista ORDER BY valor_a_precio_venta DESC, nombre LIMIT p_limit) t
    ), '[]'::json)
  );
$function$;


-- ----------------------------------------------------------------------------
-- bot_ranking_preventistas_por_producto — unidades y facturado por vendedor.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_ranking_preventistas_por_producto(p_producto_ids bigint[], p_desde date, p_hasta date, p_sucursal_id bigint, p_limit integer DEFAULT 10)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE resultado JSON;
BEGIN
  WITH ventas_filtradas AS (
    SELECT p.usuario_id, pi.producto_id, pi.cantidad, pi.subtotal
    FROM pedidos p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    WHERE p.sucursal_id = p_sucursal_id
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND p.estado = 'entregado'
      AND p.canal <> 'cambio'
      AND p.tipo_factura IS DISTINCT FROM 'VB'
      AND pi.producto_id = ANY(p_producto_ids)
  ),
  por_usuario AS (
    SELECT v.usuario_id, pf.nombre, pf.rol,
      SUM(v.cantidad) AS unidades, SUM(v.subtotal) AS facturado,
      COUNT(DISTINCT v.producto_id) AS productos_distintos,
      COUNT(*) AS line_items
    FROM ventas_filtradas v LEFT JOIN perfiles pf ON pf.id = v.usuario_id
    GROUP BY v.usuario_id, pf.nombre, pf.rol
    ORDER BY SUM(v.cantidad) DESC LIMIT p_limit
  ),
  productos_info AS (
    SELECT id, codigo, nombre FROM productos
    WHERE id = ANY(p_producto_ids) ORDER BY id
  )
  SELECT json_build_object(
    'producto_ids', to_json(p_producto_ids),
    'productos', COALESCE((SELECT json_agg(row_to_json(pi.*)) FROM productos_info pi), '[]'::JSON),
    'desde', p_desde, 'hasta', p_hasta,
    'unidades_total', (SELECT COALESCE(SUM(cantidad), 0) FROM ventas_filtradas),
    'facturado_total', (SELECT COALESCE(SUM(subtotal), 0) FROM ventas_filtradas),
    'preventistas_count', (SELECT COUNT(*) FROM por_usuario),
    'preventistas', COALESCE((SELECT json_agg(row_to_json(pu.*)) FROM por_usuario pu), '[]'::JSON)
  ) INTO resultado;
  RETURN resultado;
END;
$function$;


-- ----------------------------------------------------------------------------
-- bot_resumen_cliente_visita — ficha de visita. Sólo cambia el "último pedido":
-- un vale no es el último pedido que hizo el cliente.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_resumen_cliente_visita(p_cliente_id bigint, p_perfil_id uuid, p_rol text, p_sucursal_id bigint)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ritmo     json;
  v_top       json;
  v_dejados   json;
  v_ultimo    json;
  v_cliente   RECORD;
  v_ve_todo   BOOLEAN := p_rol IN ('admin', 'encargado');
BEGIN
  -- El gate es el mismo de recurrentes y dejados: si este rebota, rebota todo.
  v_top := bot_productos_recurrentes_cliente(p_cliente_id, p_perfil_id, p_rol, p_sucursal_id, 90, 5);
  IF v_top ->> 'error' IS NOT NULL THEN
    RETURN json_build_object('cliente_id', p_cliente_id, 'error', v_top ->> 'error');
  END IF;

  SELECT c.id, c.codigo, COALESCE(NULLIF(btrim(c.nombre_fantasia), ''), c.razon_social) AS nombre,
         c.direccion, c.telefono, c.saldo_cuenta, c.limite_credito, c.es_comodin, c.activo
    INTO v_cliente
    FROM clientes c
   WHERE c.id = p_cliente_id AND c.sucursal_id = p_sucursal_id;
  IF NOT FOUND THEN
    RETURN json_build_object('cliente_id', p_cliente_id, 'error', 'Cliente no encontrado en esta sucursal');
  END IF;

  -- El ritmo de ESTE cliente, con la misma definicion que la lista de atrasados.
  -- Se calcula sobre la sucursal entera (admin) para no depender de la cartera:
  -- el gate de arriba ya decidio si lo puede ver.
  SELECT row_to_json(r.*) INTO v_ritmo
    FROM clientes_ritmo_compra(p_sucursal_id, 'admin', p_perfil_id, NULL, p_cliente_id) r;

  v_dejados := bot_productos_dejados_cliente(p_cliente_id, p_perfil_id, p_rol, p_sucursal_id);

  -- Ultimo pedido: el propio para quien no ve todos (montos propios).
  SELECT json_build_object('fecha', pe.fecha, 'total', pe.total, 'estado', pe.estado,
                           'estado_pago', pe.estado_pago)
    INTO v_ultimo
    FROM pedidos pe
   WHERE pe.cliente_id = p_cliente_id AND pe.sucursal_id = p_sucursal_id
     AND pe.estado IS DISTINCT FROM 'cancelado'
     AND pe.tipo_factura IS DISTINCT FROM 'VB'
     AND (v_ve_todo OR pe.usuario_id = p_perfil_id OR pe.transportista_id = p_perfil_id)
   ORDER BY pe.fecha DESC, pe.id DESC
   LIMIT 1;

  RETURN json_build_object(
    'cliente', json_build_object('id', v_cliente.id, 'codigo', v_cliente.codigo,
       'nombre', v_cliente.nombre, 'direccion', v_cliente.direccion,
       'telefono', v_cliente.telefono, 'es_comodin', v_cliente.es_comodin,
       'activo', v_cliente.activo),
    'saldo', v_cliente.saldo_cuenta,
    'limite_credito', v_cliente.limite_credito,
    'ritmo', CASE WHEN v_ritmo IS NULL THEN NULL ELSE json_build_object(
       'ultima_compra', v_ritmo ->> 'ultima_compra',
       'dias_sin_comprar', (v_ritmo ->> 'dias_sin_comprar')::int,
       'frecuencia_dias', (v_ritmo ->> 'frecuencia_dias')::numeric,
       'estado', v_ritmo ->> 'estado') END,
    'top_productos', v_top -> 'productos',
    'montos', CASE WHEN v_ve_todo THEN 'todos' ELSE 'propios' END,
    'dejados', v_dejados -> 'productos',
    'ultimo_pedido', v_ultimo,
    'ultimo_pedido_alcance', CASE WHEN v_ve_todo THEN 'todos' ELSE 'propios' END
  );
END;
$function$;


-- ----------------------------------------------------------------------------
-- bot_riesgo_por_preventista — N17 le llega por clientes_ritmo_compra (los
-- clientes VB ya no están en ninguno de sus CTE). Acá sólo el EXISTS de "venta
-- de un preventista activo en 180 días", que es venta como cualquier otra.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_riesgo_por_preventista(p_sucursal_id bigint)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF p_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'bot_riesgo_por_preventista: sucursal requerida';
  END IF;

  RETURN (
    WITH sucursal AS (
      SELECT COUNT(*) FILTER (WHERE estado = 'atrasado') AS atrasados,
             COALESCE(SUM(monto_mensual) FILTER (WHERE estado = 'atrasado'), 0) AS monto
        FROM clientes_ritmo_compra(p_sucursal_id, 'admin', NULL, NULL)
    ),
    -- Atrasados que no estan en la cartera de nadie: sin preventista asignado,
    -- no reservados a administracion (mig 214: reservado es lo contrario de
    -- "sin asignar") y sin venta de un preventista activo en 180 dias (esos
    -- huerfanos ya cuentan en la cartera de quien les vendio).
    sin_asignar AS (
      SELECT COUNT(*) AS atrasados, COALESCE(SUM(r.monto_mensual), 0) AS monto
        FROM clientes_ritmo_compra(p_sucursal_id, 'admin', NULL, NULL) r
        JOIN clientes c ON c.id = r.cliente_id
       WHERE r.estado = 'atrasado'
         AND NOT c.reservado_admin
         AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = r.cliente_id)
         AND NOT EXISTS (
               SELECT 1 FROM pedidos pe
                 JOIN perfiles pf ON pf.id = pe.usuario_id AND pf.rol = 'preventista' AND pf.activo
                WHERE pe.cliente_id = r.cliente_id AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
                  AND pe.tipo_factura IS DISTINCT FROM 'VB'
                  AND pe.fecha >= (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 179)
    ),
    reservados AS (
      SELECT COUNT(*) AS atrasados, COALESCE(SUM(r.monto_mensual), 0) AS monto
        FROM clientes_ritmo_compra(p_sucursal_id, 'admin', NULL, NULL) r
        JOIN clientes c ON c.id = r.cliente_id
       WHERE r.estado = 'atrasado' AND c.reservado_admin
    ),
    por_preventista AS (
      SELECT pf.id, pf.nombre,
             COUNT(*) FILTER (WHERE r.estado = 'atrasado') AS atrasados,
             COALESCE(SUM(r.monto_mensual) FILTER (WHERE r.estado = 'atrasado'), 0) AS monto,
             COUNT(r.cliente_id) AS clientes_en_cartera
        FROM perfiles pf
        JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = p_sucursal_id
        LEFT JOIN LATERAL clientes_ritmo_compra(p_sucursal_id, 'admin', NULL, pf.id) r ON true
       WHERE pf.rol = 'preventista' AND pf.activo
       GROUP BY pf.id, pf.nombre
    )
    SELECT json_build_object(
      'sucursal_id', p_sucursal_id,
      'criterio', 'Atrasados de la cartera de cada preventista (asignados mas huerfanos donde vendio en 180 dias), con lo que el cliente compra por mes a todos los vendedores. Un cliente en dos carteras cuenta en las dos: el total es el de la sucursal.',
      'total_atrasados', (SELECT atrasados FROM sucursal),
      'total_monto_mensual', (SELECT ROUND(monto, 2) FROM sucursal),
      'sin_asignar_atrasados', (SELECT atrasados FROM sin_asignar),
      'sin_asignar_monto_mensual', (SELECT ROUND(monto, 2) FROM sin_asignar),
      'reservados_atrasados', (SELECT atrasados FROM reservados),
      'reservados_monto_mensual', (SELECT ROUND(monto, 2) FROM reservados),
      'preventistas', COALESCE((
        SELECT json_agg(json_build_object(
                 'perfil_id', id, 'nombre', nombre, 'atrasados', atrasados,
                 'monto_mensual_en_riesgo', ROUND(monto, 2),
                 'clientes_en_cartera', clientes_en_cartera)
               ORDER BY monto DESC, nombre)
          FROM por_preventista
      ), '[]'::json)
    )
  );
END;
$function$;


-- ----------------------------------------------------------------------------
-- bot_stock_y_ventas — unidades vendidas en 30 días (sin regalos).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_stock_y_ventas(p_sucursal_id bigint, p_rol text, p_texto text DEFAULT NULL::text, p_proveedor text DEFAULT NULL::text, p_categoria text DEFAULT NULL::text, p_limit integer DEFAULT 30)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH params AS (
    SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 29 AS desde,
           p_rol IN ('admin', 'encargado') AS ve_ventas,
           -- El texto del usuario va literal: % y _ no son comodines.
           replace(replace(replace(p_texto, '\', '\\'), '%', '\%'), '_', '\_') AS t,
           replace(replace(replace(p_proveedor, '\', '\\'), '%', '\%'), '_', '\_') AS pv,
           replace(replace(replace(p_categoria, '\', '\\'), '%', '\%'), '_', '\_') AS ca
  ),
  candidatos AS (
    SELECT p.id, p.codigo, p.nombre, p.categoria, pv.nombre AS proveedor,
           p.stock, p.stock_minimo, p.precio
      FROM productos p
      LEFT JOIN proveedores pv ON pv.id = p.proveedor_id
      CROSS JOIN params f
     WHERE p.sucursal_id = p_sucursal_id
       AND p.activo
       AND (f.t IS NULL OR p.nombre ILIKE '%' || f.t || '%' OR p.codigo ILIKE '%' || f.t || '%')
       AND (f.pv IS NULL OR pv.nombre ILIKE '%' || f.pv || '%')
       AND (f.ca IS NULL OR p.categoria ILIKE '%' || f.ca || '%')
  ),
  ventas AS (
    SELECT pi.producto_id,
           SUM(pi.cantidad) FILTER (WHERE NOT COALESCE(pi.es_bonificacion, false)) AS vendidas,
           SUM(pi.cantidad) FILTER (WHERE COALESCE(pi.es_bonificacion, false))     AS regaladas
      FROM pedido_items pi
      JOIN pedidos pe ON pe.id = pi.pedido_id
      JOIN candidatos ca ON ca.id = pi.producto_id, params pr
     WHERE pe.sucursal_id = p_sucursal_id
       AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
       AND pe.tipo_factura IS DISTINCT FROM 'VB'
       AND pe.fecha >= pr.desde
     GROUP BY pi.producto_id
  ),
  filas AS (
    SELECT ca.*,
           CASE WHEN pr.ve_ventas THEN COALESCE(v.vendidas, 0) END AS vendidas_30d,
           CASE WHEN pr.ve_ventas THEN COALESCE(v.regaladas, 0) END AS regaladas_30d,
           CASE WHEN pr.ve_ventas AND COALESCE(v.vendidas, 0) > 0
                THEN ROUND(ca.stock / (v.vendidas / 30.0), 0) END AS cobertura_dias
      FROM candidatos ca CROSS JOIN params pr
      LEFT JOIN ventas v ON v.producto_id = ca.id
  )
  SELECT json_build_object(
    'filtro', json_build_object('texto', p_texto, 'proveedor', p_proveedor, 'categoria', p_categoria),
    'ventas_visibles', (SELECT ve_ventas FROM params),
    'criterio', 'Ventas: unidades entregadas en los ultimos 30 dias, sin regalos (aparte). Cobertura: dias de stock al ritmo de esas ventas.',
    'productos_count', (SELECT COUNT(*) FROM filas),
    'productos', COALESCE((
      SELECT json_agg(row_to_json(t.*))
        FROM (SELECT * FROM filas ORDER BY vendidas_30d DESC NULLS LAST, nombre LIMIT p_limit) t
    ), '[]'::json)
  );
$function$;


-- ----------------------------------------------------------------------------
-- bot_ventas_periodo — ventas del período, ticket promedio, top clientes y top
-- productos. `en_curso` (asignado/pendiente) no se toca: un VB nace entregado.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_ventas_periodo(p_desde date, p_hasta date, p_sucursal_id bigint, p_limit integer DEFAULT 10)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE resultado JSON;
BEGIN
  WITH ventas_filtradas AS (
    SELECT id, cliente_id, total, fecha
    FROM pedidos
    WHERE sucursal_id = p_sucursal_id
      AND fecha BETWEEN p_desde AND p_hasta
      AND estado = 'entregado' AND canal <> 'cambio'
      AND tipo_factura IS DISTINCT FROM 'VB'
  ),
  en_curso AS (
    SELECT COALESCE(SUM(total), 0) AS monto, COUNT(*) AS pedidos
    FROM pedidos
    WHERE sucursal_id = p_sucursal_id
      AND fecha BETWEEN p_desde AND p_hasta
      AND canal <> 'cambio'
      AND COALESCE(estado, '') IN ('asignado', 'pendiente')
  ),
  top_clientes AS (
    SELECT c.id, c.codigo, c.nombre_fantasia, c.razon_social, c.es_comodin,
      SUM(v.total) AS total_comprado, COUNT(*) AS pedidos
    FROM ventas_filtradas v JOIN clientes c ON c.id = v.cliente_id
    GROUP BY c.id, c.codigo, c.nombre_fantasia, c.razon_social, c.es_comodin
    ORDER BY SUM(v.total) DESC LIMIT p_limit
  ),
  top_productos AS (
    SELECT p.id, p.codigo, p.nombre, SUM(pi.cantidad) AS unidades, SUM(pi.subtotal) AS facturado
    FROM ventas_filtradas v
    JOIN pedido_items pi ON pi.pedido_id = v.id
    JOIN productos p ON p.id = pi.producto_id
    GROUP BY p.id, p.codigo, p.nombre
    ORDER BY SUM(pi.subtotal) DESC LIMIT p_limit
  )
  SELECT json_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'total_ventas', (SELECT COALESCE(SUM(total), 0) FROM ventas_filtradas),
    'pedidos_count', (SELECT COUNT(*) FROM ventas_filtradas),
    'ticket_promedio', (SELECT CASE WHEN COUNT(*) > 0 THEN ROUND(AVG(total), 2) ELSE 0 END FROM ventas_filtradas),
    'en_curso_monto', (SELECT monto FROM en_curso),
    'en_curso_pedidos', (SELECT pedidos FROM en_curso),
    'top_clientes', COALESCE((SELECT json_agg(row_to_json(tc.*)) FROM top_clientes tc), '[]'::JSON),
    'top_productos', COALESCE((SELECT json_agg(row_to_json(tp.*)) FROM top_productos tp), '[]'::JSON)
  ) INTO resultado;
  RETURN resultado;
END;
$function$;


-- ----------------------------------------------------------------------------
-- clientes_ritmo_compra — N17. Tres cambios:
--   1) `universo`: un cliente con tipo_factura_default = 'VB' no entra (sin
--      "ventas" aparecería como cliente perdido). Alcanza para bot_clientes_atrasados
--      y bot_riesgo_por_preventista, que lo consumen.
--   2) el EXISTS de "venta de este preventista en 180 días" (cartera huérfana),
--   3) `ventas`: las entregas que arman frecuencia, última compra y monto mensual.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clientes_ritmo_compra(p_sucursal_id bigint, p_rol text, p_perfil_id uuid, p_preventista_id uuid DEFAULT NULL::uuid, p_cliente_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(cliente_id bigint, codigo integer, nombre text, zona text, es_comodin boolean, saldo numeric, ultima_compra date, dias_sin_comprar integer, entregas_365 integer, frecuencia_dias numeric, ratio numeric, estado text, monto_mensual numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH params AS (
    SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS hoy,
           CASE WHEN p_rol IN ('admin', 'encargado') THEN p_preventista_id
                ELSE p_perfil_id END AS prev,
           p_rol NOT IN ('admin', 'encargado') AS solo_propio
  ),
  universo AS (
    SELECT c.id, c.codigo,
           COALESCE(NULLIF(btrim(c.nombre_fantasia), ''), NULLIF(btrim(c.razon_social), ''), '(sin nombre)') AS nombre,
           -- La zona como la muestra la app (reporte_ventas_por_cliente): la de
           -- la tabla zonas, y el texto viejo sólo si no hay zona asignada.
           COALESCE(z.nombre, NULLIF(btrim(c.zona), ''), 'SIN ZONA') AS zona,
           c.es_comodin, c.saldo_cuenta
      FROM clientes c
      LEFT JOIN zonas z ON z.id = c.zona_id
      CROSS JOIN params pr
     WHERE c.sucursal_id = p_sucursal_id
       AND c.activo
       -- 3XD (N17): un cliente de consumo interno (vale blanco) no tiene ritmo
       -- de compra: no es atrasado ni perdido, no es cartera de nadie.
       AND c.tipo_factura_default <> 'VB'
       AND (p_cliente_id IS NULL OR c.id = p_cliente_id)
       AND (
             -- Toda la sucursal: solo admin/encargado sin filtro de preventista.
             (pr.prev IS NULL AND NOT pr.solo_propio)
             OR (pr.prev IS NOT NULL AND (
                  EXISTS (SELECT 1 FROM cliente_preventistas cp
                           WHERE cp.cliente_id = c.id AND cp.preventista_id = pr.prev)
                  OR (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
                      AND EXISTS (SELECT 1 FROM pedidos pe
                                   WHERE pe.cliente_id = c.id AND pe.usuario_id = pr.prev
                                     AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
                                     AND pe.tipo_factura IS DISTINCT FROM 'VB'
                                     AND pe.fecha >= pr.hoy - 179))
                ))
           )
       -- Reservado a administracion: fuera de la cartera de un preventista,
       -- salvo que ya le haya vendido (mig 214).
       AND (NOT c.reservado_admin OR pr.prev IS NULL
            OR EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = pr.prev))
  ),
  ventas AS (
    SELECT pe.cliente_id, pe.fecha, pe.total, pe.usuario_id
      FROM pedidos pe JOIN universo u ON u.id = pe.cliente_id, params pr
     WHERE pe.sucursal_id = p_sucursal_id
       AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
       AND pe.tipo_factura IS DISTINCT FROM 'VB'
       AND pe.fecha >= pr.hoy - 364
  ),
  fechas AS (
    SELECT DISTINCT cliente_id, fecha FROM ventas
  ),
  gaps AS (
    SELECT cliente_id, (fecha - LAG(fecha) OVER (PARTITION BY cliente_id ORDER BY fecha)) AS gap
      FROM fechas
  ),
  -- Agrupado y no una subconsulta correlacionada: con 600 clientes la
  -- correlacionada recorria todas las fechas por cliente (255 ms contra 20).
  med AS (
    SELECT cliente_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY gap)::numeric AS frecuencia
      FROM gaps WHERE gap IS NOT NULL GROUP BY cliente_id
  ),
  ritmo AS (
    SELECT f.cliente_id,
           MAX(f.fecha) AS ultima,
           -- Dias distintos con entrega, no pedidos: dos pedidos el mismo dia son una visita.
           COUNT(*)::int AS entregas,
           MAX(m.frecuencia) AS frecuencia
      FROM fechas f LEFT JOIN med m ON m.cliente_id = f.cliente_id
     GROUP BY f.cliente_id
  ),
  montos AS (
    SELECT v.cliente_id, SUM(v.total) / 6 AS mensual
      FROM ventas v, params pr
     WHERE v.fecha >= pr.hoy - 179
       AND (NOT pr.solo_propio OR v.usuario_id = p_perfil_id)
     GROUP BY v.cliente_id
  )
  SELECT u.id, u.codigo, u.nombre, u.zona, u.es_comodin, u.saldo_cuenta,
         r.ultima,
         (pr.hoy - r.ultima)::int,
         COALESCE(r.entregas, 0),
         ROUND(r.frecuencia, 1),
         CASE WHEN r.frecuencia > 0 THEN ROUND((pr.hoy - r.ultima) / r.frecuencia, 2) END,
         CASE
           WHEN r.ultima IS NULL THEN 'sin_compras'
           WHEN pr.hoy - r.ultima > 180 THEN 'perdido'
           WHEN pr.hoy - r.ultima > 90 THEN 'inactivo'
           WHEN r.entregas < 3 OR r.frecuencia IS NULL OR r.frecuencia = 0 THEN
             CASE WHEN pr.hoy - r.ultima >= 45 THEN 'ocasional' ELSE 'al_dia' END
           WHEN pr.hoy - r.ultima >= GREATEST(2 * r.frecuencia, 14) THEN 'atrasado'
           WHEN pr.hoy - r.ultima >= GREATEST(1.5 * r.frecuencia, 7) THEN 'por_vencer'
           ELSE 'al_dia'
         END,
         ROUND(COALESCE(m.mensual, 0), 2)
    FROM universo u
    CROSS JOIN params pr
    LEFT JOIN ritmo r  ON r.cliente_id = u.id
    LEFT JOIN montos m ON m.cliente_id = u.id;
$function$;


-- ----------------------------------------------------------------------------
-- jornada_preventista_detalle — desempeño del preventista, detalle del día.
-- Un VB (entregado o cancelado) no es un pedido que el preventista haya salido
-- a vender: ni entregado ni "rechazado". Se filtra también en los pendientes
-- de las otras jornadas por consistencia.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.jornada_preventista_detalle(p_dia date, p_preventista_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_target   uuid;
  v_sucursal bigint;
  v_out      jsonb;
BEGIN
  v_target := COALESCE(p_preventista_id, auth.uid());

  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Sin usuario' USING ERRCODE = '42501';
  END IF;

  IF auth.uid() IS NOT NULL AND v_target <> auth.uid() AND NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
  END IF;

  v_sucursal := current_sucursal_id();

  WITH candidatos AS (
    SELECT
      p.*,
      CASE
        WHEN p.estado = 'entregado' THEN
          COALESCE((p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
                   (SELECT (h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      FROM pedido_historial h
                     WHERE h.pedido_id = p.id
                       AND h.campo_modificado = 'estado'
                       AND h.valor_nuevo = 'entregado'
                     ORDER BY h.created_at DESC
                     LIMIT 1),
                   p.fecha)
        WHEN p.estado = 'cancelado' THEN
          COALESCE((SELECT (h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      FROM pedido_historial h
                     WHERE h.pedido_id = p.id
                       AND h.campo_modificado = 'estado'
                       AND h.valor_nuevo LIKE 'cancelado%'
                     ORDER BY h.created_at DESC
                     LIMIT 1),
                   p.fecha)
        ELSE NULL
      END AS dia
    FROM pedidos p
    WHERE p.usuario_id  = v_target
      AND p.sucursal_id = v_sucursal
      AND p.canal <> 'cambio'
      AND p.tipo_factura IS DISTINCT FROM 'VB'
      AND (
        (p_dia IS NOT NULL
         AND p.estado IN ('entregado','cancelado')
         AND p.fecha BETWEEN (p_dia - 90) AND p_dia)
        OR (p_dia IS NULL AND p.estado NOT IN ('entregado','cancelado'))
      )
  ),
  filtrados AS (
    SELECT * FROM candidatos
    WHERE (p_dia IS NULL AND dia IS NULL) OR dia = p_dia
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'pedido_id', f.id,
    'cliente',   COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, 'Cliente'),
    'monto',     CASE WHEN f.estado = 'cancelado'
                   THEN COALESCE(NULLIF(f.total, 0), NULLIF(f.total_real, 0),
                                 (SELECT COALESCE(SUM(pi.subtotal), 0) FROM pedido_items pi
                                   WHERE pi.pedido_id = f.id))
                   ELSE f.total END,
    'desenlace', CASE
      WHEN f.estado = 'entregado'
           AND EXISTS (SELECT 1 FROM salvedades_items s
                        WHERE s.pedido_id = f.id AND s.estado_resolucion <> 'anulada')
        THEN 'entregado_con_salvedad'
      WHEN f.estado = 'entregado' THEN 'entregado'
      WHEN f.estado = 'cancelado'
           AND f.motivo_cancelacion_tipo IN
               ('error_de_carga','prueba','duplicado','unifica_pedidos','cambio_de_cliente','falta_stock')
        THEN 'administrativo'
      WHEN f.estado = 'cancelado' THEN 'rechazado'
      ELSE 'pendiente'
    END,
    'estado',        f.estado,
    'fecha_pedido',  f.fecha,
    'motivo_tipo',   f.motivo_cancelacion_tipo,
    'motivo_nota',   NULLIF(btrim(COALESCE(f.motivo_cancelacion, '')), ''),
    'transportista', tr.nombre,
    'salvedades', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'producto',          pr.nombre,
        'cantidad_afectada', s.cantidad_afectada,
        'cantidad_original', s.cantidad_original,
        'motivo',            s.motivo,
        'descripcion',       NULLIF(btrim(COALESCE(s.descripcion, '')), ''),
        'monto_afectado',    s.monto_afectado
      ) ORDER BY pr.nombre), '[]'::jsonb)
      FROM salvedades_items s
      JOIN productos pr ON pr.id = s.producto_id
      WHERE s.pedido_id = f.id AND s.estado_resolucion <> 'anulada'
    )
  ) ORDER BY f.id DESC), '[]'::jsonb)
  INTO v_out
  FROM filtrados f
  LEFT JOIN clientes c ON c.id = f.cliente_id
  LEFT JOIN perfiles tr ON tr.id = f.transportista_id;

  RETURN v_out;
END;
$function$;


-- ----------------------------------------------------------------------------
-- jornada_transportista_detalle — idem, desde el lado del transportista. Un VB
-- viejo con transportista (los 75 históricos) no es una entrega que haya
-- repartido en ruta.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.jornada_transportista_detalle(p_dia date, p_transportista_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_target   uuid;
  v_sucursal bigint;
  v_out      jsonb;
BEGIN
  v_target := COALESCE(p_transportista_id, auth.uid());

  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Sin usuario' USING ERRCODE = '42501';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF v_target <> auth.uid() AND NOT es_encargado_o_admin() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
    -- es_transportista() incluye admin y rol extra (trampa 4): ver encabezado.
    IF NOT (es_transportista() OR es_encargado_o_admin()) THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
  END IF;

  v_sucursal := current_sucursal_id();

  WITH candidatos AS (
    SELECT
      p.*,
      CASE
        WHEN p.estado = 'entregado' THEN
          COALESCE((p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
                   (SELECT (h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      FROM pedido_historial h
                     WHERE h.pedido_id = p.id
                       AND h.campo_modificado = 'estado'
                       AND h.valor_nuevo = 'entregado'
                     ORDER BY h.created_at DESC
                     LIMIT 1),
                   p.fecha)
        WHEN p.estado = 'cancelado' THEN
          COALESCE((SELECT (h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      FROM pedido_historial h
                     WHERE h.pedido_id = p.id
                       AND h.campo_modificado = 'estado'
                       AND h.valor_nuevo LIKE 'cancelado%'
                     ORDER BY h.created_at DESC
                     LIMIT 1),
                   p.fecha)
        ELSE NULL
      END AS dia
    FROM pedidos p
    WHERE p.transportista_id = v_target
      AND p.sucursal_id      = v_sucursal
      AND p.canal <> 'cambio'
      AND p.tipo_factura IS DISTINCT FROM 'VB'
      AND (
        (p_dia IS NOT NULL
         AND p.estado IN ('entregado','cancelado')
         AND p.fecha BETWEEN (p_dia - 90) AND p_dia)
        OR (p_dia IS NULL AND p.estado NOT IN ('entregado','cancelado'))
      )
  ),
  filtrados AS (
    SELECT * FROM candidatos
    WHERE (p_dia IS NULL AND dia IS NULL) OR dia = p_dia
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'pedido_id', f.id,
    'cliente',   COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, 'Cliente'),
    'monto',     CASE WHEN f.estado = 'cancelado'
                   THEN COALESCE(NULLIF(f.total, 0), NULLIF(f.total_real, 0),
                                 (SELECT COALESCE(SUM(pi.subtotal), 0) FROM pedido_items pi
                                   WHERE pi.pedido_id = f.id))
                   ELSE f.total END,
    'desenlace', CASE
      WHEN f.estado = 'entregado'
           AND EXISTS (SELECT 1 FROM salvedades_items s
                        WHERE s.pedido_id = f.id AND s.estado_resolucion <> 'anulada')
        THEN 'entregado_con_salvedad'
      WHEN f.estado = 'entregado' THEN 'entregado'
      WHEN f.estado = 'cancelado'
           AND f.motivo_cancelacion_tipo IN
               ('error_de_carga','prueba','duplicado','unifica_pedidos','cambio_de_cliente','falta_stock')
        THEN 'administrativo'
      WHEN f.estado = 'cancelado' THEN 'rechazado'
      ELSE 'pendiente'
    END,
    'estado',        f.estado,
    'fecha_pedido',  f.fecha,
    'motivo_tipo',   f.motivo_cancelacion_tipo,
    'motivo_nota',   NULLIF(btrim(COALESCE(f.motivo_cancelacion, '')), ''),
    -- Acá el transportista es uno mismo: lo que informa es quién vendió.
    'transportista', NULL,
    'vendedor',      ve.nombre,
    'salvedades', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'producto',          pr.nombre,
        'cantidad_afectada', s.cantidad_afectada,
        'cantidad_original', s.cantidad_original,
        'motivo',            s.motivo,
        'descripcion',       NULLIF(btrim(COALESCE(s.descripcion, '')), ''),
        'monto_afectado',    s.monto_afectado
      ) ORDER BY pr.nombre), '[]'::jsonb)
      FROM salvedades_items s
      JOIN productos pr ON pr.id = s.producto_id
      WHERE s.pedido_id = f.id AND s.estado_resolucion <> 'anulada'
    )
  ) ORDER BY f.id DESC), '[]'::jsonb)
  INTO v_out
  FROM filtrados f
  LEFT JOIN clientes c ON c.id = f.cliente_id
  LEFT JOIN perfiles ve ON ve.id = f.usuario_id;

  RETURN v_out;
END;
$function$;


-- ----------------------------------------------------------------------------
-- jornadas_preventista — desempeño por día (entregados/rechazados/monto).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.jornadas_preventista(p_desde date, p_hasta date, p_preventista_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_target    uuid;
  v_nombre    text;
  v_sucursal  bigint;
  v_dias      jsonb;
  v_pend      jsonb;
  v_totales   jsonb;
BEGIN
  v_target := COALESCE(p_preventista_id, auth.uid());

  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Sin usuario' USING ERRCODE = '42501';
  END IF;

  IF auth.uid() IS NOT NULL AND v_target <> auth.uid() AND NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
  END IF;

  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde THEN
    RAISE EXCEPTION 'Rango de fechas invalido' USING ERRCODE = '22007';
  END IF;

  v_sucursal := current_sucursal_id();

  SELECT nombre INTO v_nombre FROM perfiles WHERE id = v_target;

  WITH resueltos AS (
    SELECT
      CASE
        WHEN p.estado = 'entregado' THEN
          COALESCE((p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
                   (SELECT (h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      FROM pedido_historial h
                     WHERE h.pedido_id = p.id
                       AND h.campo_modificado = 'estado'
                       AND h.valor_nuevo = 'entregado'
                     ORDER BY h.created_at DESC
                     LIMIT 1),
                   p.fecha)
        ELSE
          COALESCE((SELECT (h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      FROM pedido_historial h
                     WHERE h.pedido_id = p.id
                       AND h.campo_modificado = 'estado'
                       AND h.valor_nuevo LIKE 'cancelado%'
                     ORDER BY h.created_at DESC
                     LIMIT 1),
                   p.fecha)
      END AS dia,
      CASE
        WHEN p.estado = 'entregado'
             AND EXISTS (SELECT 1 FROM salvedades_items s
                          WHERE s.pedido_id = p.id
                            AND s.estado_resolucion <> 'anulada')
          THEN 'entregado_con_salvedad'
        WHEN p.estado = 'entregado' THEN 'entregado'
        WHEN p.motivo_cancelacion_tipo IN
             ('error_de_carga','prueba','duplicado','unifica_pedidos','cambio_de_cliente','falta_stock')
          THEN 'administrativo'
        ELSE 'rechazado'
      END AS desenlace,
      CASE WHEN p.estado = 'cancelado'
        THEN COALESCE(NULLIF(p.total, 0), NULLIF(p.total_real, 0),
                      (SELECT COALESCE(SUM(pi.subtotal), 0) FROM pedido_items pi
                        WHERE pi.pedido_id = p.id))
        ELSE p.total
      END AS monto
    FROM pedidos p
    WHERE p.usuario_id  = v_target
      AND p.sucursal_id = v_sucursal
      AND p.canal <> 'cambio'
      AND p.tipo_factura IS DISTINCT FROM 'VB'
      AND p.estado IN ('entregado','cancelado')
      AND p.fecha >= (p_desde - 90)
      AND p.fecha <= p_hasta
  ),
  del_rango AS (
    SELECT * FROM resueltos WHERE dia BETWEEN p_desde AND p_hasta
  ),
  por_dia AS (
    SELECT
      dia,
      COUNT(*)                                                        AS total,
      COUNT(*) FILTER (WHERE desenlace LIKE 'entregado%')             AS entregados,
      COUNT(*) FILTER (WHERE desenlace = 'entregado_con_salvedad')    AS con_salvedad,
      COUNT(*) FILTER (WHERE desenlace = 'rechazado')                 AS rechazados,
      COUNT(*) FILTER (WHERE desenlace = 'administrativo')            AS administrativos,
      COALESCE(SUM(monto) FILTER (WHERE desenlace LIKE 'entregado%'), 0) AS monto_entregado,
      COALESCE(SUM(monto) FILTER (WHERE desenlace = 'rechazado'), 0)     AS monto_rechazado
    FROM del_rango
    GROUP BY dia
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'dia',             d.dia,
      'total',           d.total,
      'entregados',      d.entregados,
      'con_salvedad',    d.con_salvedad,
      'rechazados',      d.rechazados,
      'administrativos', d.administrativos,
      'monto_entregado', d.monto_entregado,
      'monto_rechazado', d.monto_rechazado
    ) ORDER BY d.dia DESC), '[]'::jsonb),
    jsonb_build_object(
      'entregados',  COALESCE(SUM(d.entregados), 0),
      'rechazados',  COALESCE(SUM(d.rechazados), 0),
      'pct_rechazo', CASE
        WHEN COALESCE(SUM(d.entregados), 0) + COALESCE(SUM(d.rechazados), 0) = 0 THEN 0
        ELSE ROUND(100.0 * SUM(d.rechazados) / (SUM(d.entregados) + SUM(d.rechazados)), 1)
      END,
      'monto_rechazado', COALESCE(SUM(d.monto_rechazado), 0)
    )
  INTO v_dias, v_totales
  FROM por_dia d;

  SELECT jsonb_build_object(
    'total',     COUNT(*),
    'monto',     COALESCE(SUM(p.total), 0),
    'mas_viejo', MIN(p.fecha)
  )
  INTO v_pend
  FROM pedidos p
  WHERE p.usuario_id  = v_target
    AND p.sucursal_id = v_sucursal
    AND p.canal <> 'cambio'
    AND p.tipo_factura IS DISTINCT FROM 'VB'
    AND p.estado NOT IN ('entregado','cancelado');

  RETURN jsonb_build_object(
    'preventista_id', v_target,
    'nombre',         v_nombre,
    'desde',          p_desde,
    'hasta',          p_hasta,
    'dias',           v_dias,
    'totales',        v_totales,
    'pendientes',     v_pend
  );
END;
$function$;


-- ----------------------------------------------------------------------------
-- jornadas_transportista — idem, desde el lado del transportista.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.jornadas_transportista(p_desde date, p_hasta date, p_transportista_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_target    uuid;
  v_nombre    text;
  v_sucursal  bigint;
  v_dias      jsonb;
  v_pend      jsonb;
  v_totales   jsonb;
BEGIN
  v_target := COALESCE(p_transportista_id, auth.uid());

  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Sin usuario' USING ERRCODE = '42501';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF v_target <> auth.uid() AND NOT es_encargado_o_admin() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
    -- es_transportista() incluye admin y rol extra (trampa 4): ver encabezado.
    IF NOT (es_transportista() OR es_encargado_o_admin()) THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde THEN
    RAISE EXCEPTION 'Rango de fechas invalido' USING ERRCODE = '22007';
  END IF;

  v_sucursal := current_sucursal_id();

  SELECT nombre INTO v_nombre FROM perfiles WHERE id = v_target;

  -- Mismo cálculo de día, desenlace y monto que jornadas_preventista (179).
  WITH resueltos AS (
    SELECT
      CASE
        WHEN p.estado = 'entregado' THEN
          COALESCE((p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
                   (SELECT (h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      FROM pedido_historial h
                     WHERE h.pedido_id = p.id
                       AND h.campo_modificado = 'estado'
                       AND h.valor_nuevo = 'entregado'
                     ORDER BY h.created_at DESC
                     LIMIT 1),
                   p.fecha)
        ELSE
          COALESCE((SELECT (h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      FROM pedido_historial h
                     WHERE h.pedido_id = p.id
                       AND h.campo_modificado = 'estado'
                       AND h.valor_nuevo LIKE 'cancelado%'
                     ORDER BY h.created_at DESC
                     LIMIT 1),
                   p.fecha)
      END AS dia,
      CASE
        WHEN p.estado = 'entregado'
             AND EXISTS (SELECT 1 FROM salvedades_items s
                          WHERE s.pedido_id = p.id
                            AND s.estado_resolucion <> 'anulada')
          THEN 'entregado_con_salvedad'
        WHEN p.estado = 'entregado' THEN 'entregado'
        WHEN p.motivo_cancelacion_tipo IN
             ('error_de_carga','prueba','duplicado','unifica_pedidos','cambio_de_cliente','falta_stock')
          THEN 'administrativo'
        ELSE 'rechazado'
      END AS desenlace,
      CASE WHEN p.estado = 'cancelado'
        THEN COALESCE(NULLIF(p.total, 0), NULLIF(p.total_real, 0),
                      (SELECT COALESCE(SUM(pi.subtotal), 0) FROM pedido_items pi
                        WHERE pi.pedido_id = p.id))
        ELSE p.total
      END AS monto
    FROM pedidos p
    WHERE p.transportista_id = v_target
      AND p.sucursal_id      = v_sucursal
      AND p.canal <> 'cambio'
      AND p.tipo_factura IS DISTINCT FROM 'VB'
      AND p.estado IN ('entregado','cancelado')
      AND p.fecha >= (p_desde - 90)
      AND p.fecha <= p_hasta
  ),
  del_rango AS (
    SELECT * FROM resueltos WHERE dia BETWEEN p_desde AND p_hasta
  ),
  por_dia AS (
    SELECT
      dia,
      COUNT(*)                                                        AS total,
      COUNT(*) FILTER (WHERE desenlace LIKE 'entregado%')             AS entregados,
      COUNT(*) FILTER (WHERE desenlace = 'entregado_con_salvedad')    AS con_salvedad,
      COUNT(*) FILTER (WHERE desenlace = 'rechazado')                 AS rechazados,
      COUNT(*) FILTER (WHERE desenlace = 'administrativo')            AS administrativos,
      COALESCE(SUM(monto) FILTER (WHERE desenlace LIKE 'entregado%'), 0) AS monto_entregado,
      COALESCE(SUM(monto) FILTER (WHERE desenlace = 'rechazado'), 0)     AS monto_rechazado
    FROM del_rango
    GROUP BY dia
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'dia',             d.dia,
      'total',           d.total,
      'entregados',      d.entregados,
      'con_salvedad',    d.con_salvedad,
      'rechazados',      d.rechazados,
      'administrativos', d.administrativos,
      'monto_entregado', d.monto_entregado,
      'monto_rechazado', d.monto_rechazado
    ) ORDER BY d.dia DESC), '[]'::jsonb),
    jsonb_build_object(
      'entregados',  COALESCE(SUM(d.entregados), 0),
      'rechazados',  COALESCE(SUM(d.rechazados), 0),
      'pct_rechazo', CASE
        WHEN COALESCE(SUM(d.entregados), 0) + COALESCE(SUM(d.rechazados), 0) = 0 THEN 0
        ELSE ROUND(100.0 * SUM(d.rechazados) / (SUM(d.entregados) + SUM(d.rechazados)), 1)
      END,
      'monto_rechazado', COALESCE(SUM(d.monto_rechazado), 0)
    )
  INTO v_dias, v_totales
  FROM por_dia d;

  -- Pendientes: asignados a él y todavía sin desenlace.
  SELECT jsonb_build_object(
    'total',     COUNT(*),
    'monto',     COALESCE(SUM(p.total), 0),
    'mas_viejo', MIN(p.fecha)
  )
  INTO v_pend
  FROM pedidos p
  WHERE p.transportista_id = v_target
    AND p.sucursal_id      = v_sucursal
    AND p.canal <> 'cambio'
    AND p.tipo_factura IS DISTINCT FROM 'VB'
    AND p.estado NOT IN ('entregado','cancelado');

  RETURN jsonb_build_object(
    'transportista_id', v_target,
    'nombre',           v_nombre,
    'desde',            p_desde,
    'hasta',            p_hasta,
    'dias',             v_dias,
    'totales',          v_totales,
    'pendientes',       v_pend
  );
END;
$function$;


-- ----------------------------------------------------------------------------
-- obtener_resumen_cuenta_cliente — ficha de cuenta (app). Total de pedidos,
-- total de compras y último pedido SIN vale blanco (sólo el filtro VB; el canal
-- faltante es otro bug → issue). Se agrega la clave `consumo_interno`
-- {monto, pedidos} para la línea propia de la ficha (N11): es aditiva, ningún
-- consumidor existente la lee, y un cliente VB no queda con la ficha en cero
-- sin explicación.
-- ----------------------------------------------------------------------------
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

  SELECT json_build_object(
    'saldo_actual', COALESCE(c.saldo_cuenta, 0),
    'limite_credito', COALESCE(c.limite_credito, 0),
    'credito_disponible', COALESCE(c.limite_credito, 0) - COALESCE(c.saldo_cuenta, 0),
    'total_pedidos', (SELECT COUNT(*) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND tipo_factura IS DISTINCT FROM 'VB'),
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND tipo_factura IS DISTINCT FROM 'VB'),
    'total_pagos', (SELECT COALESCE(SUM(monto), 0) FROM pagos WHERE cliente_id = p_cliente_id),
    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id AND estado_pago != 'pagado'),
    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND tipo_factura IS DISTINCT FROM 'VB'),
    'ultimo_pago', (SELECT MAX(created_at) FROM pagos WHERE cliente_id = p_cliente_id),
    'consumo_interno', (SELECT json_build_object('monto', COALESCE(SUM(total), 0), 'pedidos', COUNT(*))
                          FROM pedidos
                         WHERE cliente_id = p_cliente_id AND tipo_factura = 'VB'
                           AND estado IS DISTINCT FROM 'cancelado')
  ) INTO resultado
  FROM clientes c
  WHERE c.id = p_cliente_id;

  RETURN resultado;
END;
$function$;


-- ----------------------------------------------------------------------------
-- obtener_resumen_cuenta_cliente_bot — idem para el bot (service role).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_resumen_cuenta_cliente_bot(p_cliente_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
BEGIN
  SELECT json_build_object(
    'saldo_actual', COALESCE(c.saldo_cuenta, 0),
    'limite_credito', COALESCE(c.limite_credito, 0),
    'credito_disponible', COALESCE(c.limite_credito, 0) - COALESCE(c.saldo_cuenta, 0),
    'total_pedidos', (SELECT COUNT(*) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'
                         AND tipo_factura IS DISTINCT FROM 'VB'),
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'
                         AND tipo_factura IS DISTINCT FROM 'VB'),
    'total_pagos', (SELECT COALESCE(SUM(monto), 0) FROM pagos WHERE cliente_id = p_cliente_id),
    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos
                                 WHERE cliente_id = p_cliente_id
                                   AND estado IS DISTINCT FROM 'cancelado'
                                   AND estado_pago IS DISTINCT FROM 'pagado'),
    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'
                         AND tipo_factura IS DISTINCT FROM 'VB'),
    'ultimo_pago', (SELECT MAX(created_at) FROM pagos WHERE cliente_id = p_cliente_id),
    'es_comodin', COALESCE(c.es_comodin, false),
    'consumo_interno', (SELECT json_build_object('monto', COALESCE(SUM(total), 0), 'pedidos', COUNT(*))
                          FROM pedidos
                         WHERE cliente_id = p_cliente_id AND tipo_factura = 'VB'
                           AND estado IS DISTINCT FROM 'cancelado')
  ) INTO resultado
  FROM clientes c
  WHERE c.id = p_cliente_id;

  RETURN resultado;
END;
$function$;


-- ----------------------------------------------------------------------------
-- rendimiento_preventistas — venta, margen comercial, cobertura y clientes
-- nuevos por preventista. Dos cambios: `ped` (la venta) y `primer_pedido` (un
-- cliente "nuevo" lo es por su primera VENTA, no por su primer vale).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rendimiento_preventistas(p_sucursal_id bigint DEFAULT NULL::bigint, p_periodo date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_periodo    date := date_trunc('month', COALESCE(p_periodo, current_date))::date;
  v_hasta      date;
  v_sucursales bigint[];
  v_asignadas  bigint[];
  v_es_servicio boolean := auth.uid() IS NULL;
  v_result     jsonb;
BEGIN
  v_hasta := (v_periodo + interval '1 month - 1 day')::date;

  IF NOT v_es_servicio AND NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede ver el rendimiento del equipo' USING ERRCODE = '42501';
  END IF;

  IF v_es_servicio THEN
    SELECT array_agg(id) INTO v_asignadas FROM sucursales;
  ELSE
    SELECT array_agg(sucursal_id) INTO v_asignadas
    FROM usuario_sucursales WHERE usuario_id = auth.uid();
  END IF;

  IF p_sucursal_id IS NULL THEN
    v_sucursales := v_asignadas;
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id
        USING ERRCODE = '42501';
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;

  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles' USING ERRCODE = '42501';
  END IF;

  WITH
  ped AS MATERIALIZED (
    SELECT id, cliente_id, usuario_id, sucursal_id, total
    FROM pedidos
    WHERE estado = 'entregado' AND canal <> 'cambio'
      AND tipo_factura IS DISTINCT FROM 'VB'
      AND fecha BETWEEN v_periodo AND v_hasta
      AND sucursal_id = ANY(v_sucursales)
  ),
  it AS MATERIALIZED (
    SELECT p.usuario_id, pi.cantidad, pi.subtotal,
           pi.cantidad * COALESCE(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
             prod.costo_sin_iva * (1 + COALESCE(prod.impuestos_internos, 0) / 100)) AS costo,
           COALESCE(mar.nombre, '(sin marca)')          AS marca,
           COALESCE(NULLIF(prod.categoria, ''), '(sin categoría)') AS categoria
    FROM ped p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    JOIN productos prod  ON prod.id = pi.producto_id
    LEFT JOIN marcas mar ON mar.id = prod.marca_id
    WHERE pi.es_bonificacion IS NOT TRUE
  ),
  primer_pedido AS (
    SELECT DISTINCT ON (p.cliente_id, p.sucursal_id)
           p.cliente_id, p.sucursal_id, p.usuario_id, p.fecha
    FROM pedidos p
    WHERE p.estado = 'entregado' AND p.canal <> 'cambio'
      AND p.tipo_factura IS DISTINCT FROM 'VB'
      AND p.sucursal_id = ANY(v_sucursales)
    ORDER BY p.cliente_id, p.sucursal_id, p.fecha, p.id
  ),
  metas AS (
    SELECT preventista_id, COUNT(*) AS total FROM metas_preventista
    WHERE activo AND sucursal_id = ANY(v_sucursales)
      AND periodo <= v_hasta AND periodo_fin >= v_periodo
    GROUP BY preventista_id
  ),
  gente AS (
    SELECT usuario_id FROM ped WHERE usuario_id IS NOT NULL
    UNION
    SELECT preventista_id FROM metas
    UNION
    SELECT us.usuario_id
    FROM usuario_sucursales us
    JOIN perfiles pf ON pf.id = us.usuario_id
    WHERE us.sucursal_id = ANY(v_sucursales)
      AND pf.rol = 'preventista'
      AND COALESCE(pf.activo, true)
  ),
  base AS (
    SELECT g.usuario_id,
           COUNT(p.id)                     AS pedidos,
           COUNT(DISTINCT p.cliente_id)    AS cobertura
    FROM gente g LEFT JOIN ped p ON p.usuario_id = g.usuario_id
    GROUP BY g.usuario_id
  ),
  items AS (
    SELECT i.usuario_id,
           COALESCE(SUM(i.subtotal), 0) AS venta,
           COALESCE(SUM(i.cantidad), 0) AS unidades,
           COALESCE(SUM(i.subtotal - i.costo), 0) AS margen_comercial
    FROM it i GROUP BY i.usuario_id
  ),
  nuevos AS (
    SELECT pp.usuario_id, COUNT(*) AS clientes_nuevos
    FROM primer_pedido pp
    WHERE pp.fecha BETWEEN v_periodo AND v_hasta
    GROUP BY pp.usuario_id
  ),
  por_marca AS (
    SELECT t.usuario_id, jsonb_agg(jsonb_build_object(
             'marca', t.marca, 'venta', t.venta, 'unidades', t.unidades
           ) ORDER BY t.venta DESC) AS detalle
    FROM (SELECT usuario_id, marca, SUM(subtotal) AS venta, SUM(cantidad) AS unidades
          FROM it GROUP BY usuario_id, marca) t
    GROUP BY t.usuario_id
  ),
  por_categoria AS (
    SELECT t.usuario_id, jsonb_agg(jsonb_build_object(
             'categoria', t.categoria, 'venta', t.venta, 'unidades', t.unidades
           ) ORDER BY t.venta DESC) AS detalle
    FROM (SELECT usuario_id, categoria, SUM(subtotal) AS venta, SUM(cantidad) AS unidades
          FROM it GROUP BY usuario_id, categoria) t
    GROUP BY t.usuario_id
  )
  SELECT jsonb_build_object(
    'periodo', v_periodo,
    'preventistas', COALESCE(jsonb_agg(jsonb_build_object(
      'preventista_id', b.usuario_id,
      'nombre', COALESCE(pf.nombre, '(sin perfil)'),
      'rol', pf.rol,
      'pedidos', b.pedidos,
      'venta', COALESCE(i.venta, 0),
      'unidades', COALESCE(i.unidades, 0),
      'margen_comercial', COALESCE(i.margen_comercial, 0),
      'cobertura', b.cobertura,
      'clientes_nuevos', COALESCE(n.clientes_nuevos, 0),
      'ticket', ROUND(COALESCE(i.venta, 0) / NULLIF(b.pedidos, 0), 2),
      'metas_cargadas', COALESCE(mt.total, 0),
      'metas', COALESCE(av.detalle -> 'metas', '[]'::jsonb),
      'resumen_metas', COALESCE(av.detalle -> 'resumen',
                                jsonb_build_object('total', 0, 'cumplidas', 0, 'en_riesgo', 0)),
      'por_marca', COALESCE(pm.detalle, '[]'::jsonb),
      'por_categoria', COALESCE(pc.detalle, '[]'::jsonb)
    ) ORDER BY COALESCE(mt.total, 0) DESC, COALESCE(i.venta, 0) DESC), '[]'::jsonb)
  ) INTO v_result
  FROM base b
  LEFT JOIN perfiles pf     ON pf.id = b.usuario_id
  LEFT JOIN items i         ON i.usuario_id = b.usuario_id
  LEFT JOIN nuevos n        ON n.usuario_id = b.usuario_id
  LEFT JOIN por_marca pm    ON pm.usuario_id = b.usuario_id
  LEFT JOIN por_categoria pc ON pc.usuario_id = b.usuario_id
  LEFT JOIN metas mt        ON mt.preventista_id = b.usuario_id
  LEFT JOIN LATERAL (
    SELECT avance_metas_preventista(b.usuario_id, v_periodo) AS detalle
    WHERE mt.total > 0
  ) av ON true;

  RETURN v_result;
END;
$function$;


-- ----------------------------------------------------------------------------
-- reporte_alerta_detalle — detalle de las alertas del gerencial. Las tres ramas
-- (cobranza vencida, clientes inactivos, productos sin costo) sin VB, igual
-- que el reporte_gerencial del que cuelgan: la suma de `productos_sin_costo`
-- ES el KPI `ingreso_sin_costo`, y el KPI no ve vales.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reporte_alerta_detalle(p_sucursal_id bigint, p_codigo text, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_incluir_no_entregados boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales bigint[];
  v_asignadas bigint[];
  v_es_servicio boolean := (auth.uid() IS NULL);
  -- Los MISMOS estados que reporte_gerencial, de la misma forma.
  v_estados text[] := CASE WHEN p_incluir_no_entregados
                           THEN ARRAY['entregado','asignado','pendiente','en_preparacion']
                           ELSE ARRAY['entregado'] END;
  v_result jsonb;
BEGIN
  IF NOT v_es_servicio THEN
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin'; END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas'; END IF;
  END IF;
  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas); END IF;
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id; END IF;
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales,1) IS NULL THEN
    RETURN '[]'::jsonb; END IF;

  IF p_codigo = 'cobranza_vencida' THEN
    -- Sin filtro de periodo a proposito: la alerta es contra CURRENT_DATE - 30.
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', nombre, 'valor', valor, 'detalle', detalle) ORDER BY valor DESC), '[]')
      INTO v_result FROM (
      SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS nombre,
             SUM(p.total - COALESCE(p.monto_pagado,0)) AS valor,
             'hace ' || MAX(CURRENT_DATE - p.fecha) || ' días' AS detalle
      FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
      WHERE p.estado='entregado' AND p.canal <> 'cambio' AND p.sucursal_id = ANY(v_sucursales)
        AND p.tipo_factura IS DISTINCT FROM 'VB'
        AND COALESCE(p.estado_pago,'pendiente') IN ('pendiente','parcial')
        AND p.fecha < CURRENT_DATE - 30 AND p.total > COALESCE(p.monto_pagado,0)
      GROUP BY c.id, c.nombre_fantasia, c.razon_social
      ORDER BY valor DESC
      LIMIT 100
    ) t;
  ELSIF p_codigo = 'clientes_inactivos' THEN
    -- Idem: la alerta es contra CURRENT_DATE - 30/90.
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', nombre, 'valor', valor, 'detalle', detalle) ORDER BY valor DESC NULLS LAST), '[]')
      INTO v_result FROM (
      SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS nombre,
             COALESCE(SUM(p.total) FILTER (WHERE p.fecha >= CURRENT_DATE - 90), 0) AS valor,
             'sin comprar hace ' || (CURRENT_DATE - MAX(p.fecha)) || ' días' AS detalle
      FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
      WHERE p.estado='entregado' AND p.canal <> 'cambio' AND p.sucursal_id = ANY(v_sucursales)
        AND p.tipo_factura IS DISTINCT FROM 'VB'
      GROUP BY c.id, c.nombre_fantasia, c.razon_social
      HAVING MAX(p.fecha) < CURRENT_DATE - 30 AND MAX(p.fecha) >= CURRENT_DATE - 90
      ORDER BY valor DESC NULLS LAST
      LIMIT 200
    ) t;
  ELSIF p_codigo = 'productos_sin_costo' THEN
    -- Mismo periodo, mismos estados, mismo canal y mismo predicado que el KPI
    -- `ingreso_sin_costo`: la suma de esta lista ES ese numero (mientras no la
    -- trunque el LIMIT, que por eso ahora ordena antes de cortar).
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', nombre, 'valor', valor, 'detalle', detalle) ORDER BY valor DESC), '[]')
      INTO v_result FROM (
      SELECT prod.nombre AS nombre, SUM(pi.subtotal) AS valor, 'sin costo cargado' AS detalle
      FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id JOIN productos prod ON prod.id = pi.producto_id
      WHERE p.estado = ANY(v_estados) AND p.canal <> 'cambio' AND p.sucursal_id = ANY(v_sucursales)
        AND p.tipo_factura IS DISTINCT FROM 'VB'
        AND (p_desde IS NULL OR p.fecha >= p_desde)
        AND (p_hasta IS NULL OR p.fecha <= p_hasta)
        AND NOT pi.es_bonificacion
        AND public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                   prod.costo_sin_iva, prod.impuestos_internos) IS NULL
      GROUP BY prod.id, prod.nombre
      ORDER BY valor DESC
      LIMIT 100
    ) t;
  ELSE
    v_result := '[]'::jsonb;
  END IF;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$function$;


-- ============================================================================
-- ENSAYO — que lo escrito sea lo que se quiso y que nada se haya abierto
-- ============================================================================
-- Hoy no hay ningún VB, así que el ensayo de comportamiento de la 241 ("antes y
-- después dan lo mismo") se cumple por vacío; lo que sí se puede chequear acá es
-- la forma: las 23 funciones nombran el filtro VB, las dos que delegan (BOT-B)
-- NO lo duplican inline, y ninguna quedó alcanzable por PUBLIC ni por anon.
DO $ensayo$
DECLARE
  v_f      record;
  v_def    text;
  v_malas  text[] := '{}';
BEGIN
  -- 1) Las reescritas nombran el filtro VB (de comprobante o de cliente).
  FOR v_f IN
    SELECT p.oid, p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN (
         'bot_digest_preventista','bot_ficha_producto','bot_historico_pedidos_cliente',
         'bot_metricas_admin_dia','bot_mis_clientes','bot_mis_ventas',
         'bot_productos_dejados_cliente','bot_productos_recurrentes_cliente',
         'bot_productos_sin_venta_con_stock','bot_ranking_preventistas_por_producto',
         'bot_resumen_cliente_visita','bot_riesgo_por_preventista','bot_stock_y_ventas',
         'bot_ventas_periodo','clientes_ritmo_compra','jornada_preventista_detalle',
         'jornada_transportista_detalle','jornadas_preventista','jornadas_transportista',
         'obtener_resumen_cuenta_cliente','obtener_resumen_cuenta_cliente_bot',
         'rendimiento_preventistas','reporte_alerta_detalle')
  LOOP
    v_def := pg_get_functiondef(v_f.oid);
    IF v_def !~ '''VB''' THEN
      v_malas := v_malas || v_f.proname::text;
    END IF;
  END LOOP;
  IF array_length(v_malas, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'ENSAYO 3XD: funciones sin el filtro VB: %', v_malas;
  END IF;

  -- 2) Las delegadas NO lo duplican (check BOT-B de auditoria_integridad).
  FOR v_f IN
    SELECT p.oid, p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('bot_ranking_clientes','bot_ventas_por_preventista','bot_clientes_atrasados')
  LOOP
    IF pg_get_functiondef(v_f.oid) ~ '''VB''' THEN
      RAISE EXCEPTION 'ENSAYO 3XD: % duplica el filtro VB inline; tiene que heredarlo de la canónica', v_f.proname;
    END IF;
  END LOOP;

  -- 3) CREATE OR REPLACE conserva los grants, pero se verifica: ninguna de las
  --    que antes eran de servidor (bot_*, clientes_ritmo_compra) quedó
  --    alcanzable con la anon key ni por PUBLIC (CLAUDE.md: gate de permisos).
  FOR v_f IN
    SELECT p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND (p.proname LIKE 'bot\_%' OR p.proname = 'clientes_ritmo_compra'
            OR p.proname IN ('jornada_preventista_detalle','jornada_transportista_detalle',
                             'jornadas_preventista','jornadas_transportista',
                             'obtener_resumen_cuenta_cliente','obtener_resumen_cuenta_cliente_bot',
                             'rendimiento_preventistas','reporte_alerta_detalle'))
       AND (has_function_privilege('anon', p.oid, 'EXECUTE')
            OR EXISTS (SELECT 1
                         FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                        WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))
  LOOP
    RAISE EXCEPTION 'ENSAYO 3XD: % es alcanzable por anon o PUBLIC', v_f.proname;
  END LOOP;
END
$ensayo$;

COMMIT;
