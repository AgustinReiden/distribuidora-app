-- #1003 (2/2) · pedido_items: el costo de la venta ya no se lee por REST
--
-- `pedido_items.costo_unitario_al_crear` es el snapshot de `costo_valuacion` al
-- vender (migs 257/258). `mt_pedido_items_select` deja leer los ítems de sus
-- pedidos al preventista y los de sus pedidos asignados al transportista, y
-- `authenticated` tenía SELECT sobre la tabla entera: el costo de cada venta les
-- llegaba al navegador con `pedido_items(*)` —y al transportista, además, a la
-- caché de la ruta en localStorage—. Con eso se reconstruyen los costos de
-- productos que #974 cerró.
--
-- Mismo molde que la mig 310 (#974): con un GRANT de tabla vigente, un
-- `REVOKE SELECT (col)` no tiene efecto, así que se revoca el SELECT de la tabla
-- y se concede columna por columna todo lo demás. Los precios de venta (precio,
-- neto, IVA, II, ingreso real, precio de lista, descuento) siguen visibles: los
-- ve quien vende y quien cobra.
--
-- Consecuencias que hay que saber:
--   * Una columna NUEVA de pedido_items nace sin SELECT para authenticated: su
--     migración la concede y `src/lib/pedidoItemColumnas.ts` la suma (su test
--     compara la lista contra este GRANT).
--   * Un `*` sobre pedido_items por PostgREST —`pedido_items(*)` en un embed, un
--     `select('*')`— falla la consulta ENTERA, para todos los roles. El front
--     pide `PEDIDO_ITEM_COLUMNAS`.
--   * Las RPCs SECURITY DEFINER (crear y editar pedidos, reportes, el bot) leen
--     como su dueño: no las afecta. El trigger `pedido_items_proteger_columnas`
--     lee NEW, que no pasa por permisos de columna. service_role no se toca.
--   * Quien sí necesita el costo —admin y encargado: el export a BI, el backup—
--     lo pide a `costos_pedido_items()`, que creó la mitad 1/2 (mig 316).
--
-- ORDEN: esta mitad va DESPUÉS de desplegar el front que pide
-- `PEDIDO_ITEM_COLUMNAS` (y de que las PWA abiertas lo tomen). Con el front
-- viejo, su `pedido_items(*)` falla para todos los roles: pedidos, la ruta del
-- chofer, la ficha del cliente y el dashboard.

REVOKE SELECT ON public.pedido_items FROM authenticated, anon;

GRANT SELECT (id, pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id, neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, sucursal_id, tp_import_id, descripcion_regalo, stock_al_crear, ingreso_real_unitario, precio_lista_al_crear, origen_precio, descuento_pct, grupo_precio_escala_id, unidades_por_bloque_al_crear, origen_unidades_por_bloque)
  ON public.pedido_items TO authenticated;

GRANT SELECT (id, pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id, neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, sucursal_id, tp_import_id, descripcion_regalo, stock_al_crear, ingreso_real_unitario, precio_lista_al_crear, origen_precio, descuento_pct, grupo_precio_escala_id, unidades_por_bloque_al_crear, origen_unidades_por_bloque)
  ON public.pedido_items TO anon;

-- Verificación

DO $verif$
DECLARE
  v_falta text;
BEGIN
  IF has_column_privilege('authenticated', 'public.pedido_items', 'costo_unitario_al_crear', 'SELECT')
     OR has_column_privilege('anon', 'public.pedido_items', 'costo_unitario_al_crear', 'SELECT') THEN
    RAISE EXCEPTION '#1003 · authenticated/anon siguen leyendo pedido_items.costo_unitario_al_crear';
  END IF;

  SELECT string_agg(column_name, ', ') INTO v_falta
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'pedido_items'
     AND column_name <> 'costo_unitario_al_crear'
     AND NOT has_column_privilege('authenticated', 'public.pedido_items', column_name, 'SELECT');
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION '#1003 · authenticated quedó sin SELECT sobre pedido_items.%', v_falta;
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.costos_pedido_items(bigint[])', 'EXECUTE') THEN
    RAISE EXCEPTION '#1003 · falta la mitad 1/2: authenticated no ejecuta costos_pedido_items';
  END IF;
END
$verif$;
