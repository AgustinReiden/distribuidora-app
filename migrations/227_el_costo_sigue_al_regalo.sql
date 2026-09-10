-- =========================================================================
-- Tres bugs de costeo de regalos
--
-- #537 la sustitucion de un regalo queda costeada con el producto ORIGINAL
-- #538 anular_salvedad devuelve el regalo como linea de venta a precio 0
-- #539 la mercaderia 100% bonificada no diluye el costo promedio
--
-- LAS TRES SON FORWARD-ONLY. Ninguna toca una fila existente, asi que el
-- reporte de los meses cerrados NO se mueve un peso. Eso es a proposito y es
-- lo que se verifico: foto de reporte_gerencial mes a mes antes y despues.
-- El detalle de lo que queda pendiente de decidir esta al final del encabezado.
--
-- =========================================================================
-- #537 · EL COSTO DE UNA SUSTITUCION
-- =========================================================================
-- La RPC `sustituir_regalo_pedido` YA reescribe costo_unitario_al_crear al
-- sustituir (lo hace desde la mig 117). El agujero esta en el OTRO camino: el
-- trigger `aplicar_sustituciones_regalo_pre_insert` (mig 061) reaplica la
-- sustitucion cuando `actualizar_pedido_items` borra y reinserta los items al
-- editar un pedido, y ahi pisa NEW.producto_id sin recalcular el costo. La
-- linea queda con las unidades de un producto y el costo de otro.
--
-- Se arregla DENTRO del trigger, que es el unico lugar donde se sabe que el
-- producto cambio. Un calculo previo al insert volveria a quedar desalineado,
-- porque el trigger corre despues.
--
-- La cascada es la canonica del proyecto, la misma que usa reporte_gerencial
-- para elegir el costo: costo_promedio -> costo_real -> costo_sin_iva * (1+ii).
-- (`sustituir_regalo_pedido` usa solo costo_real, que es una version mas pobre
-- de lo mismo; no se toca acá porque no es lo que rompe.)
--
-- =========================================================================
-- #538 · EL REGALO QUE VUELVE COMO VENTA
-- =========================================================================
-- `anular_salvedad` reinserta el item sin `es_bonificacion` y sin
-- `promocion_id`, asi que un regalo vuelve como linea de venta a precio 0:
-- deja de contar en unidades_bonif y costo_bonif, empieza a contar como venta
-- con costo, y pierde el vinculo con la promo.
--
-- No alcanzaba con agregar las dos columnas al INSERT: `salvedades_items` NO
-- las guarda, y el item original ya fue borrado, asi que en el momento de
-- anular no hay de donde leerlas. Por eso van las dos a la tabla, las escribe
-- `registrar_salvedad` (que YA las tiene cargadas en v_item, solo no las
-- guardaba) y las restituye `anular_salvedad`.
--
-- La FK de promocion_id es COMPUESTA con sucursal_id y ON DELETE SET NULL,
-- igual que `pedido_items_promocion_id_fkey`: sin eso, borrar una promo dejaria
-- un id colgado que despues haria fallar la reinsercion.
--
-- NUNCA SE ANULO UNA SALVEDAD: las 241 de prod estan en 'pendiente'. El
-- arreglo es preventivo y no mueve ningun numero.
--
-- =========================================================================
-- #539 · LA MERCADERIA REGALADA NO DILUIA EL PROMEDIO
-- =========================================================================
-- Con bonificacion 100% (o costo neto 0) `registrar_compra_completa` sumaba el
-- stock y salteaba el promedio entero. Son unidades que entraron a costo 0 y
-- tienen que bajar el promedio ponderado.
--
-- Se toca SOLO `costo_promedio`. `costo_real`, `costo_sin_iva` y `costo_con_iva`
-- siguen sin moverse en esa rama, y esta bien: son costo de REPOSICION, y una
-- entrega gratis no cambia a cuanto se repone.
--
-- EL ESPEJO DE CI NO ENTRA ACA. `scripts/espejo-motor-compras.mjs` compara
-- `src/utils/prorrateoCompra.ts` contra `prorratear_cargo` /
-- `calcular_costos_compra` (mig 193), que son el motor de PRORRATEO DE CARGOS.
-- Verificado: ninguna de las tres menciona `costo_promedio`, que se calcula
-- inline en registrar_compra_completa y no tiene segunda implementacion. El
-- gate queda verde y no hay otro lado que tocar.
--
-- CERO COMPRAS ASI EN PROD. Forward-only por la politica de las migs 127/128:
-- no se recalcula el promedio historico.
--
-- LO QUE QUEDA SIN DECIDIR, A PROPOSITO
-- -------------------------------------
-- 1. Un producto SIN promedio previo (stock_anterior <= 0 o costo_promedio
--    nulo/cero) que recibe solo mercaderia gratis: la aritmetica pura diria
--    promedio 0, y con eso su CMV seria 0 para siempre hasta la proxima compra
--    paga. No hay un solo caso en prod para calibrar esa decision, asi que se
--    deja el comportamiento actual -- no tocar el promedio -- y se diluye solo
--    cuando HAY un promedio previo que diluir. Diluir es mezclar; fijar en cero
--    desde la nada es otra decision.
-- 2. Las 4 lineas historicas del #537 con costo congelado del producto
--    original. No se backfillean: no hay fuente para "el costo del sustituto en
--    el momento de la sustitucion" y no se inventa un numero. Mismo criterio
--    que los 70 items que la mig 212 dejo en NULL.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1 · #537 — el trigger recalcula el costo cuando cambia el producto.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.aplicar_sustituciones_regalo_pre_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sust RECORD;
  v_nombre_sustituto TEXT;
  v_costo_sustituto NUMERIC;
