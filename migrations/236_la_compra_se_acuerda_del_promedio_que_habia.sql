-- =========================================================================
-- mig 236 · LA COMPRA SE ACUERDA DEL PROMEDIO QUE HABIA
--
-- Cinco agujeros de la cadena de RPCs de compras. Los cinco son forward-only:
-- ninguno toca una fila existente, asi que el reporte de los meses cerrados no
-- se mueve un peso.
--
-- PARCHE POR ANCLA, NO CREATE OR REPLACE DESDE EL REPO. Las cuatro RPCs vienen
-- parchadas in situ por la cadena 000 -> 046 -> 048 -> 104 -> 111 -> 114 ->
-- 115 -> 125 -> 126 -> 127 -> 128 -> 177 -> 178 -> 192..196 -> 224 -> 227.
-- `migrations/` es una vista curada, no un espejo: armar un cuerpo entero
-- desde el archivo del repo borraria esos parches en silencio. Los helpers de
-- abajo leen `pg_get_functiondef` y fallan si el ancla no aparece exactamente
-- una vez.
--
-- =========================================================================
-- 1 · EL CPP SE RE-DERIVA DESDE EL PROMEDIO QUE YA INCLUYE LA COMPRA
-- =========================================================================
-- `actualizar_compra_items` (mig 128) arma la base del promedio con dos
-- numeros que no son de la misma foto:
--
--   · `v_cpp_map` = `productos.costo_promedio` leido tal cual, o sea el
--     promedio DESPUES de esta compra;
--   · `v_stock_previo_map` = `productos.stock` MENOS las unidades de esta
--     compra, o sea el stock ANTES.
--
-- Mezclarlos corre el promedio hacia el costo de la factura en CADA edicion,
-- aunque no se toque ni una cantidad ni un costo. Medido en prod, en una
-- transaccion revertida: un producto con 100 u. a CPP 10 que recibe una compra
-- de 100 u. a 20 queda en 15 al registrar, y una edicion SIN UN SOLO CAMBIO lo
-- deja en 17,50. Otra edicion lo dejaria en 18,75. `reporte_gerencial` y
-- `reporte_valuacion_inventario` leen `costo_promedio`: el CMV se va para
-- arriba cada vez que alguien corrige el numero de factura.
--
-- El promedio previo NO se puede reconstruir despues (el vivo ya lo incluye),
-- asi que se GUARDA cuando todavia se sabe:
-- `compra_items.costo_promedio_anterior`, analoga a `stock_anterior`, escrita
-- por las dos RPCs.
--
-- Las compras ya cargadas no tienen ese dato. Para esas la edicion NO toca el
-- promedio y devuelve `warning_costo_promedio` con `motivo = 'sin_cpp_previo'`:
-- avisar es mejor que mover el numero para el lado equivocado.
--
-- =========================================================================
-- 2 · UNA FACTURA TRASPAPELADA PISA EL COSTO DE REPOSICION
-- =========================================================================
-- `registrar_compra_completa` escribe `costo_sin_iva` / `costo_con_iva` /
-- `costo_real` / `ultimo_tipo_compra` sin mirar si hay una compra POSTERIOR.
-- Una factura de hace tres semanas cargada con su fecha real devuelve el costo
-- de reposicion a esa fecha, y de ahi salen los precios de venta.
--
-- `actualizar_compra_items` ya lo resuelve desde la 128 con `v_es_mas_reciente`.
-- Se porta el mismo criterio al alta: el stock y el promedio suman igual —la
-- mercaderia entro y las unidades pesan—, el costo de REPOSICION no se pisa, y
-- cada item vuelve con `costo_actualizado = false` mas un
-- `warning_costo_reposicion` de cabecera para que la pantalla lo diga.
--
-- =========================================================================
-- 3 · LA 227 PARCHEO UNA SOLA DE LAS DOS
-- =========================================================================
-- La 227 (#539) hizo que la mercaderia 100% bonificada diluya el promedio: son
-- unidades que entraron a costo 0. Toco `registrar_compra_completa` y nada mas.
-- `actualizar_compra_items` conservo `v_actualiza_costo := (bonificacion < 100
-- AND costo_neto > 0)` y en la rama falsa no hace nada: editar una compra con
-- un regalo le devuelve al producto el promedio sin diluir. Se aplica el mismo
-- parche, con `v_stock_previo` de base, y el post-check de la 227 pasa a mirar
-- las dos funciones.
--
-- =========================================================================
-- 4 · LA NOTA DE CREDITO NO TIENE TOPE EN LA BASE
-- =========================================================================
-- `registrar_nota_credito` (viva desde el baseline) no valida que el
-- `producto_id` pertenezca a la compra ni que la cantidad quepa en lo comprado
-- menos lo ya acreditado. El unico tope vive en `ModalNotaCredito`
-- (`maxCreditable`, con `staleTime` de 5 minutos): dos notas simultaneas sobre
-- la misma compra leen las dos el mismo "ya acreditado", acreditan el doble y
-- descuentan el stock dos veces.
--
-- El corte va POR PRODUCTO, igual que el del modal: la base no sabe de que
-- renglon salio cada unidad. Y el `FOR UPDATE` sobre las lineas de la compra
-- serializa: la segunda espera y al despertarse ve la nota de la primera.
--
-- =========================================================================
-- 5 · issue #566 — EL CLON SE QUEDABA SIN LOTES
-- =========================================================================
-- `cambiar_proveedor_compra` (mig 125, parcheada por 194/195) clona la compra
-- y despues cancela la vieja con un UPDATE directo. Ese UPDATE dispara
-- `borrar_lotes_compra_cancelada` (mig 224), que borra los `producto_lotes` de
-- la compra vieja: el clon nacia sin un solo vencimiento y la mercaderia que
-- seguia en el deposito volvia a la bolsa "sin fecha".
--
-- `producto_lotes.compra_id` apunta a la COMPRA, no a la linea, asi que no hay
-- nada que clonar: se REAPUNTAN antes de cancelar. Reapuntar y no
-- INSERT ... SELECT + DELETE preserva `cantidad_restante` —lo que FEFO ya
-- consumio— y no duplica la suma de lotes ni por un instante, que es el
-- invariante LOTE-A.
--
-- LO QUE NO SE TOCA
-- -----------------
-- · `src/utils/prorrateoCompra.ts`, `prorratear_cargo` y
--   `calcular_costos_compra`: son el motor de PRORRATEO DE CARGOS y estan
--   espejados por `scripts/espejo-motor-compras.mjs`. Ninguna de las tres
--   menciona `costo_promedio`, y el bloque de verificacion lo vuelve a
--   comprobar.
-- · El contrato de las RPCs, salvo por los campos NUEVOS de salida
--   (`warning_costo_reposicion`, y el `motivo` de cada entrada de
--   `warning_costo_promedio`).
-- · El orden de `anular_compra_atomica`: la mig 229 ya cancela ANTES de bajar
--   el stock, justamente para que el trigger de lotes no consuma FEFO de lotes
--   ajenos y despues borre ademas los propios. Verificado sobre el cuerpo
--   vivo; no hay nada que hacer.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 0 · Los helpers de cirugia sobre el cuerpo vivo.
-- -------------------------------------------------------------------------

-- Reemplazo de un ancla exacta. Falla si no aparece exactamente una vez.
CREATE OR REPLACE FUNCTION public._mig236_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- Reemplazo de una REGION delimitada por dos marcas cortas. El ancla se extrae
-- del cuerpo vivo en vez de transcribirse: cuarenta lineas copiadas a mano son
-- cuarenta oportunidades de que un espacio no coincida y el parche no entre.
-- Las dos marcas si se transcriben, pero son de un renglon.
CREATE OR REPLACE FUNCTION public._mig236_region(
  p_funcion regprocedure,
  p_desde   text,
  p_hasta   text,
  p_nuevo   text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_ini   int;
  v_fin   int;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);

  v_veces := (length(v_def) - length(replace(v_def, p_desde, ''))) / length(p_desde);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'La marca de apertura aparece % veces en % (se esperaba 1): %',
      v_veces, p_funcion, left(p_desde, 120);
  END IF;
  v_veces := (length(v_def) - length(replace(v_def, p_hasta, ''))) / length(p_hasta);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'La marca de cierre aparece % veces en % (se esperaba 1): %',
      v_veces, p_funcion, left(p_hasta, 120);
  END IF;

  v_ini := position(p_desde in v_def);
  v_fin := position(p_hasta in v_def);
  IF v_fin <= v_ini THEN
    RAISE EXCEPTION 'En % la marca de cierre esta antes de la de apertura.', p_funcion;
  END IF;

  EXECUTE left(v_def, v_ini - 1) || p_nuevo || substr(v_def, v_fin);
END;
$fn$;

-- -------------------------------------------------------------------------
-- 1 · La columna que guarda el promedio de antes.
-- -------------------------------------------------------------------------
ALTER TABLE public.compra_items
  ADD COLUMN IF NOT EXISTS costo_promedio_anterior NUMERIC;

COMMENT ON COLUMN public.compra_items.costo_promedio_anterior IS
  'El costo promedio ponderado del producto JUSTO ANTES de esta linea, analogo '
  'a stock_anterior. Existe porque despues no se puede reconstruir: '
  'productos.costo_promedio ya incluye esta compra, y usarlo de base al editar '
  'corre el promedio hacia el costo de la factura en cada edicion (mig 236). '
  'NULL en las lineas anteriores a la mig 236: para esas la edicion no toca el '
  'promedio y avisa.';

-- -------------------------------------------------------------------------
-- 2 · registrar_compra_completa — guarda el promedio previo y respeta la
--     compra posterior.
-- -------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_compra_completa';

  -- 2.a) Las variables nuevas.
  PERFORM public._mig236_ancla(v_fn,
$ancla$  v_usar_motor          BOOLEAN := false;
  v_warning_ii          TEXT;
BEGIN
$ancla$,
$nuevo$  v_usar_motor          BOOLEAN := false;
  v_warning_ii          TEXT;
  -- mig 236
  v_cpp_previo          NUMERIC;   -- el promedio de ANTES de esta linea
  v_max_fecha           DATE;
  v_es_mas_reciente     BOOLEAN;
  v_warning_repos       JSONB := '[]'::JSONB;
BEGIN
$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_compra_completa';

  -- 2.b) Los dos datos que solo se pueden leer ANTES de tocar el producto.
  PERFORM public._mig236_ancla(v_fn,
$ancla$    v_cantidad           := (v_item->>'cantidad')::INTEGER;
    v_stock_anterior     := COALESCE(v_producto.stock, 0);
    v_stock_nuevo        := v_stock_anterior + v_cantidad;
$ancla$,
$nuevo$    v_cantidad           := (v_item->>'cantidad')::INTEGER;
    v_stock_anterior     := COALESCE(v_producto.stock, 0);
    v_stock_nuevo        := v_stock_anterior + v_cantidad;

    /* mig 236 · dos cosas que se leen ACA porque despues ya no se pueden saber.

       El PROMEDIO PREVIO se guarda en la fila. Sin el, editar la compra
       re-deriva el promedio desde el promedio que YA la incluye y lo corre
       hacia el costo de la factura en cada edicion (ver el encabezado). Se
       guarda un 0 y no un NULL cuando el producto no tenia promedio: 0 y NULL
       significan lo mismo —no habia— y NULL ya esta tomado por "esta linea es
       anterior a la mig 236 y no se sabe".

       Y si esta compra es la MAS NUEVA del producto: una factura traspapelada
       que se carga con su fecha real no es el costo de reposicion de hoy. Se
       excluye la propia compra por id, asi que un producto repetido en dos
       lineas no se cuenta a si mismo. */
    v_cpp_previo := COALESCE(v_producto.costo_promedio, 0);

    SELECT MAX(c.fecha_compra) INTO v_max_fecha
      FROM compras c
      JOIN compra_items ci ON ci.compra_id = c.id AND ci.sucursal_id = c.sucursal_id
     WHERE ci.producto_id = (v_item->>'producto_id')::BIGINT
       AND ci.sucursal_id = v_sucursal
       AND c.estado <> 'cancelada'
       AND c.id <> v_compra_id;

    v_es_mas_reciente := (v_max_fecha IS NULL)
                      OR (COALESCE(p_fecha_compra, CURRENT_DATE) >= v_max_fecha);
$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_compra_completa';

  -- 2.c) La columna nueva en el INSERT de la linea.
  PERFORM public._mig236_ancla(v_fn,
$ancla$      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
      condicion_iva, cargos_unitarios /* mig 194 */
    ) VALUES (
$ancla$,
$nuevo$      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
      condicion_iva, cargos_unitarios /* mig 194 */,
      costo_promedio_anterior /* mig 236 */
    ) VALUES (
$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_compra_completa';

  PERFORM public._mig236_ancla(v_fn,
$ancla$      v_condicion_iva,
      v_cargo_unit /* mig 194 */
    )
    RETURNING id INTO v_item_id;
$ancla$,
$nuevo$      v_condicion_iva,
      v_cargo_unit /* mig 194 */,
      v_cpp_previo /* mig 236 */
    )
    RETURNING id INTO v_item_id;
