-- 409 · sincronizar_lotes_compra bloquea los productos antes que los lotes (#1255).
--
-- La 402 le dio a _clampear_lotes_a_stock el FOR UPDATE del producto (sin él,
-- una venta sin commitear le dejaba leer el stock de antes y el recorte se
-- quedaba corto). Su único llamador, sincronizar_lotes_compra, bloqueaba
-- compra → salvedades → TODOS los lotes de la compra y recién al final llamaba
-- a _clampear: el producto se pedía con los lotes ya tomados (lote → producto),
-- al revés que la venta, que bloquea el producto y deja que el trigger baje
-- después a sus lotes por FEFO. Con la bolsa en 0, una edición de compra y una
-- venta del mismo producto cerraban el ciclo (40P01).
--
-- Ahora, entre las salvedades y los lotes, bloquea los productos de la compra
-- (los de sus lotes y los del payload) en orden de id. El orden queda compra →
-- salvedades → productos → lotes: el de anular_salvedad (salvedad → producto
-- → lote) y el de la venta. El FOR UPDATE de _clampear pasa a ser un re-lock.
--
-- Es un parche por ancla sobre el cuerpo VIVO, no una copia de la función: si
-- el ancla no aparece exactamente una vez (la función cambió), no aplica nada.
-- El resto del cuerpo queda idéntico.
--
-- Ensayo: scripts/test-stock-integridad-1254-1255-1256.sql (sección 3 · E).

DO $parche$
DECLARE
  v_def   text := pg_get_functiondef('public.sincronizar_lotes_compra(bigint,jsonb)'::regprocedure);
  v_ancla text := $ancla$  PERFORM 1 FROM public.producto_lotes
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
     FOR UPDATE;$ancla$;
  v_lock  text := $lock$  -- #1255 · los productos de la compra (los de sus lotes y los del payload),
  -- en orden de id, ANTES que sus lotes: el orden de la venta, que bloquea el
  -- producto y deja que el trigger baje después a los lotes. Al final
  -- _clampear_lotes_a_stock bloquea el producto (402): sin esto lo pedía con
  -- los lotes de la compra ya tomados y, contra una venta con la bolsa en 0,
  -- cerraba el ciclo (40P01). El producto de un lote no cambia nunca.
  PERFORM 1
     FROM public.productos
    WHERE sucursal_id = v_sucursal
      AND id IN (SELECT producto_id FROM public.producto_lotes
                  WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
                 UNION
                 SELECT (e->>'producto_id')::bigint
                   FROM jsonb_array_elements(COALESCE(p_lotes, '[]'::jsonb)) e)
    ORDER BY id
      FOR UPDATE;

$lock$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla) <> 1 THEN
    RAISE EXCEPTION 'sincronizar_lotes_compra cambió: el ancla del lock de lotes no aparece exactamente una vez';
  END IF;
  IF position('FROM public.productos' IN v_def) > 0
     AND position('ORDER BY id' IN v_def) > 0
     AND position('#1255' IN v_def) > 0 THEN
    RAISE EXCEPTION 'sincronizar_lotes_compra ya tiene el lock de productos de #1255';
  END IF;
  EXECUTE replace(v_def, v_ancla, v_lock || v_ancla);
END
$parche$;
