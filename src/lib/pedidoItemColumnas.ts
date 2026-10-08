/**
 * Columnas de `pedido_items` que se leen por REST (#1003).
 *
 * Desde la migración de #1003, `authenticated` no tiene SELECT sobre la tabla
 * entera sino columna por columna, y `costo_unitario_al_crear` queda afuera: el
 * costo de cada venta lo da sólo la RPC `costos_pedido_items()`, a admin y
 * encargado. Es el mismo molde que `productoColumnas.ts` (#974). Por eso:
 *
 *  - Ninguna consulta pide `*` sobre pedido_items —ni un embed con asterisco,
 *    ni `select('*')`, ni un `.select()` pelado—. En PostgREST un `*`
 *    sobre una columna sin permiso hace fallar la consulta ENTERA, para todos
 *    los roles. Lo vigila `pedidoItemColumnas.test.ts`.
 *  - Una columna nueva de pedido_items nace sin SELECT para nadie: hay que
 *    concederla en su migración Y sumarla acá, o el front no la ve.
 */

/** La columna que sólo devuelve `costos_pedido_items()`. */
export const COLUMNAS_COSTO_PEDIDO_ITEM = ['costo_unitario_al_crear'] as const

/**
 * Todas las columnas de pedido_items MENOS la de costo, en el orden de la tabla.
 * Es exactamente el `GRANT SELECT (...)` de la migración de #1003.
 *
 * Es un literal de string y no un `[...].join(', ')` a propósito: supabase-js
 * parsea el `select` en el TIPO, y con un `string` cualquiera no puede y tipa
 * las filas como `GenericStringError`.
 */
export const PEDIDO_ITEM_COLUMNAS =
  'id, pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id, neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, sucursal_id, tp_import_id, descripcion_regalo, stock_al_crear, ingreso_real_unitario, precio_lista_al_crear, origen_precio, descuento_pct, grupo_precio_escala_id, unidades_por_bloque_al_crear, origen_unidades_por_bloque'