$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_compra_completa';

  -- 2.d) El costo de reposicion no se pisa si hay una compra posterior.
  PERFORM public._mig236_ancla(v_fn,
$ancla$      UPDATE productos
         SET stock              = stock + v_cantidad,
             costo_sin_iva      = v_costo_neto,
             costo_con_iva      = v_costo_con_iva,
             costo_real         = v_costo_real,
             costo_promedio     = v_costo_promedio,
             ultimo_tipo_compra = v_tipo_factura,
             updated_at         = NOW()
       WHERE id = (v_item->>'producto_id')::BIGINT
         AND sucursal_id = v_sucursal;
$ancla$,
$nuevo$      IF v_es_mas_reciente THEN
        UPDATE productos
           SET stock              = stock + v_cantidad,
               costo_sin_iva      = v_costo_neto,
               costo_con_iva      = v_costo_con_iva,
               costo_real         = v_costo_real,
               costo_promedio     = v_costo_promedio,
               ultimo_tipo_compra = v_tipo_factura,
               updated_at         = NOW()
         WHERE id = (v_item->>'producto_id')::BIGINT
           AND sucursal_id = v_sucursal;
      ELSE
        /* mig 236 · hay una compra POSTERIOR no cancelada de este producto. El
           stock y el promedio suman igual —la mercaderia entro y las unidades
           pesan—, pero el costo de REPOSICION es el de la ultima factura, no el
           de esta. Mismo criterio que actualizar_compra_items desde la 128. */
        UPDATE productos
           SET stock          = stock + v_cantidad,
               costo_promedio = v_costo_promedio,
               updated_at     = NOW()
         WHERE id = (v_item->>'producto_id')::BIGINT
           AND sucursal_id = v_sucursal;

        v_warning_repos := v_warning_repos || jsonb_build_object(
          'producto_id',         (v_item->>'producto_id')::BIGINT,
          'fecha_compra',        COALESCE(p_fecha_compra, CURRENT_DATE),
          'fecha_ultima_compra', v_max_fecha);
      END IF;
$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_compra_completa';

  -- 2.e) `costo_actualizado` dice la verdad por item.
  PERFORM public._mig236_ancla(v_fn,
$ancla$      'costo_actualizado', v_actualiza_costo
    );
