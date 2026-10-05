-- =========================================================================
-- mig 288 · SE BORRAN LAS PROMOCIONES DEL PROVEEDOR
--
-- La 284 (`284_las_promociones_del_proveedor`) creo `promociones_proveedor` y
-- `promocion_proveedor_productos` para que el modal de compra sugiriera la
-- bonificacion no descontada (#908) comparando contra una promo declarada por
-- proveedor. Ese PR (#939) se cerro sin mergear: #908 lo resolvio #927, que
-- detecta la bonificacion por el impuesto interno sin configuracion por
-- proveedor. Ningun codigo lee ni escribe estas tablas.
--
-- Se borran para no dejar un lugar donde "declarar promos" que nada consulta:
-- una promo cargada ahi no tendria ningun efecto y nadie se enteraria. El
-- archivo de la 284 queda en el repo porque esta en el ledger.
--
-- Guarda: si alguien llego a cargar una fila, la migracion falla en vez de
-- borrarla en silencio.
-- =========================================================================

BEGIN;

DO $guarda$
BEGIN
  IF EXISTS (SELECT 1 FROM public.promociones_proveedor)
     OR EXISTS (SELECT 1 FROM public.promocion_proveedor_productos) THEN
    RAISE EXCEPTION 'mig288: promociones_proveedor tiene datos; no se borra a ciegas.';
  END IF;
END
$guarda$;

-- Las policies, indices y FKs se van con las tablas. El alcance primero: su
-- FK compuesta apunta a la promo.
DROP TABLE public.promocion_proveedor_productos;
DROP TABLE public.promociones_proveedor;

COMMIT;
