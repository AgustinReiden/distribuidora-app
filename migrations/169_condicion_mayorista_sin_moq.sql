-- =========================================================================
-- 169_condicion_mayorista_sin_moq.sql
--
-- "Movimos condiciones mayoristas a la ficha del producto y ahí estaban los
--  mínimos de venta, que ahora se repiten en la ficha misma."
--
-- Desde la mig 147 el mínimo de venta vive en productos.cantidad_minima_venta,
-- se valida en la base (trigger validar_minimo_venta_item) y aplica al producto
-- exista o no una condición mayorista. El MOQ viejo
-- (grupo_precio_productos.cantidad_minima_pedido) quedó conviviendo con él:
--   · nunca se usó en prod (0 filas con valor, verificado 2026-08-06);
--   · solo se validaba en el navegador;
--   · y desde que la ficha muestra las condiciones, el dueño veía DOS mínimos
--     para el mismo producto, uno editable y otro no.
--
-- La 147 decía "el MOQ de grupo sigue existiendo; en el front gana el mayor de
-- los dos". Esta migración termina esa transición: queda uno solo.
--
-- ⚠️ ORDEN DE APLICACIÓN: aplicar DESPUÉS de desplegar las edge functions.
-- supabase/functions/_shared/pricing/index.ts seleccionaba la columna por
-- nombre y PostgREST devuelve 400 si no existe, lo que dejaría al bot sin
-- poder tomar pedidos.
--
-- Rollback: con 0 filas con valor, revertir es
--   ALTER TABLE grupo_precio_productos ADD COLUMN cantidad_minima_pedido integer;
--   ALTER TABLE grupo_precio_productos ADD CONSTRAINT chk_cantidad_minima_pedido_positiva
--     CHECK (cantidad_minima_pedido IS NULL OR cantidad_minima_pedido > 0);
-- =========================================================================

DO $$
DECLARE
  v_con_valor integer;
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'grupo_precio_productos'
       AND column_name  = 'cantidad_minima_pedido'
  ) THEN

    SELECT count(*) INTO v_con_valor
      FROM public.grupo_precio_productos
     WHERE cantidad_minima_pedido IS NOT NULL;

    -- Guarda: si alguien cargó un valor entre el análisis y la aplicación, se
    -- preserva en el mínimo del producto en vez de perderse en silencio.
    -- GREATEST porque el criterio del front era "gana el más restrictivo".
    IF v_con_valor > 0 THEN
      UPDATE public.productos p
         SET cantidad_minima_venta = GREATEST(COALESCE(p.cantidad_minima_venta, 0), sub.moq)
        FROM (
          SELECT producto_id, max(cantidad_minima_pedido) AS moq
            FROM public.grupo_precio_productos
           WHERE cantidad_minima_pedido IS NOT NULL
           GROUP BY producto_id
        ) sub
       WHERE p.id = sub.producto_id;

      RAISE NOTICE 'Backfilleadas % filas de cantidad_minima_pedido a productos.cantidad_minima_venta', v_con_valor;
    END IF;

    ALTER TABLE public.grupo_precio_productos
      DROP CONSTRAINT IF EXISTS chk_cantidad_minima_pedido_positiva;

    ALTER TABLE public.grupo_precio_productos
      DROP COLUMN cantidad_minima_pedido;
  END IF;
END $$;

COMMENT ON TABLE public.grupo_precio_productos IS
  'Productos que comparten una condición mayorista. Cualquier mezcla de ellos suma para llegar al mínimo de la escala. El mínimo de venta NO vive acá: vive en productos.cantidad_minima_venta (mig 147/169).';

-- Nota: en prod hay 3 condiciones sin productos (ids 3, 23 y 24). No aplican
-- precio a nadie, pero NO se tocan acá: esta migración solo elimina la columna
-- duplicada. Desactivarlas es una decisión de negocio y se hace desde la UI.