$ancla$,
$nuevo$      'costo_actualizado', (v_actualiza_costo AND v_es_mas_reciente) /* mig 236 */
    );
$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_compra_completa';

  -- 2.f) Y el aviso de cabecera, para no obligar a la pantalla a recorrer
  --      items_procesados para enterarse.
  PERFORM public._mig236_ancla(v_fn,
$ancla$    'warning_descuadre', v_warning,
    'warning_ii_declarado', v_warning_ii /* mig 194 */
  );
$ancla$,
$nuevo$    'warning_descuadre', v_warning,
    'warning_ii_declarado', v_warning_ii, /* mig 194 */
    'warning_costo_reposicion', CASE WHEN jsonb_array_length(v_warning_repos) > 0
                                     THEN v_warning_repos ELSE NULL END /* mig 236 */
  );
$nuevo$);
END
$patch$;

-- -------------------------------------------------------------------------
-- 3 · actualizar_compra_items — el promedio arranca de donde estaba, y el
--     regalo diluye tambien en la edicion.
-- -------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'actualizar_compra_items';

  -- 3.a) Las variables nuevas.
  PERFORM public._mig236_ancla(v_fn,
$ancla$  v_usar_motor       BOOLEAN := false;
  v_warning_ii       TEXT;
BEGIN
$ancla$,
$nuevo$  v_usar_motor       BOOLEAN := false;
  v_warning_ii       TEXT;
  -- mig 236
  v_cpp_previo_map   JSONB := '{}'::JSONB;  -- producto -> costo_promedio_anterior
  v_cpp_hay_previo   BOOLEAN;
  v_cpp_persistir    NUMERIC;
BEGIN
$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'actualizar_compra_items';

  -- 3.b) La base correcta del promedio, antes del DELETE de las lineas.
  PERFORM public._mig236_ancla(v_fn,
$ancla$         AND COALESCE(bonificacion, 0) < 100
       GROUP BY producto_id
    ) t;
$ancla$,
$nuevo$         AND COALESCE(bonificacion, 0) < 100
       GROUP BY producto_id
    ) t;

  /* mig 236 · EL PROMEDIO PREVIO A ESTA COMPRA.

     `v_cpp_map` trae el promedio VIVO, que ya incluye lo que esta compra
     aporto, mientras `v_stock_previo_map` si resta sus unidades. Usar los dos
     juntos mezcla un promedio de despues con un stock de antes y corre el
     numero hacia el costo de la factura en CADA edicion, aunque no se toque ni
     una cantidad ni un costo. Medido: 100 u. a 10 mas una compra de 100 u. a
     20 dejan 15 al registrar y 17,50 despues de una edicion sin un solo cambio.

     La base correcta es el snapshot que guardo el alta en la fila. Se toma el
     de la PRIMERA linea del producto (por id): la segunda linea del mismo
     producto ya vio el promedio movido por la primera.

     Para un producto que esta compra NO tocaba —uno que se agrega en esta
     edicion— el vivo ES el previo, y se deja como esta. */
  SELECT COALESCE(jsonb_object_agg(producto_id::text, to_jsonb(cpp_prev)), '{}'::JSONB)
    INTO v_cpp_previo_map
    FROM (
      SELECT DISTINCT ON (producto_id) producto_id, costo_promedio_anterior AS cpp_prev
        FROM compra_items
       WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
       ORDER BY producto_id, id
    ) t;

  SELECT COALESCE(jsonb_object_agg(e.key,
           CASE WHEN jsonb_typeof(v_cpp_previo_map -> e.key) = 'number'
                THEN v_cpp_previo_map -> e.key
                ELSE e.value END), '{}'::JSONB)
    INTO v_cpp_map
    FROM jsonb_each(v_cpp_map) e;
$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'actualizar_compra_items';

  -- 3.c) La base de la linea se lee ANTES de insertarla, porque la fila nueva
  --      se lleva su propio snapshot.
  PERFORM public._mig236_ancla(v_fn,
$ancla$    v_stock_anterior := COALESCE((v_snapshot_stock->>v_producto_id::TEXT)::INTEGER, 0);
    v_stock_nuevo := v_stock_anterior + v_cantidad;
$ancla$,
$nuevo$    v_stock_anterior := COALESCE((v_snapshot_stock->>v_producto_id::TEXT)::INTEGER, 0);
    v_stock_nuevo := v_stock_anterior + v_cantidad;

    /* mig 236 · la base del promedio para esta linea. `v_cpp_hay_previo` es
       falso solo cuando el producto YA estaba en esta compra y su linea vieja
       no guardo el snapshot, o sea una compra anterior a esta migracion: ahi no
       hay de donde arrancar. `jsonb_typeof` distingue las tres situaciones de
       un tiro: NULL = la clave no esta (el producto se agrega en ESTA edicion y
       el promedio vivo ES el previo), 'null' = estaba y no se guardo, cualquier
       otra cosa = el snapshot.
       Lo que se persiste no pasa por el NULLIF: un promedio de 0 es un numero
       conocido ("no habia") y NULL significa otra cosa. */
    v_cpp_hay_previo := COALESCE(
      jsonb_typeof(v_cpp_previo_map -> v_producto_id::TEXT), 'ausente') <> 'null';
    v_stock_previo   := COALESCE((v_stock_previo_map->>v_producto_id::TEXT)::NUMERIC, 0);
    v_cpp_actual     := NULLIF((v_cpp_map->>v_producto_id::TEXT)::NUMERIC, 0);
    v_cpp_persistir  := CASE WHEN v_cpp_hay_previo
                             THEN COALESCE((v_cpp_map->>v_producto_id::TEXT)::NUMERIC, 0)
                             ELSE NULL END;
$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'actualizar_compra_items';

  -- 3.d) La columna nueva en el INSERT de la linea.
  PERFORM public._mig236_ancla(v_fn,
$ancla$      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
      condicion_iva, cargos_unitarios /* mig 194 */
    ) VALUES (
      p_compra_id, v_producto_id, v_cantidad, v_costo_unitario,
      v_subtotal_item, v_stock_anterior, v_stock_nuevo, v_bonificacion, v_sucursal,
      v_porcentaje_iva, v_impuestos_internos, round(v_costo_neto, 4), v_costo_real,
      v_condicion_iva, v_cargo_unit
    )
