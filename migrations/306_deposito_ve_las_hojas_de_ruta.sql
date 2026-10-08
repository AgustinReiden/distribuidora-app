-- #782 · hojas_de_ruta_deposito(): depósito ve lo que tiene que preparar, sin plata
--
-- Depósito no ve ningún pedido: `mt_pedidos_select` deja leer sólo a admin o
-- encargado, a quien lo cargó y al chofer asignado. Abrir esa policy no sirve:
-- la RLS filtra filas, no columnas, y con la fila vendrían `total`,
-- `monto_pagado`, los precios de `pedido_items` y los pagos por REST.
--
-- Por eso las policies no se tocan y depósito lee por esta RPC, que arma a mano
-- SÓLO las columnas sin plata. Decisión del dueño (2026-10-07): depósito ve las
-- hojas de ruta ARMADAS (recorridos, uno por chofer y por día, que se arman la
-- tarde anterior) con sus paradas, y aparte los pedidos que todavía no están en
-- ninguna ruta. Con productos y cantidades; ni precios, ni totales, ni saldos.
-- No mueve estados.
--
-- Qué NO devuelve, a propósito: pedidos.total / total_neto / total_iva /
-- total_real / monto_pagado / estado_pago / forma_pago; pedido_items.precio_* /
-- subtotal / neto / iva / costo / ingreso_real; recorridos.total_facturado /
-- total_cobrado; pagos; y de clientes sólo identificación y dónde entregar.
-- Si agregás una clave acá, preguntate si es plata.
--
-- Quién: depósito, admin o encargado, por ROL PRINCIPAL (`perfiles.rol`), igual
-- que el resto de las policies que nombran a depósito. No existe es_deposito()
-- y no hay que inventarlo (migs 192 y 223): el EXISTS va inline.
--
-- Fecha: sin p_fecha, la de MAÑANA si ya está armada (es la que se prepara esta
-- tarde); si no, la de HOY si hay (el sábado a la mañana, con la del lunes ya
-- armada, se carga la del sábado); si no, la próxima que haya; si no, hoy vacía.
-- Hoy en hora argentina, no UTC.
--
-- "Todavía sin ruta" es estado pendiente o en preparación, sin mirar los
-- recorridos: al rutear un pedido pasa a 'asignado', y uno no entregado vuelve a
-- 'pendiente' (marcar_no_entregado, mig 243) pero su parada QUEDA en la ruta del
-- día como registro del intento. Excluirlo por estar en un recorrido lo
-- escondería para siempre, justo cuando hay que volver a prepararlo.

