-- =========================================================================
-- mig 288 · SE BORRAN LAS PROMOCIONES DEL PROVEEDOR
--
-- La 284 (`284_las_promociones_del_proveedor`) creó `promociones_proveedor` y
-- `promocion_proveedor_productos` para el #908 con el enfoque "reglas
-- declaradas por proveedor" (PR #939). El dueño eligió el otro enfoque —la
-- bonificación no descontada se deduce del impuesto interno y del papel, sin
-- configurar nada por proveedor (PR #927)— y el #939 se cerró sin mergear.
-- Las dos tablas quedaron vacías y sin ningún código que las use: se borran.
--
-- Aplicada en prod el 2026-10-05 (ledger 20261005222011). Este archivo es el
-- cuerpo exacto del ledger (`supabase_migrations.schema_migrations.statements`),
-- subido después para que el repo refleje el ledger: no volver a aplicarlo.
-- =========================================================================

DO $guarda$
BEGIN
  IF EXISTS (SELECT 1 FROM public.promociones_proveedor)
     OR EXISTS (SELECT 1 FROM public.promocion_proveedor_productos) THEN
    RAISE EXCEPTION 'mig288: promociones_proveedor tiene datos; no se borra a ciegas.';
  END IF;
END
$guarda$;

DROP TABLE public.promocion_proveedor_productos;
DROP TABLE public.promociones_proveedor;