$ancla$,
$nuevo$      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
      condicion_iva, cargos_unitarios /* mig 194 */,
      costo_promedio_anterior /* mig 236 */
    ) VALUES (
      p_compra_id, v_producto_id, v_cantidad, v_costo_unitario,
      v_subtotal_item, v_stock_anterior, v_stock_nuevo, v_bonificacion, v_sucursal,
      v_porcentaje_iva, v_impuestos_internos, round(v_costo_neto, 4), v_costo_real,
      v_condicion_iva, v_cargo_unit,
      v_cpp_persistir /* mig 236 */
    )
$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'actualizar_compra_items';

  /* 3.e) El bloque del promedio, entero. Se reemplaza por REGION y no por ancla
          transcripta: son cuarenta lineas del cuerpo vivo y alcanza con que un
          espacio no coincida para que el parche no entre. */
  PERFORM public._mig236_region(v_fn,
$desde$    IF v_es_mas_reciente AND v_actualiza_costo THEN$desde$,
$hasta$    v_items_procesados := v_items_procesados || jsonb_build_object($hasta$,
$nuevo$    IF v_es_mas_reciente AND v_actualiza_costo THEN
      IF v_cpp_hay_previo THEN
        -- Re-derivacion del CPP: la linea se trata como si recien entrara,
        -- sobre el stock Y el promedio previos a esta compra. Hasta la mig 236
        -- el promedio de la formula era el vivo, que ya incluia esta compra.
        IF v_stock_previo <= 0 OR v_cpp_actual IS NULL OR v_cpp_actual <= 0 THEN
          v_costo_promedio := v_costo_real;
        ELSE
          v_costo_promedio := round(
            (v_stock_previo * v_cpp_actual + v_cantidad * v_costo_real)
            / (v_stock_previo + v_cantidad), 4);
        END IF;

        v_cpp_map := jsonb_set(v_cpp_map, ARRAY[v_producto_id::TEXT], to_jsonb(v_costo_promedio));

        UPDATE productos
           SET costo_sin_iva      = v_costo_neto,
               costo_con_iva      = v_costo_con_iva,
               costo_real         = v_costo_real,
               costo_promedio     = v_costo_promedio,
               ultimo_tipo_compra = v_compra.tipo_factura,
               updated_at         = NOW()
         WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      ELSE
        /* mig 236 · compra anterior a la columna del snapshot: no hay de donde
           arrancar el promedio. El costo de REPOSICION se actualiza igual —no
           depende del promedio— y el promedio queda como esta. Avisar es mejor
           que moverlo para el lado equivocado. */
        v_costo_promedio := COALESCE((v_cpp_map->>v_producto_id::TEXT)::NUMERIC, 0);

        UPDATE productos
           SET costo_sin_iva      = v_costo_neto,
               costo_con_iva      = v_costo_con_iva,
               costo_real         = v_costo_real,
               ultimo_tipo_compra = v_compra.tipo_factura,
               updated_at         = NOW()
         WHERE id = v_producto_id AND sucursal_id = v_sucursal;

        v_warning_cpp := v_warning_cpp || jsonb_build_object(
          'producto_id', v_producto_id,
          'motivo', 'sin_cpp_previo'
        );
      END IF;

      v_costo_actualizado := v_costo_actualizado || jsonb_build_object(
        'producto_id', v_producto_id,
        'costo_sin_iva', v_costo_neto,
        'costo_con_iva', v_costo_con_iva,
        'costo_real', v_costo_real,
        'costo_promedio', v_costo_promedio
      );
    ELSIF v_actualiza_costo THEN
      -- Compra vieja: forward-only, el CPP no se retro-ajusta. Avisar si el
      -- costo cambio materialmente (> 1%).
      v_costo_old := NULLIF((v_costo_old_map->>v_producto_id::TEXT)::NUMERIC, 0);
      IF v_costo_old IS NOT NULL
         AND abs(v_costo_real - v_costo_old) / v_costo_old > 0.01 THEN
        v_warning_cpp := v_warning_cpp || jsonb_build_object(
          'producto_id', v_producto_id,
          'costo_real_anterior', v_costo_old,
          'costo_real_nuevo', v_costo_real,
          'motivo', 'no_es_la_ultima' /* mig 236 */
        );
      END IF;
    ELSIF v_es_mas_reciente AND v_cpp_hay_previo THEN
      /* mig 236 · el parche de la 227 (#539), que solo habia entrado en el
         alta: la mercaderia regalada SI diluye el promedio, son unidades que
         entraron a costo 0. Solo el promedio — costo_real, costo_sin_iva y
         costo_con_iva son costo de REPOSICION y una entrega gratis no cambia a
         cuanto se repone. Se diluye solo si HAY promedio previo que diluir,
         mismo criterio que el alta: fijar cero desde la nada es otra decision. */
      IF v_stock_previo > 0 AND v_cpp_actual IS NOT NULL AND v_cpp_actual > 0 THEN
        v_costo_promedio := round(
          (v_stock_previo * v_cpp_actual) / (v_stock_previo + v_cantidad), 4);
        v_cpp_map := jsonb_set(v_cpp_map, ARRAY[v_producto_id::TEXT], to_jsonb(v_costo_promedio));
        UPDATE productos
           SET costo_promedio = v_costo_promedio,
               updated_at     = NOW()
         WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      END IF;
    END IF;

    /* mig 236 · la linea ya entro: su stock pesa en la base de la linea
       siguiente del mismo producto, haya tomado la rama que haya tomado. Antes
       solo avanzaba en la rama que re-derivaba, asi que un regalo seguido de
       una linea paga del mismo producto volvia a contar el mismo stock. */
    v_stock_previo_map := jsonb_set(v_stock_previo_map, ARRAY[v_producto_id::TEXT],
                                    to_jsonb(v_stock_previo + v_cantidad));

$nuevo$);
END
$patch$;

-- -------------------------------------------------------------------------
-- 4 · registrar_nota_credito — el tope de lo acreditable vive en la base.
-- -------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_nota_credito';

  PERFORM public._mig236_ancla(v_fn,
$ancla$  v_producto_id BIGINT; v_cantidad INTEGER; v_costo DECIMAL; v_sub DECIMAL;
BEGIN
$ancla$,
$nuevo$  v_producto_id BIGINT; v_cantidad INTEGER; v_costo DECIMAL; v_sub DECIMAL;
  v_exceso TEXT;  -- mig 236
BEGIN
$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_nota_credito';

  PERFORM public._mig236_ancla(v_fn,
$ancla$  INSERT INTO notas_credito (compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id)
$ancla$,
$nuevo$  /* mig 236 · EL TOPE DE LO ACREDITABLE.

     Hasta aca el unico tope vivia en `ModalNotaCredito` (`maxCreditable`, sobre
     una query con staleTime de 5 minutos). Dos notas simultaneas sobre la misma
     compra leian las dos el mismo "ya acreditado", acreditaban el doble y
     descontaban el stock dos veces; y nada impedia acreditar un producto que la
     compra ni siquiera tenia.

     El FOR UPDATE sobre las lineas de la compra es lo que SERIALIZA: la segunda
     nota espera a que la primera termine y recien entonces cuenta lo acreditado,
     que ya la incluye. Va antes de leer los totales, no despues.

     El corte es POR PRODUCTO, igual que el del modal: la base no sabe de que
     renglon salio cada unidad, y repartir por linea seria inventar una
     convencion que el reparto de la pantalla ya hace para mostrar. */
  PERFORM 1 FROM compra_items
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
   ORDER BY id
     FOR UPDATE;

  SELECT string_agg(
           COALESCE(pr.nombre, '#' || d.producto_id) || ' (' ||
           CASE WHEN d.comprado IS NULL              THEN 'no esta en esta compra'
                WHEN d.pedido IS NULL OR d.pedido <= 0 THEN 'cantidad invalida'
                ELSE format('se piden %s y quedan %s', d.pedido,
                            d.comprado - COALESCE(d.acreditado, 0)) END || ')',
           '; ' ORDER BY d.producto_id)
    INTO v_exceso
    FROM (
      SELECT pe.producto_id, pe.pedido, co.comprado, ac.acreditado
        FROM (SELECT (i->>'producto_id')::BIGINT AS producto_id,
                     SUM((i->>'cantidad')::INTEGER) AS pedido
                FROM jsonb_array_elements(p_items) i
               GROUP BY 1) pe
        LEFT JOIN (SELECT producto_id, SUM(cantidad)::INT AS comprado
                     FROM compra_items
                    WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
                    GROUP BY 1) co ON co.producto_id = pe.producto_id
        LEFT JOIN (SELECT nci.producto_id, SUM(nci.cantidad)::INT AS acreditado
                     FROM nota_credito_items nci
                     JOIN notas_credito nc ON nc.id = nci.nota_credito_id
                                          AND nc.sucursal_id = nci.sucursal_id
                    WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = v_sucursal
                    GROUP BY 1) ac ON ac.producto_id = pe.producto_id
    ) d
    LEFT JOIN productos pr ON pr.id = d.producto_id AND pr.sucursal_id = v_sucursal
   WHERE d.comprado IS NULL
      OR d.pedido IS NULL
      OR d.pedido <= 0
      OR d.pedido > d.comprado - COALESCE(d.acreditado, 0);

  IF v_exceso IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'No se puede acreditar: ' || v_exceso ||
      '. Si la pantalla mostraba otro maximo, recargala: puede haber otra nota de credito sobre esta compra.');
  END IF;

  INSERT INTO notas_credito (compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id)
$nuevo$);
END
$patch$;

-- -------------------------------------------------------------------------
-- 5 · cambiar_proveedor_compra — el clon hereda los lotes (issue #566).
-- -------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'cambiar_proveedor_compra';

  PERFORM public._mig236_ancla(v_fn,
$ancla$  -- 3) Anular la vieja (NO revierte stock: la mercaderia queda)
$ancla$,
$nuevo$  /* 2.2) mig 236 · LOS LOTES DE VENCIMIENTO, issue #566.

        Tiene que pasar ANTES del UPDATE de abajo: cancelar la compra dispara
        `borrar_lotes_compra_cancelada` (mig 224), que borra los lotes de la
        compra vieja. El clon nacia sin un solo vencimiento y la mercaderia que
        seguia en el deposito volvia a la bolsa "sin fecha" — con el stock
        intacto y el panel de vencimientos vacio.

        `producto_lotes.compra_id` apunta a la COMPRA, no a la linea, asi que no
        hay nada que clonar: se REAPUNTAN. Reapuntar y no INSERT ... SELECT mas
        DELETE preserva `cantidad_restante` —lo que FEFO ya consumio— y no
        duplica la suma de lotes ni por un instante, que es el invariante
        LOTE-A. La FK compuesta (compra_id, sucursal_id) queda satisfecha
        porque el clon es de la misma sucursal. */
  UPDATE producto_lotes
     SET compra_id = v_nueva_id
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;

  -- 3) Anular la vieja (NO revierte stock: la mercaderia queda)
$nuevo$);
END
$patch$;

