/**
 * Columnas de `productos` que se leen por REST (#974).
 *
 * Desde la migración de #974, `authenticated` no tiene SELECT sobre la tabla
 * entera sino columna por columna, y las de costo quedan afuera: las da sólo la
 * RPC `costos_productos()`, a admin y encargado. Por eso:
 *
 *  - Ninguna consulta pide `*` sobre productos —ni `select('*')`, ni un
 *    `.select()` pelado después de un insert/update, ni un embed de productos
 *    con asterisco—. En PostgREST un `*` sobre una columna sin
 *    permiso hace fallar la consulta ENTERA, para todos los roles. Lo vigila
 *    `productoColumnas.test.ts`.
 *  - Una columna nueva de productos nace sin SELECT para nadie: hay que
 *    concederla en su migración Y sumarla acá, o el front no la ve.
 */

/** Las cuatro columnas que sólo devuelve `costos_productos()`. */
export const COLUMNAS_COSTO_PRODUCTO = [
  'costo_real',
  'costo_promedio',
  'costo_sin_iva',
  'costo_con_iva',
] as const

/**
 * Todas las columnas de productos MENOS las de costo, en el orden de la tabla.
 * Es exactamente el `GRANT SELECT (...)` de la migración de #974.
 *
 * Es un literal de string y no un `[...].join(', ')` a propósito: supabase-js
 * parsea el `select` en el TIPO, y con un `string` cualquiera no puede y tipa
 * las filas como `GenericStringError`.
 */
export const PRODUCTO_COLUMNAS =
  'id, nombre, precio, stock, categoria, created_at, codigo, impuestos_internos, precio_sin_iva, stock_minimo, porcentaje_iva, proveedor_id, updated_at, sucursal_id, tp_import_id, unidades_de_venta_por_fardo, etiqueta_bulto, ultimo_tipo_compra, categoria_id, cantidad_minima_venta, marca_id, condicion_iva, subcategoria_id, ii_encuadre_id, activo, unidades_por_bulto'