CREATE OR REPLACE FUNCTION public.hojas_de_ruta_deposito(p_fecha date DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal bigint;
  v_hoy      date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_fecha    date;
  v_rutas    jsonb;
  v_sin_ruta jsonb;
  v_subrubros jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501';
  END IF;

  IF NOT (
    public.es_encargado_o_admin()
    OR EXISTS (SELECT 1 FROM public.perfiles
                WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito')
  ) THEN
    RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501';
  END IF;

  v_sucursal := public.current_sucursal_id();
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sin sucursal activa' USING ERRCODE = '42501';
  END IF;

  v_fecha := COALESCE(
    p_fecha,
    (SELECT v_hoy + 1 WHERE EXISTS (SELECT 1 FROM public.recorridos r
      WHERE r.sucursal_id = v_sucursal AND r.estado <> 'cancelado' AND r.fecha = v_hoy + 1)),
    (SELECT v_hoy WHERE EXISTS (SELECT 1 FROM public.recorridos r
      WHERE r.sucursal_id = v_sucursal AND r.estado <> 'cancelado' AND r.fecha = v_hoy)),
    (SELECT min(r.fecha) FROM public.recorridos r
      WHERE r.sucursal_id = v_sucursal AND r.estado <> 'cancelado' AND r.fecha > v_hoy),
    v_hoy
  );

  WITH
  rutas AS (
    SELECT r.id, r.estado, r.transportista_id, r.created_at
      FROM public.recorridos r
     WHERE r.sucursal_id = v_sucursal
       AND r.fecha = v_fecha
       AND r.estado <> 'cancelado'
  ),
  paradas AS (
    SELECT rp.recorrido_id, rp.orden_entrega, rp.pedido_id, rp.estado_entrega
      FROM public.recorrido_pedidos rp
      JOIN rutas ON rutas.id = rp.recorrido_id
  ),
  sin_ruta AS (
    -- Ver el encabezado: el estado alcanza, y un no entregado tiene que volver acá.
    SELECT p.id AS pedido_id
      FROM public.pedidos p
     WHERE p.sucursal_id = v_sucursal
       AND p.estado IN ('pendiente', 'en_preparacion')
  ),
  pedidos_json AS (
    SELECT p.id,
           p.created_at,
           jsonb_build_object(
             'id', p.id,
             'estado', p.estado,
             'canal', p.canal,
             'fecha', p.fecha,
             'fecha_entrega_programada', p.fecha_entrega_programada,
             'created_at', p.created_at,
             'notas', p.notas,
             'cliente', (
               SELECT jsonb_build_object(
                        'id', c.id,
                        'nombre_fantasia', c.nombre_fantasia,
                        'razon_social', c.razon_social,
                        'direccion', c.direccion,
                        'aclaracion_direccion', c.aclaracion_direccion,
                        'telefono', c.telefono,
                        'zona', c.zona,
                        'horarios_atencion', c.horarios_atencion)
                 FROM public.clientes c WHERE c.id = p.cliente_id),
             'items', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                        'id', pi.id,
                        'producto_id', pi.producto_id,
                        'cantidad', pi.cantidad,
                        'es_bonificacion', pi.es_bonificacion,
                        'descripcion_regalo', pi.descripcion_regalo,
                        'unidades_por_bloque_al_crear', pi.unidades_por_bloque_al_crear,
                        'producto', jsonb_build_object(
                          'id', pr.id,
                          'nombre', pr.nombre,
                          'codigo', pr.codigo,
                          'categoria', pr.categoria,
                          'subcategoria_id', pr.subcategoria_id,
                          'unidades_de_venta_por_fardo', pr.unidades_de_venta_por_fardo,
                          'etiqueta_bulto', pr.etiqueta_bulto),
                        'promocion', CASE WHEN pm.id IS NULL THEN NULL ELSE jsonb_build_object(
                          'unidades_por_bloque', pm.unidades_por_bloque,
                          'regalo_mueve_stock', pm.regalo_mueve_stock) END
                      ) ORDER BY pi.id)
                 FROM public.pedido_items pi
                 LEFT JOIN public.productos pr ON pr.id = pi.producto_id
                 LEFT JOIN public.promociones pm ON pm.id = pi.promocion_id
                WHERE pi.pedido_id = p.id), '[]'::jsonb),
             -- Parada de cambio: qué se retira y qué se entrega, sin valores.
             'cambio', (
               SELECT jsonb_build_object(
                        'producto_devuelto_nombre', rc.producto_devuelto_nombre,
                        'cantidad_devuelta', rc.cantidad_devuelta,
                        'producto_entregado_id', rc.producto_entregado_id,
                        'producto_entregado_nombre', rc.producto_entregado_nombre,
                        -- Rubro del producto a entregar, para que el manifiesto
                        -- lo agrupe en su góndola como el del admin.
                        'producto_entregado_categoria', pe.categoria,
                        'producto_entregado_subcategoria_id', pe.subcategoria_id,
                        'cantidad_entregada', rc.cantidad_entregada,
                        'observaciones', rc.observaciones,
                        'motivo', rc.motivo)
                 FROM public.recorrido_cambios rc
                 LEFT JOIN public.productos pe ON pe.id = rc.producto_entregado_id
                WHERE rc.pedido_id = p.id
                ORDER BY rc.id DESC LIMIT 1)
           ) AS j
      FROM public.pedidos p
     WHERE p.sucursal_id = v_sucursal
       AND p.id IN (SELECT pedido_id FROM paradas UNION SELECT pedido_id FROM sin_ruta)
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'recorrido_id', rutas.id,
               'estado', rutas.estado,
               'transportista', jsonb_build_object('id', t.id, 'nombre', t.nombre),
               'paradas', COALESCE((
                 SELECT jsonb_agg(pj.j || jsonb_build_object('orden_entrega', pa.orden_entrega,
                                                             'estado_entrega', pa.estado_entrega)
                                  ORDER BY pa.orden_entrega NULLS LAST, pa.pedido_id)
                   FROM paradas pa JOIN pedidos_json pj ON pj.id = pa.pedido_id
                  WHERE pa.recorrido_id = rutas.id), '[]'::jsonb)
             ) ORDER BY t.nombre, rutas.created_at)
        FROM rutas LEFT JOIN public.perfiles t ON t.id = rutas.transportista_id), '[]'::jsonb),
    COALESCE((
      SELECT jsonb_agg(pj.j ORDER BY pj.created_at)
        FROM pedidos_json pj WHERE pj.id IN (SELECT pedido_id FROM sin_ruta)), '[]'::jsonb)
  INTO v_rutas, v_sin_ruta;

  -- Nombre de los subrubros, para que el manifiesto agrupe rubro -> subrubro
  -- sin que depósito tenga que leer otra tabla.
  SELECT COALESCE(jsonb_object_agg(cat.id::text, cat.nombre), '{}'::jsonb)
    INTO v_subrubros
    FROM public.categorias cat
   WHERE cat.sucursal_id = v_sucursal AND cat.parent_id IS NOT NULL;

  RETURN jsonb_build_object(
    'fecha', v_fecha,
    'rutas', v_rutas,
    'sin_ruta', v_sin_ruta,
    'subrubros', v_subrubros
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.hojas_de_ruta_deposito(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hojas_de_ruta_deposito(date) TO authenticated;

DO $verif$
BEGIN
  IF has_function_privilege('anon', 'public.hojas_de_ruta_deposito(date)', 'EXECUTE') THEN
    RAISE EXCEPTION '#782 · anon puede ejecutar hojas_de_ruta_deposito';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.hojas_de_ruta_deposito(date)', 'EXECUTE') THEN
    RAISE EXCEPTION '#782 · authenticated no puede ejecutar hojas_de_ruta_deposito';
  END IF;
END
$verif$;
