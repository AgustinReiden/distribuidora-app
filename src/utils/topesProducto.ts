/**
 * Topes de las columnas de `productos` que llenan la ficha (catalogo-B4, tanda 6 de #1603):
 * `stock` y `stock_minimo` son `integer`, `precio` es `numeric(10,2)` y `codigo` es `varchar(50)`.
 * Pasarse llegaba como `22003` / `22001` crudo; ahora la ficha lo deja en rojo con el límite y no guarda.
 */
export const STOCK_MAXIMO = 2_147_483_647
export const PRECIO_MAXIMO = 99_999_999.99
export const CODIGO_LARGO_MAXIMO = 50

export const MOTIVO_STOCK_MAXIMO = 'El stock no puede superar 2.147.483.647 unidades.'
export const MOTIVO_STOCK_MINIMO_MAXIMO = 'El stock mínimo no puede superar 2.147.483.647 unidades.'
export const MOTIVO_PRECIO_MAXIMO = 'El precio no puede superar $ 99.999.999,99.'
export const MOTIVO_CODIGO_LARGO = 'El código no puede tener más de 50 caracteres.'