BEGIN
  IF NOT COALESCE(NEW.es_bonificacion, FALSE) THEN
    RETURN NEW;
  END IF;
  IF NEW.promocion_id IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT producto_sustituto_id, cantidad_sustituta, ajuste_producto_id_nuevo
    INTO v_sust
    FROM pedido_item_sustituciones
   WHERE pedido_id = NEW.pedido_id
     AND promocion_id = NEW.promocion_id
     AND producto_original_id = NEW.producto_id
     AND sucursal_id = NEW.sucursal_id
   ORDER BY created_at DESC
   LIMIT 1;
  IF FOUND THEN
    IF COALESCE(NEW.descripcion_regalo, '') NOT LIKE '%[Sustituido por:%' THEN
      SELECT nombre INTO v_nombre_sustituto
        FROM productos
       WHERE id = v_sust.producto_sustituto_id
         AND sucursal_id = NEW.sucursal_id;
      NEW.descripcion_regalo := COALESCE(NEW.descripcion_regalo, '') ||
                                ' [Sustituido por: ' || COALESCE(v_nombre_sustituto, '?') || ']';
    END IF;
    NEW.producto_id := v_sust.producto_sustituto_id;

    -- El costo tiene que seguir al producto (issue #537). Quien llamo al INSERT
    -- snapshoteo el costo del producto ORIGINAL, que a partir de esta linea ya
    -- no es el de la fila. Misma cascada que usa reporte_gerencial para elegir
    -- el costo de una linea.
    SELECT COALESCE(costo_promedio, costo_real,
                    CASE WHEN costo_sin_iva IS NULL THEN NULL
                         ELSE round(costo_sin_iva * (1 + COALESCE(impuestos_internos, 0) / 100), 4) END)
      INTO v_costo_sustituto
      FROM productos
     WHERE id = v_sust.producto_sustituto_id
       AND sucursal_id = NEW.sucursal_id;

    -- Si el sustituto no tiene ningun costo cargado, dejar NULL antes que
    -- dejar el del original: NULL hace que el reporte caiga al costo vivo del
    -- producto correcto, y un numero equivocado no.
    NEW.costo_unitario_al_crear := v_costo_sustituto;
  END IF;
  RETURN NEW;
END;
$function$;

ALTER FUNCTION public.aplicar_sustituciones_regalo_pre_insert() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.aplicar_sustituciones_regalo_pre_insert() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.aplicar_sustituciones_regalo_pre_insert() IS
  'Reaplica una sustitucion de regalo cuando el item se reinserta (edicion de '
  'pedido). Mueve producto_id Y el costo congelado juntos: si se mueve uno solo, '
  'la linea queda con las unidades de un producto y el costo de otro (issue #537).';

-- -------------------------------------------------------------------------
-- 2 · #538 — la salvedad se acuerda de que la linea era un regalo.
-- -------------------------------------------------------------------------
ALTER TABLE public.salvedades_items
  ADD COLUMN IF NOT EXISTS es_bonificacion BOOLEAN,
  ADD COLUMN IF NOT EXISTS promocion_id    BIGINT;

DO $fk$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'salvedades_items_promocion_id_fkey') THEN
    -- Compuesta con sucursal_id, como pedido_items_promocion_id_fkey: dejarla
    -- simple romperia el aislamiento por sucursal sin fallar en nada visible.
    ALTER TABLE public.salvedades_items
      ADD CONSTRAINT salvedades_items_promocion_id_fkey
      FOREIGN KEY (promocion_id, sucursal_id)
      REFERENCES public.promociones(id, sucursal_id) ON DELETE SET NULL;
  END IF;
