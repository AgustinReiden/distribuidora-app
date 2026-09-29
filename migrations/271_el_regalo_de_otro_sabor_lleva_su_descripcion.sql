-- El regalo de otro sabor lleva su descripcion (#830)
--
-- Cuando el producto de la linea de regalo no es el promociones.producto_regalo_id
-- (el admin eligio otro sabor al cargar), crear_pedido_completo dejaba
-- pedido_items.descripcion_regalo en NULL. Con la promo 13 ("2 Botellas Manaos
-- Limon 3LT") pasaron el pedido 5119 (Lima Limon en vez de Naranja) y el 5253:
-- la linea quedaba sin nada que dijera que su cantidad esta en botellas.
--
-- Ahora guarda la descripcion de la promo con el producto realmente entregado:
-- se conserva el prefijo "<N> <unidad> " de la descripcion de la promo (el
-- formato que ya leen nombreSinConteo y la deteccion de fraccion del manifiesto)
-- y se cambia el resto por el nombre del producto. "2 Botellas Manaos Limon
-- 3LT" + Lima Limon 3 LT -> "2 Botellas MANAOS LIMA LIMON 3 LT". Una promo sin
-- descripcion (no fraccionada) sigue con NULL, igual que en el caso normal.
--
-- crear_pedido_completo_bot no escribia descripcion_regalo NUNCA, ni en el caso
-- normal: un regalo de promo fraccionada por el bot quedaba igual de mudo. Se
-- le aplica la misma regla, de punta a punta.
--
-- Cambio minimo sobre el cuerpo vivo: se parchea con replace() y cada parche
-- exige haber encontrado su texto (si no, RAISE), asi que ni se pisa una version
-- mas nueva de la funcion ni se pierden los GRANT/REVOKE. Firmas intactas.
--
-- Datos historicos (items 18690 y 19310): NO se tocan aca.

DO $mig$
DECLARE
  v_def TEXT;
  v_new TEXT;
BEGIN
  -- crear_pedido_completo ----------------------------------------------------
  SELECT pg_get_functiondef('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure)
    INTO v_def;

  v_new := replace(v_def,
$a$      IF v_regalo_default_id IS DISTINCT FROM v_producto_id THEN
        v_descripcion_regalo := NULL;
      END IF;$a$,
$b$      -- mig 271 (#830): otro sabor -> la descripcion del producto entregado.
      IF v_regalo_default_id IS DISTINCT FROM v_producto_id AND v_descripcion_regalo IS NOT NULL THEN
        v_descripcion_regalo := COALESCE(substring(v_descripcion_regalo from '^\d+\s+\S+\s+'), '')
          || COALESCE((SELECT nombre FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal), '');
      END IF;$b$);
  IF v_new = v_def THEN
    RAISE EXCEPTION 'crear_pedido_completo: no se encontro el bloque de descripcion_regalo';
  END IF;
  EXECUTE v_new;

  -- crear_pedido_completo_bot ------------------------------------------------
  SELECT pg_get_functiondef('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure)
    INTO v_def;

  v_new := replace(v_def,
$a$  v_container_id BIGINT;
BEGIN$a$,
$b$  v_container_id BIGINT;
  v_descripcion_regalo TEXT;
  v_regalo_default_id BIGINT;
BEGIN$b$);
  IF v_new = v_def THEN
    RAISE EXCEPTION 'crear_pedido_completo_bot: no se encontro el DECLARE';
  END IF;
  v_def := v_new;

  v_new := replace(v_def,
$a$    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id, neto_unitario, iva_unitario,
      impuestos_internos_unitario, porcentaje_iva, ingreso_real_unitario,
      sucursal_id, stock_al_crear, costo_unitario_al_crear
    ) VALUES ($a$,
$b$    -- mig 271 (#830): misma regla que crear_pedido_completo.
    v_descripcion_regalo := NULL;
    v_regalo_default_id := NULL;
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      SELECT descripcion_regalo, producto_regalo_id
        INTO v_descripcion_regalo, v_regalo_default_id
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
      IF v_regalo_default_id IS DISTINCT FROM v_producto_id AND v_descripcion_regalo IS NOT NULL THEN
        v_descripcion_regalo := COALESCE(substring(v_descripcion_regalo from '^\d+\s+\S+\s+'), '')
          || COALESCE((SELECT nombre FROM productos WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id), '');
      END IF;
    END IF;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id, neto_unitario, iva_unitario,
      impuestos_internos_unitario, porcentaje_iva, ingreso_real_unitario,
      sucursal_id, stock_al_crear, costo_unitario_al_crear, descripcion_regalo
    ) VALUES ($b$);
  IF v_new = v_def THEN
    RAISE EXCEPTION 'crear_pedido_completo_bot: no se encontro el INSERT de pedido_items';
  END IF;
  v_def := v_new;

  v_new := replace(v_def,
$a$      v_pendiente.sucursal_id, v_stock_al_crear, v_costo_al_crear
    );$a$,
$b$      v_pendiente.sucursal_id, v_stock_al_crear, v_costo_al_crear, v_descripcion_regalo
    );$b$);
  IF v_new = v_def THEN
    RAISE EXCEPTION 'crear_pedido_completo_bot: no se encontro el VALUES de pedido_items';
  END IF;
  EXECUTE v_new;
END
$mig$;
