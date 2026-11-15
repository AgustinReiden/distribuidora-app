/**
 * La ficha del producto guarda sólo lo que el usuario cambió (#1561, FRG-5).
 *
 * Mandaba el formulario entero como estaba al abrirse, y `updateProducto`
 * escribe todo campo definido: si con la ficha abierta entraba una compra o un
 * aumento masivo, guardar un cambio de subrubro volvía el precio, el neto y los
 * costos a los de la apertura. Ahora, en la edición, un campo que el usuario no
 * tocó no viaja (`undefined` = "no tocar" en `updateProducto`).
 *
 * Los campos que se calculan juntos viajan juntos:
 *   · condición y alícuota de IVA (un CHECK cruzado las pide coherentes);
 *   · el precio final y el neto, que sale del final y de la alícuota: viajan si
 *     cambió el precio o el IVA;
 *   · los costos (neto, total, internos y su encuadre), porque el total sale del
 *     neto, del IVA y de los internos: viajan si cambió alguno o el IVA;
 *   · el rubro y el subrubro (un trigger valida que el subrubro sea del rubro);
 *   · las unidades del fardo y su etiqueta.
 * El stock, el costo real y el costo promedio tienen su propia regla en la ficha
 * y no pasan por acá.
 */

type Campos = Record<string, unknown>

/** Los campos que se comparan como número ('' y null son "vacío"). */
const NUMERICOS = new Set([
  'stock_minimo', 'cantidad_minima_venta', 'unidades_por_bulto', 'unidades_de_venta_por_fardo',
  'porcentaje_iva', 'precio', 'precio_sin_iva', 'costo_sin_iva', 'costo_con_iva', 'impuestos_internos',
])

function normalizar(campo: string, v: unknown): string | number | null {
  if (v === undefined || v === null) return null
  if (typeof v === 'string' && v.trim() === '') return null
  if (NUMERICOS.has(campo)) {
    const n = typeof v === 'number' ? v : Number(String(v).replace(',', '.'))
    return Number.isFinite(n) ? Math.round(n * 10000) / 10000 : String(v)
  }
  return String(v).trim()
}

function cambio(campo: string, inicial: Campos, actual: Campos): boolean {
  return normalizar(campo, inicial[campo]) !== normalizar(campo, actual[campo])
}

export interface NovedadesDeCatalogo {
  /** Se tipeó un rubro nuevo. */
  categoriaNueva?: boolean
  /** Se tipeó un subrubro nuevo. */
  subrubroNuevo?: boolean
  /** Se tipeó una marca nueva. */
  marcaNueva?: boolean
}

/** Los grupos de campos que no cambiaron: en la edición no se mandan. */
export function camposSinCambios(inicial: object, actual: object, novedades: NovedadesDeCatalogo = {}): string[] {
  const alguno = (...cs: string[]) => cs.some(c => cambio(c, inicial as Campos, actual as Campos))
  const fiscal = alguno('condicion_iva', 'porcentaje_iva')
  const grupos: Array<[string[], boolean]> = [
    [['nombre'], alguno('nombre')],
    [['codigo'], alguno('codigo')],
    [['proveedor_id'], alguno('proveedor_id')],
    [['stock_minimo'], alguno('stock_minimo')],
    [['cantidad_minima_venta'], alguno('cantidad_minima_venta')],
    [['unidades_por_bulto'], alguno('unidades_por_bulto')],
    [['unidades_de_venta_por_fardo', 'etiqueta_bulto'], alguno('unidades_de_venta_por_fardo', 'etiqueta_bulto')],
    [['marca_id'], alguno('marca_id') || !!novedades.marcaNueva],
    [['categoria', 'subcategoria_id'], alguno('categoria', 'subcategoria_id') || !!novedades.categoriaNueva || !!novedades.subrubroNuevo],
    [['condicion_iva', 'porcentaje_iva'], fiscal],
    [['precio', 'precio_sin_iva'], fiscal || alguno('precio')],
    [['costo_sin_iva', 'costo_con_iva', 'impuestos_internos', 'ii_encuadre_id'],
      fiscal || alguno('costo_sin_iva', 'impuestos_internos', 'ii_encuadre_id')],
  ]
  return grupos.filter(([, cambiado]) => !cambiado).flatMap(([cs]) => cs)
}

/**
 * El guardado de la edición sin los campos que no cambiaron (quedan `undefined`).
 * `inicial` es el formulario como se abrió y `actual`, como se guarda.
 */
export function soloLoCambiado<T extends object>(
  guardado: T,
  inicial: object,
  actual: object,
  novedades: NovedadesDeCatalogo = {},
): T {
  const resultado = { ...guardado } as Campos
  for (const c of camposSinCambios(inicial, actual, novedades)) resultado[c] = undefined
  return resultado as unknown as T
}