END
$fk$;

COMMENT ON COLUMN public.salvedades_items.es_bonificacion IS
  'Si la linea afectada era un regalo. Lo necesita anular_salvedad para '
  'reinsertarla como regalo y no como venta a precio 0 (issue #538). NULL en '
  'las salvedades anteriores a la mig que agrego la columna.';
COMMENT ON COLUMN public.salvedades_items.promocion_id IS
  'La promo de la linea afectada, para poder restituir el vinculo al anular '
  '(issue #538). NULL en las salvedades viejas.';

-- Backfill de lo que todavia se puede leer: las salvedades cuyo item sigue
-- existiendo. Las que ya no lo tienen quedan en NULL, que es exactamente el
-- comportamiento de hoy y no empeora nada.
UPDATE public.salvedades_items s
   SET es_bonificacion = COALESCE(pi.es_bonificacion, FALSE),
       promocion_id    = pi.promocion_id
  FROM public.pedido_items pi
 WHERE pi.id = s.pedido_item_id
   AND pi.sucursal_id = s.sucursal_id
   AND s.es_bonificacion IS NULL;

-- Parche por ancla sobre el cuerpo VIVO. migrations/ no es espejo: estas dos
-- funciones vienen parchadas por varias migraciones y un CREATE OR REPLACE
-- armado desde el archivo del repo borraria esos parches en silencio.
CREATE OR REPLACE FUNCTION public._mig_costeo_reemplazar_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano.',
      v_veces, p_funcion;
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- 2.a) registrar_salvedad guarda las dos columnas nuevas.
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='registrar_salvedad';

  PERFORM public._mig_costeo_reemplazar_ancla(v_fn,
    E'    reportado_por, stock_devuelto, stock_devuelto_at, estado_resolucion, sucursal_id,\n'
    || E'    client_request_id\n'
    || E'  ) VALUES (\n',
    E'    reportado_por, stock_devuelto, stock_devuelto_at, estado_resolucion, sucursal_id,\n'
    || E'    client_request_id, es_bonificacion, promocion_id\n'
    || E'  ) VALUES (\n');

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='registrar_salvedad';

  PERFORM public._mig_costeo_reemplazar_ancla(v_fn,
    E'    p_client_request_id\n'
    || E'  ) RETURNING id INTO v_salvedad_id;\n',
    E'    p_client_request_id, v_item.es_bonificacion, v_item.promocion_id\n'
    || E'  ) RETURNING id INTO v_salvedad_id;\n');
END
$patch$;