-- -------------------------------------------------------------------------
-- 6 · Los helpers no sobreviven a la migracion.
-- -------------------------------------------------------------------------
DROP FUNCTION public._mig236_ancla(regprocedure, text, text);
DROP FUNCTION public._mig236_region(regprocedure, text, text, text);

-- -------------------------------------------------------------------------
-- 7 · Permisos. CREATE OR REPLACE los preserva, pero dejarlo escrito es lo que
--     hace que el gate de `scripts/check-permisos.mjs` no dependa de eso.
-- -------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.registrar_compra_completa(bigint, character varying, character varying, date, numeric, numeric, numeric, numeric, character varying, text, uuid, jsonb, character varying, numeric, numeric, numeric, numeric, jsonb, jsonb, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_compra_completa(bigint, character varying, character varying, date, numeric, numeric, numeric, numeric, character varying, text, uuid, jsonb, character varying, numeric, numeric, numeric, numeric, jsonb, jsonb, numeric) TO authenticated;

REVOKE ALL ON FUNCTION public.actualizar_compra_items(bigint, jsonb, numeric, numeric, numeric, uuid, numeric, numeric, numeric, numeric, numeric, jsonb, jsonb, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_compra_items(bigint, jsonb, numeric, numeric, numeric, uuid, numeric, numeric, numeric, numeric, numeric, jsonb, jsonb, numeric) TO authenticated;

REVOKE ALL ON FUNCTION public.registrar_nota_credito(bigint, character varying, text, numeric, numeric, numeric, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_nota_credito(bigint, character varying, text, numeric, numeric, numeric, uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION public.cambiar_proveedor_compra(bigint, uuid, bigint, character varying, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cambiar_proveedor_compra(bigint, uuid, bigint, character varying, text) TO authenticated;

-- -------------------------------------------------------------------------
-- 8 · Verificacion estatica: que los parches hayan entrado y que no hayan
--     revertido a los anteriores.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def  text;
  v_n    int;
  v_acl  text;
  v_nom  text;
BEGIN
  -- La columna del snapshot.
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'compra_items'
                    AND column_name = 'costo_promedio_anterior') THEN
    RAISE EXCEPTION 'mig236: falta compra_items.costo_promedio_anterior.';
  END IF;

  -- registrar_compra_completa
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_compra_completa';
  IF v_def NOT LIKE '%costo_promedio_anterior%' THEN
    RAISE EXCEPTION 'mig236: el alta no guarda el promedio previo.';
  END IF;
  IF v_def NOT LIKE '%v_es_mas_reciente%' THEN
    RAISE EXCEPTION 'mig236: el alta sigue pisando el costo de reposicion sin mirar la fecha.';
  END IF;
  IF v_def NOT LIKE '%warning_costo_reposicion%' THEN
    RAISE EXCEPTION 'mig236: el alta no devuelve el aviso de costo de reposicion.';
  END IF;
  -- Post-check de la 227, primera mitad: la rama del regalo sigue diluyendo.
  IF v_def NOT LIKE '%(v_stock_anterior::NUMERIC * v_producto.costo_promedio)%' THEN
    RAISE EXCEPTION 'mig236: se revirtio el parche de la 227 en el alta (el regalo dejo de diluir).';
  END IF;

  -- actualizar_compra_items
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'actualizar_compra_items';
  IF v_def NOT LIKE '%v_cpp_previo_map%' THEN
    RAISE EXCEPTION 'mig236: la edicion sigue re-derivando el promedio desde el promedio vivo.';
  END IF;
  IF v_def NOT LIKE '%costo_promedio_anterior%' THEN
    RAISE EXCEPTION 'mig236: la edicion no re-guarda el promedio previo; la edicion SIGUIENTE se quedaria sin base.';
  END IF;
  IF v_def NOT LIKE '%sin_cpp_previo%' OR v_def NOT LIKE '%no_es_la_ultima%' THEN
    RAISE EXCEPTION 'mig236: faltan los motivos de warning_costo_promedio.';
  END IF;
  -- Post-check de la 227, segunda mitad: ahora tambien en la edicion.
  IF v_def NOT LIKE '%(v_stock_previo * v_cpp_actual) / (v_stock_previo + v_cantidad)%' THEN
    RAISE EXCEPTION 'mig236: la edicion sigue sin diluir el promedio con la mercaderia regalada (227).';
  END IF;

  -- El motor espejado sigue sin saber nada de promedios: si empezara a saber,
  -- hay que tocar `src/utils/prorrateoCompra.ts` tambien. Mismo check que la 227.
  SELECT count(*) INTO v_n FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('prorratear_cargo', 'calcular_costos_compra', 'espejo_motor_compras')
     AND pg_get_functiondef(p.oid) LIKE '%costo_promedio%';
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig236: el motor espejado empezo a tocar costo_promedio; hay que tocar el TS tambien.';
  END IF;

  -- registrar_nota_credito
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_nota_credito';
  IF v_def NOT LIKE '%No se puede acreditar%' THEN
    RAISE EXCEPTION 'mig236: la nota de credito sigue sin tope en la base.';
  END IF;
  IF position($m$FOR UPDATE$m$ in v_def) > position($m$INSERT INTO notas_credito$m$ in v_def) THEN
    RAISE EXCEPTION 'mig236: el FOR UPDATE quedo despues del INSERT; dos notas simultaneas no se serializan.';
  END IF;

  -- cambiar_proveedor_compra: reapuntar ANTES de cancelar, o el trigger de la
  -- 224 se lleva los lotes puestos.
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'cambiar_proveedor_compra';
  IF v_def NOT LIKE '%UPDATE producto_lotes%' THEN
    RAISE EXCEPTION 'mig236: el clon sigue naciendo sin lotes (issue #566).';
  END IF;
  IF position($m$UPDATE producto_lotes$m$ in v_def)
     > position($m$SET estado = 'cancelada',$m$ in v_def) THEN
    RAISE EXCEPTION 'mig236: los lotes se reapuntan DESPUES de cancelar; el trigger de la 224 ya los borro.';
  END IF;

  -- Y el orden de la 229 en anular_compra_atomica, que es de la misma familia:
  -- si el stock baja antes de cancelar, el trigger de lotes consume FEFO de
  -- lotes ajenos y despues borra ademas los propios.
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'anular_compra_atomica';
  IF position($m$SET estado = 'cancelada', updated_at = NOW()$m$ in v_def)
     > position($m$SET stock = p.stock - q.qty$m$ in v_def) THEN
    RAISE EXCEPTION 'mig236: se revirtio el orden de la 229 en anular_compra_atomica.';
  END IF;

  -- Una sola sobrecarga de cada una: dos con rangos superpuestos dan PGRST203
  -- en runtime, invisible para tsc y para los tests.
  FOREACH v_nom IN ARRAY ARRAY['registrar_compra_completa', 'actualizar_compra_items',
                               'registrar_nota_credito', 'cambiar_proveedor_compra',
                               'anular_compra_atomica']
  LOOP
    SELECT count(*) INTO v_n FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_nom;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig236: hay % sobrecargas de %.', v_n, v_nom;
    END IF;
  END LOOP;

  -- Ninguna alcanzable con la anon key.
  SELECT string_agg(p.proname || ' -> ' || a::text, ', ') INTO v_acl
    FROM pg_proc p, unnest(p.proacl) a
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('registrar_compra_completa', 'actualizar_compra_items',
                       'registrar_nota_credito', 'cambiar_proveedor_compra')
     AND (a::text LIKE '=%' OR a::text LIKE 'anon=%');
  IF v_acl IS NOT NULL THEN
    RAISE EXCEPTION 'mig236: quedaron ejecutables de mas (%).', v_acl;
  END IF;

  -- Y los helpers de cirugia no sobrevivieron.
  SELECT count(*) INTO v_n FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE '\_mig236\_%';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'mig236: quedaron % helpers vivos.', v_n;
  END IF;

  RAISE NOTICE 'mig236 · verificacion estatica OK.';
END
$verif$;

-- -------------------------------------------------------------------------
-- 9 · ENSAYO FUNCIONAL, contra las funciones que se acaban de parchear.
--
--     Corre adentro de una subtransaccion que se revierte SIEMPRE: crea un
--     producto, un proveedor y unas compras de prueba, mide, y no deja una sola
--     fila. Las variables de plpgsql no son transaccionales, asi que lo medido
--     sobrevive al rollback y se puede afirmar sobre eso.
--
--     Es lo que convierte a esta migracion en su propia prueba de aceptacion:
--     los cuatro escenarios del issue, sobre el cuerpo vivo, en el momento de
--     aplicarla.
-- -------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_uid    uuid;
  v_suc    bigint;
  v_fallas text := '';
  v_notas  text := '';
  -- lo que se mide adentro de la subtransaccion
  v_cpp_alta     numeric;
  v_cpp_edit     numeric;
  v_real_b       numeric;
  v_cpp_b        numeric;
  v_repos_b      jsonb;
  v_act_b        boolean;
  v_nc_11        boolean;
  v_nc_ajeno     boolean;
  v_nc_6a        boolean;
  v_nc_6b        boolean;
  v_nc_4         boolean;
  v_lotes_nueva  int;
  v_lotes_vieja  int;
  v_lote_rest    int;
BEGIN
  SELECT p.id, us.sucursal_id INTO v_uid, v_suc
    FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.es_default
   WHERE p.rol = 'admin'
   ORDER BY p.id
   LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'mig236: no hay ningun admin con sucursal por defecto; el ensayo no puede correr.';
  END IF;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

    DECLARE
      v_p1 bigint; v_p2 bigint; v_p3 bigint; v_p4 bigint;
      v_prov bigint; v_c bigint; v_c2 bigint; v_nueva bigint;
      v_res jsonb;
      v_linea jsonb;
    BEGIN
      ---------------------------------------------------------------------
      -- A · el promedio no se corre solo al editar (punto 1 del issue)
      ---------------------------------------------------------------------
      INSERT INTO productos (nombre, precio, sucursal_id, stock, costo_promedio,
                             costo_real, costo_sin_iva, impuestos_internos, porcentaje_iva)
      VALUES ('ZZZ mig236 A', 100, v_suc, 100, 10, 10, 10, 0, 21)
      RETURNING id INTO v_p1;

      v_linea := jsonb_build_array(jsonb_build_object(
        'producto_id', v_p1, 'cantidad', 100, 'costo_unitario', 20, 'subtotal', 2000,
        'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0,
        'condicion_iva', 'no_gravado'));

      v_res := registrar_compra_completa(NULL, 'ZZZ mig236', 'ZZZ-A', CURRENT_DATE,
                 2000, 0, 0, 2000, 'efectivo', 'ensayo mig236', v_uid, v_linea,
                 'FC', 0, 0, 0, 0, '[]'::jsonb, '{}'::jsonb, 0);
      IF NOT (v_res->>'success')::boolean THEN
        RAISE EXCEPTION 'A · el alta fallo: %', v_res->>'error';
      END IF;
      v_c := (v_res->>'compra_id')::bigint;
      SELECT costo_promedio INTO v_cpp_alta FROM productos WHERE id = v_p1;

      v_res := actualizar_compra_items(v_c, v_linea, 2000, 0, 2000, v_uid,
                 0, 0, 0, 0, 0, '[]'::jsonb, '{}'::jsonb, 0);
      IF NOT (v_res->>'success')::boolean THEN
        RAISE EXCEPTION 'A · la edicion fallo: %', v_res->>'error';
      END IF;
      SELECT costo_promedio INTO v_cpp_edit FROM productos WHERE id = v_p1;

      ---------------------------------------------------------------------
      -- B · una factura con fecha vieja no pisa el costo de reposicion
      ---------------------------------------------------------------------
      INSERT INTO productos (nombre, precio, sucursal_id, stock, costo_promedio,
                             costo_real, costo_sin_iva, impuestos_internos, porcentaje_iva)
      VALUES ('ZZZ mig236 B', 100, v_suc, 0, NULL, NULL, NULL, 0, 21)
      RETURNING id INTO v_p2;

      v_res := registrar_compra_completa(NULL, 'ZZZ mig236', 'ZZZ-B1', CURRENT_DATE,
                 200, 0, 0, 200, 'efectivo', 'ensayo mig236', v_uid,
                 jsonb_build_array(jsonb_build_object(
                   'producto_id', v_p2, 'cantidad', 10, 'costo_unitario', 20, 'subtotal', 200,
                   'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0,
                   'condicion_iva', 'no_gravado')),
                 'FC', 0, 0, 0, 0, '[]'::jsonb, '{}'::jsonb, 0);
      IF NOT (v_res->>'success')::boolean THEN
        RAISE EXCEPTION 'B · el alta reciente fallo: %', v_res->>'error';
      END IF;

      v_res := registrar_compra_completa(NULL, 'ZZZ mig236', 'ZZZ-B2', CURRENT_DATE - 30,
                 500, 0, 0, 500, 'efectivo', 'ensayo mig236', v_uid,
                 jsonb_build_array(jsonb_build_object(
                   'producto_id', v_p2, 'cantidad', 10, 'costo_unitario', 50, 'subtotal', 500,
                   'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0,
                   'condicion_iva', 'no_gravado')),
                 'FC', 0, 0, 0, 0, '[]'::jsonb, '{}'::jsonb, 0);
      IF NOT (v_res->>'success')::boolean THEN
        RAISE EXCEPTION 'B · el alta traspapelada fallo: %', v_res->>'error';
      END IF;
      v_repos_b := v_res->'warning_costo_reposicion';
      v_act_b   := (v_res->'items_procesados'->0->>'costo_actualizado')::boolean;
      SELECT costo_real, costo_promedio INTO v_real_b, v_cpp_b FROM productos WHERE id = v_p2;

      ---------------------------------------------------------------------
      -- C · la nota de credito no puede pasarse de lo comprado
      ---------------------------------------------------------------------
      INSERT INTO productos (nombre, precio, sucursal_id, stock, costo_promedio,
                             costo_real, costo_sin_iva, impuestos_internos, porcentaje_iva)
      VALUES ('ZZZ mig236 C', 100, v_suc, 0, NULL, NULL, NULL, 0, 21)
      RETURNING id INTO v_p3;

      v_res := registrar_compra_completa(NULL, 'ZZZ mig236', 'ZZZ-C', CURRENT_DATE,
                 100, 0, 0, 100, 'efectivo', 'ensayo mig236', v_uid,
                 jsonb_build_array(jsonb_build_object(
                   'producto_id', v_p3, 'cantidad', 10, 'costo_unitario', 10, 'subtotal', 100,
                   'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0,
                   'condicion_iva', 'no_gravado')),
                 'FC', 0, 0, 0, 0, '[]'::jsonb, '{}'::jsonb, 0);
      IF NOT (v_res->>'success')::boolean THEN
        RAISE EXCEPTION 'C · el alta fallo: %', v_res->>'error';
      END IF;
      v_c2 := (v_res->>'compra_id')::bigint;

      v_nc_11 := (registrar_nota_credito(v_c2, 'ZZZ-NC-11', 'ensayo', 110, 0, 110, v_uid,
                   jsonb_build_array(jsonb_build_object('producto_id', v_p3, 'cantidad', 11,
                     'costo_unitario', 10, 'subtotal', 110)))->>'success')::boolean;

      v_nc_ajeno := (registrar_nota_credito(v_c2, 'ZZZ-NC-AJ', 'ensayo', 10, 0, 10, v_uid,
                      jsonb_build_array(jsonb_build_object('producto_id', v_p1, 'cantidad', 1,
                        'costo_unitario', 10, 'subtotal', 10)))->>'success')::boolean;

      v_nc_6a := (registrar_nota_credito(v_c2, 'ZZZ-NC-6a', 'ensayo', 60, 0, 60, v_uid,
                   jsonb_build_array(jsonb_build_object('producto_id', v_p3, 'cantidad', 6,
                     'costo_unitario', 10, 'subtotal', 60)))->>'success')::boolean;

      v_nc_6b := (registrar_nota_credito(v_c2, 'ZZZ-NC-6b', 'ensayo', 60, 0, 60, v_uid,
                   jsonb_build_array(jsonb_build_object('producto_id', v_p3, 'cantidad', 6,
                     'costo_unitario', 10, 'subtotal', 60)))->>'success')::boolean;

      v_nc_4 := (registrar_nota_credito(v_c2, 'ZZZ-NC-4', 'ensayo', 40, 0, 40, v_uid,
                  jsonb_build_array(jsonb_build_object('producto_id', v_p3, 'cantidad', 4,
                    'costo_unitario', 10, 'subtotal', 40)))->>'success')::boolean;

      ---------------------------------------------------------------------
      -- D · cambiar de proveedor conserva los lotes (issue #566)
      ---------------------------------------------------------------------
      INSERT INTO productos (nombre, precio, sucursal_id, stock, costo_promedio,
                             costo_real, costo_sin_iva, impuestos_internos, porcentaje_iva)
      VALUES ('ZZZ mig236 D', 100, v_suc, 0, NULL, NULL, NULL, 0, 21)
      RETURNING id INTO v_p4;

      INSERT INTO proveedores (nombre, sucursal_id)
      VALUES ('ZZZ mig236 proveedor', v_suc)
      RETURNING id INTO v_prov;

      v_res := registrar_compra_completa(NULL, 'ZZZ mig236 equivocado', 'ZZZ-D', CURRENT_DATE,
                 100, 0, 0, 100, 'efectivo', 'ensayo mig236', v_uid,
                 jsonb_build_array(jsonb_build_object(
                   'producto_id', v_p4, 'cantidad', 10, 'costo_unitario', 10, 'subtotal', 100,
                   'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0,
                   'condicion_iva', 'no_gravado')),
                 'FC', 0, 0, 0, 0, '[]'::jsonb, '{}'::jsonb, 0);
      IF NOT (v_res->>'success')::boolean THEN
        RAISE EXCEPTION 'D · el alta fallo: %', v_res->>'error';
      END IF;
      v_c := (v_res->>'compra_id')::bigint;

      INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento,
                                  cantidad, cantidad_restante, compra_id, origen, usuario_id)
      VALUES (v_p4, v_suc, CURRENT_DATE + 60, 10, 10, v_c, 'compra', v_uid);

      v_res := cambiar_proveedor_compra(v_c, v_uid, v_prov, NULL, 'ensayo mig236');
      IF NOT (v_res->>'success')::boolean THEN
        RAISE EXCEPTION 'D · el cambio de proveedor fallo: %', v_res->>'error';
      END IF;
      v_nueva := (v_res->>'nueva_compra_id')::bigint;

      SELECT count(*), COALESCE(max(cantidad_restante), -1) INTO v_lotes_nueva, v_lote_rest
        FROM producto_lotes WHERE compra_id = v_nueva;
      SELECT count(*) INTO v_lotes_vieja FROM producto_lotes WHERE compra_id = v_c;
    END;

    RAISE EXCEPTION 'mig236_rollback_del_ensayo';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig236_rollback_del_ensayo' THEN
      RAISE EXCEPTION 'mig236 · el ensayo funcional exploto: %', SQLERRM;
    END IF;
  END;

  -- A
  IF v_cpp_alta IS DISTINCT FROM 15.0000 THEN
    v_fallas := v_fallas || format(' [A alta: el promedio quedo en %s y tenia que ser 15]', v_cpp_alta);
  END IF;
  IF v_cpp_edit IS DISTINCT FROM 15.0000 THEN
    v_fallas := v_fallas || format(' [A edicion: el promedio se corrio a %s; antes de la 236 daba 17,50]', v_cpp_edit);
  END IF;
  -- B
  IF v_real_b IS DISTINCT FROM 20 THEN
    v_fallas := v_fallas || format(' [B: la factura vieja piso el costo de reposicion, quedo en %s en vez de 20]', v_real_b);
  END IF;
  IF v_cpp_b IS DISTINCT FROM 35.0000 THEN
    v_fallas := v_fallas || format(' [B: el promedio tenia que sumar igual y quedo en %s en vez de 35]', v_cpp_b);
  END IF;
  IF v_repos_b IS NULL OR jsonb_typeof(v_repos_b) <> 'array' THEN
    v_fallas := v_fallas || ' [B: no vino warning_costo_reposicion]';
  END IF;
  IF v_act_b IS DISTINCT FROM false THEN
    v_fallas := v_fallas || format(' [B: costo_actualizado vino %s y tenia que venir false]', v_act_b);
  END IF;
  -- C
  IF v_nc_11 THEN     v_fallas := v_fallas || ' [C: una NC de 11 sobre una compra de 10 paso]'; END IF;
  IF v_nc_ajeno THEN  v_fallas := v_fallas || ' [C: una NC de un producto que no esta en la compra paso]'; END IF;
  IF NOT v_nc_6a THEN v_fallas := v_fallas || ' [C: la primera NC de 6 sobre 10 tendria que haber pasado]'; END IF;
  IF v_nc_6b THEN     v_fallas := v_fallas || ' [C: la segunda NC de 6 paso; se acredito el doble]'; END IF;
  IF NOT v_nc_4 THEN  v_fallas := v_fallas || ' [C: la NC de 4, que completa las 10, tendria que haber pasado]'; END IF;
  -- D
  IF v_lotes_nueva <> 1 THEN
    v_fallas := v_fallas || format(' [D: el clon quedo con %s lotes en vez de 1 (issue #566)]', v_lotes_nueva);
  END IF;
  IF v_lote_rest <> 10 THEN
    v_fallas := v_fallas || format(' [D: el lote del clon quedo con %s restantes en vez de 10]', v_lote_rest);
  END IF;
  IF v_lotes_vieja <> 0 THEN
    v_fallas := v_fallas || format(' [D: quedaron %s lotes apuntando a la compra anulada]', v_lotes_vieja);
  END IF;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig236 · el ensayo funcional encontro:%', v_fallas;
  END IF;

  v_notas := format('A alta=%s edicion=%s · B costo_real=%s promedio=%s · C 11=%s ajeno=%s 6a=%s 6b=%s 4=%s · D lotes_clon=%s restantes=%s lotes_vieja=%s',
                    v_cpp_alta, v_cpp_edit, v_real_b, v_cpp_b,
                    v_nc_11, v_nc_ajeno, v_nc_6a, v_nc_6b, v_nc_4,
                    v_lotes_nueva, v_lote_rest, v_lotes_vieja);
  RAISE NOTICE 'mig236 · ensayo funcional OK: %', v_notas;
END
$ensayo$;

COMMIT;
