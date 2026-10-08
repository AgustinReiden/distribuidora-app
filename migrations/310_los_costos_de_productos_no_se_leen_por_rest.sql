-- #974 (2/2) · productos: los costos ya no se leen por REST
--
-- `authenticated` (y `anon`) tenían SELECT sobre la tabla `productos` ENTERA, y
-- la RLS filtra sólo por sucursal: cualquier rol, preventista incluido, leía
-- `costo_real`, `costo_promedio`, `costo_sin_iva` y `costo_con_iva` —o sea,
-- costo y margen de todo el catálogo— con la anon key y su sesión, aunque la UI
-- no los mostrara.
--
-- Revocar sólo esas cuatro columnas NO alcanza: con un GRANT de tabla vigente,
-- un `REVOKE SELECT (col)` no tiene efecto. Por eso se revoca el SELECT de la
-- tabla y se concede columna por columna todo lo demás.
--
-- Consecuencias que hay que saber:
--   * Una columna NUEVA de productos nace sin SELECT para authenticated: su
--     migración tiene que concederla, y `src/lib/productoColumnas.ts` sumarla
--     (el test de ese archivo compara la lista contra este GRANT).
--   * Un `*` sobre productos por PostgREST —`select('*')`, `.select()` pelado
--     tras un insert/update, `producto:productos(*)`— falla la consulta ENTERA,
--     para todos los roles. El front pide `PRODUCTO_COLUMNAS`.
--   * INSERT / UPDATE / DELETE no cambian: el admin sigue guardando costos al
--     editar un producto (lo que lo limita es la RLS y `productos_proteger_columnas`).
--   * Las funciones SECURITY DEFINER (reportes, compras, pedidos, el trigger de
--     mermas que sólo disparan RPCs definer) leen como su dueño: no las afecta.
--   * service_role (bot, edge functions) no se toca.
--
-- Quien sí necesita los costos —admin y encargado: lista de Productos, ficha
-- del producto, costo por defecto en Compras, aceptar transferencias, export a
-- BI, backup— los pide a `costos_productos()`, que creó la mitad 1/2 (mig 299).
--
-- ORDEN: esta mitad va DESPUÉS de desplegar el front que pide
-- `PRODUCTO_COLUMNAS` (y de que las PWA abiertas lo tomen). Con el front viejo,
-- su `select('*')` sobre productos falla para todos los roles.

-- SELECT por columna, sin las cuatro de costo

REVOKE SELECT ON public.productos FROM authenticated, anon;

GRANT SELECT (id, nombre, precio, stock, categoria, created_at, codigo, impuestos_internos, precio_sin_iva, stock_minimo, porcentaje_iva, proveedor_id, updated_at, sucursal_id, tp_import_id, unidades_de_venta_por_fardo, etiqueta_bulto, ultimo_tipo_compra, categoria_id, cantidad_minima_venta, marca_id, condicion_iva, subcategoria_id, ii_encuadre_id, activo, unidades_por_bulto)
  ON public.productos TO authenticated;

GRANT SELECT (id, nombre, precio, stock, categoria, created_at, codigo, impuestos_internos, precio_sin_iva, stock_minimo, porcentaje_iva, proveedor_id, updated_at, sucursal_id, tp_import_id, unidades_de_venta_por_fardo, etiqueta_bulto, ultimo_tipo_compra, categoria_id, cantidad_minima_venta, marca_id, condicion_iva, subcategoria_id, ii_encuadre_id, activo, unidades_por_bulto)
  ON public.productos TO anon;

-- Verificación

DO $verif$
DECLARE
  v_costo text;
  v_falta text;
BEGIN
  SELECT string_agg(c, ', ') INTO v_costo
    FROM unnest(ARRAY['costo_real','costo_promedio','costo_sin_iva','costo_con_iva']) c
   WHERE has_column_privilege('authenticated', 'public.productos', c, 'SELECT')
      OR has_column_privilege('anon', 'public.productos', c, 'SELECT');
  IF v_costo IS NOT NULL THEN
    RAISE EXCEPTION '#974 · authenticated/anon siguen leyendo %', v_costo;
  END IF;

  SELECT string_agg(column_name, ', ') INTO v_falta
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'productos'
     AND column_name NOT IN ('costo_real','costo_promedio','costo_sin_iva','costo_con_iva')
     AND NOT has_column_privilege('authenticated', 'public.productos', column_name, 'SELECT');
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION '#974 · authenticated quedó sin SELECT sobre %', v_falta;
  END IF;

  IF has_function_privilege('anon', 'public.costos_productos(bigint[])', 'EXECUTE') THEN
    RAISE EXCEPTION '#974 · anon puede ejecutar costos_productos';
  END IF;
END
$verif$;