-- 2.b) anular_salvedad las restituye.
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='anular_salvedad';

  PERFORM public._mig_costeo_reemplazar_ancla(v_fn,
    E'      ingreso_real_unitario, costo_unitario_al_crear\n'
    || E'    )\n',
    E'      ingreso_real_unitario, costo_unitario_al_crear,\n'
    || E'      es_bonificacion, promocion_id\n'
    || E'    )\n');

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='anular_salvedad';

  -- Un regalo tiene que volver COMO regalo: si no, deja de contar en
  -- unidades_bonif / costo_bonif y empieza a contar como venta con costo, y el
  -- margen sale mal de los dos lados (issue #538).
  PERFORM public._mig_costeo_reemplazar_ancla(v_fn,
    E'      COALESCE(v_costo_prom, v_costo_real,\n'
    || E'        CASE WHEN v_costo_sin IS NULL THEN NULL ELSE round(v_costo_sin * (1 + v_pct_ii / 100), 4) END)\n'
    || E'    );\n',
    E'      COALESCE(v_costo_prom, v_costo_real,\n'
    || E'        CASE WHEN v_costo_sin IS NULL THEN NULL ELSE round(v_costo_sin * (1 + v_pct_ii / 100), 4) END),\n'
    || E'      COALESCE(v_salvedad.es_bonificacion, FALSE), v_salvedad.promocion_id\n'
    || E'    );\n');
END
$patch$;

-- -------------------------------------------------------------------------
-- 3 · #539 — la mercaderia gratis diluye el promedio.
--
--     Parche por ancla: registrar_compra_completa viene parchada in situ por
--     las migs 177, 193, 194 y 195 con cirugia de string sobre
--     pg_get_functiondef. Reescribirla entera desde el repo las borraria.
-- -------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='registrar_compra_completa';

  PERFORM public._mig_costeo_reemplazar_ancla(v_fn,
    E'    ELSE\n'
    || E'      v_costo_promedio := v_producto.costo_promedio;\n'
    || E'      UPDATE productos\n'
    || E'         SET stock      = stock + v_cantidad,\n'
    || E'             updated_at = NOW()\n'
    || E'       WHERE id = (v_item->>''producto_id'')::BIGINT\n'
    || E'         AND sucursal_id = v_sucursal;\n'
    || E'    END IF;\n',
    E'    ELSE\n'
    || E'      /* mig #539 · la mercaderia gratis SI diluye el promedio: son unidades\n'
    || E'         que entraron a costo 0. Solo el promedio -- costo_real, costo_sin_iva\n'
    || E'         y costo_con_iva son costo de REPOSICION y una entrega gratis no\n'
    || E'         cambia a cuanto se repone.\n'
    || E'         Se diluye solo si HAY un promedio previo que diluir: fijar cero desde\n'
    || E'         la nada es otra decision y no hay un solo caso en prod para calibrarla. */\n'
    || E'      IF v_stock_anterior > 0 AND COALESCE(v_producto.costo_promedio, 0) > 0 THEN\n'
    || E'        v_costo_promedio := round(\n'
    || E'          (v_stock_anterior::NUMERIC * v_producto.costo_promedio)\n'
    || E'          / (v_stock_anterior + v_cantidad), 4);\n'
    || E'      ELSE\n'
    || E'        v_costo_promedio := v_producto.costo_promedio;\n'
    || E'      END IF;\n'
    || E'      UPDATE productos\n'
    || E'         SET stock          = stock + v_cantidad,\n'
    || E'             costo_promedio = v_costo_promedio,\n'
    || E'             updated_at     = NOW()\n'
    || E'       WHERE id = (v_item->>''producto_id'')::BIGINT\n'
    || E'         AND sucursal_id = v_sucursal;\n'
    || E'    END IF;\n');
END
$patch$;

DROP FUNCTION public._mig_costeo_reemplazar_ancla(regprocedure, text, text);

-- -------------------------------------------------------------------------
-- 4 · Verificacion.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def  text;
  v_cols int;
  v_acl  text;
  v_n    int;
BEGIN
  -- #537
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace
     AND p.proname='aplicar_sustituciones_regalo_pre_insert';
  IF v_def NOT LIKE '%NEW.costo_unitario_al_crear%' THEN
    RAISE EXCEPTION '#537: el trigger sigue sin mover el costo.';
  END IF;
  IF position('NEW.producto_id := ' in v_def) > position('NEW.costo_unitario_al_crear' in v_def) THEN
    RAISE EXCEPTION '#537: el costo se calcula antes de cambiar el producto.';
  END IF;

  -- #538 · columnas, FK compuesta y las dos funciones
  SELECT count(*) INTO v_cols FROM information_schema.columns
   WHERE table_schema='public' AND table_name='salvedades_items'
     AND column_name IN ('es_bonificacion','promocion_id');
  IF v_cols <> 2 THEN RAISE EXCEPTION '#538: faltan columnas en salvedades_items (hay %).', v_cols; END IF;

  SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint
   WHERE conname='salvedades_items_promocion_id_fkey';
  IF v_def IS NULL OR v_def NOT LIKE '%(promocion_id, sucursal_id)%' THEN
    RAISE EXCEPTION '#538: la FK no quedo compuesta con sucursal_id: %', COALESCE(v_def,'(no existe)');
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='registrar_salvedad';
  IF v_def NOT LIKE '%v_item.es_bonificacion, v_item.promocion_id%' THEN
    RAISE EXCEPTION '#538: registrar_salvedad no guarda las columnas nuevas.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='anular_salvedad';
  IF v_def NOT LIKE '%v_salvedad.es_bonificacion%' THEN
    RAISE EXCEPTION '#538: anular_salvedad no restituye es_bonificacion.';
  END IF;

  -- #539 · la rama gratis ahora escribe costo_promedio, y el motor espejado
  -- sigue sin saber nada de promedios.
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='registrar_compra_completa';
  IF v_def NOT LIKE '%costo_promedio = v_costo_promedio,%' THEN
    RAISE EXCEPTION '#539: la rama gratis sigue sin diluir el promedio.';
  END IF;
  IF (length(v_def) - length(replace(v_def, 'SET stock          = stock + v_cantidad,', '')))
     / length('SET stock          = stock + v_cantidad,') <> 1 THEN
    RAISE EXCEPTION '#539: el parche no entro una sola vez.';
  END IF;

  SELECT count(*) INTO v_n FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace
     AND p.proname IN ('prorratear_cargo','calcular_costos_compra','espejo_motor_compras')
     AND pg_get_functiondef(p.oid) LIKE '%costo_promedio%';
  IF v_n > 0 THEN
    RAISE EXCEPTION '#539: el motor espejado empezo a tocar costo_promedio; hay que tocar el TS tambien.';
  END IF;

  -- Una sola sobrecarga de cada funcion tocada: dos con rangos superpuestos dan
  -- PGRST203 en runtime, invisible para tsc y para los tests.
  FOR v_def IN SELECT unnest(ARRAY['registrar_salvedad','anular_salvedad',
                                   'registrar_compra_completa',
                                   'aplicar_sustituciones_regalo_pre_insert'])
  LOOP
    SELECT count(*) INTO v_n FROM pg_proc p
     WHERE p.pronamespace='public'::regnamespace AND p.proname = v_def;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'Hay % sobrecargas de %.', v_n, v_def;
    END IF;
  END LOOP;

  -- El helper de trigger no necesita EXECUTE para nadie.
  SELECT array_to_string(array_agg(a::text), ' ') INTO v_acl
  FROM pg_proc p, unnest(p.proacl) a
  WHERE p.pronamespace='public'::regnamespace
    AND p.proname='aplicar_sustituciones_regalo_pre_insert'
    AND (a::text LIKE '=%' OR a::text LIKE 'anon=%' OR a::text LIKE 'authenticated=%');
  IF v_acl IS NOT NULL THEN
    RAISE EXCEPTION 'El trigger quedo ejecutable de mas (%).', v_acl;
  END IF;

  RAISE NOTICE 'OK: los tres bugs de costeo de regalos, arreglados forward-only.';
END
$verif$;

COMMIT;
