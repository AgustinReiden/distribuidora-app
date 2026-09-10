/**
 * Semáforo de vencimientos (migs 223/224/225).
 *
 * ACÁ VIVE LA REGLA, Y EN UN SOLO LADO
 * ------------------------------------
 * `reporte_vencimientos()` devuelve la fecha y los días que faltan, pero **no**
 * el color. Calcular el semáforo también en SQL crearía un espejo que se
 * desincroniza — que es exactamente el problema que obligó a escribir el gate
 * `espejo-motor-compras.mjs` para el motor de costos.
 *
 * Por la misma razón el front nunca usa el `dias_restantes` que devuelve la RPC:
 * lo recalcula desde `fecha_vencimiento` con `diasHasta`. Si no, la ficha (que
 * lee `producto_lotes` directo y no tiene esa columna) y el panel podrían
 * mostrar números distintos para el mismo lote cuando el día del servidor y el
 * del navegador no coinciden.
 *
 * LAS FECHAS SE COMPARAN COMO CALENDARIO, NO COMO INSTANTES
 * ---------------------------------------------------------
 * `fecha_vencimiento` es un `date` de Postgres: llega como 'YYYY-MM-DD' y no
 * tiene hora ni zona. `new Date('2026-10-01')` lo interpreta como medianoche
 * UTC, que en Argentina es el 30/09 a las 21:00 — o sea, un día menos. Por eso
 * acá no se construyen Date a partir del string: se parsea a mano y se compara
 * con `Date.UTC`, que es aritmética de calendario pura.
 */

export type EstadoVencimiento = 'vencido' | 'critico' | 'alerta' | 'ok'

/** La fecha de hoy del navegador, como 'YYYY-MM-DD'. */
export function hoyISO(): string {
  const ahora = new Date()
  const mes = String(ahora.getMonth() + 1).padStart(2, '0')
  const dia = String(ahora.getDate()).padStart(2, '0')
  return `${ahora.getFullYear()}-${mes}-${dia}`
}

/** Milisegundos UTC del comienzo de una fecha 'YYYY-MM-DD'. NaN si no parsea. */
function aUTC(fecha: string): number {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(fecha ?? '')
  if (!m) return NaN
  return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
}

/**
 * Días de calendario entre hoy y la fecha. Negativo = ya venció.
 *
 * Devuelve NaN si alguna fecha no parsea, para que quien la use decida qué
 * hacer en vez de comerse un 0 que parecería "vence hoy".
 */
export function diasHasta(fecha: string, hoy: string = hoyISO()): number {
  const destino = aUTC(fecha)
  const origen = aUTC(hoy)
  if (Number.isNaN(destino) || Number.isNaN(origen)) return NaN
  return Math.round((destino - origen) / 86_400_000)
}

/**
 * El color del lote, según los dos umbrales de la sucursal.
 *
 * - `vencido`: la fecha ya pasó. No bloquea la venta, es una decisión de
 *   negocio: un dato mal tipeado no puede frenar la operación.
 * - `critico`: entra dentro del umbral rojo. Hay que liquidarlo ya.
 * - `alerta`: entra dentro del umbral amarillo. Todavía se coloca normal.
 * - `ok`: falta.
 *
 * Los umbrales son inclusivos: con `diasCritico = 15`, un lote que vence en
 * exactamente 15 días ya es crítico. Es lo que espera quien configuró "avisame
 * 15 días antes".
 *
 * Con umbrales en 0 solo se marca lo ya vencido, que es la forma de tener la
 * feature prendida sin que avise de nada por adelantado.
 */
export function estadoVencimiento(
  fecha: string,
  diasAlerta: number,
  diasCritico: number,
  hoy: string = hoyISO(),
): EstadoVencimiento {
  const dias = diasHasta(fecha, hoy)
  // Una fecha ilegible no es un vencimiento: no se inventa una alarma.
  if (Number.isNaN(dias)) return 'ok'
  if (dias < 0) return 'vencido'
  if (dias <= diasCritico) return 'critico'
  if (dias <= diasAlerta) return 'alerta'
  return 'ok'
}

/** Texto corto para la UI: "vencido hace 3 días", "vence en 12 días", "vence hoy". */
export function textoVencimiento(fecha: string, hoy: string = hoyISO()): string {
  const dias = diasHasta(fecha, hoy)
  if (Number.isNaN(dias)) return 'sin fecha'
  if (dias === 0) return 'vence hoy'
  if (dias < 0) {
    const d = Math.abs(dias)
    return `vencido hace ${d} ${d === 1 ? 'día' : 'días'}`
  }
  return `vence en ${dias} ${dias === 1 ? 'día' : 'días'}`
}

/**
 * Lo que queda sin vencimiento cargado: la bolsa.
 *
 * Es una resta y no una fila en ninguna tabla — ver el encabezado de la mig 223.
 * Nunca negativa: el invariante LOTE-A lo garantiza del lado de la base, y acá
 * se recorta igual para que un dato viejo en caché no pinte un número absurdo.
 */
export function bolsaSinVencimiento(stock: number, asignadoALotes: number): number {
  return Math.max(0, (Number(stock) || 0) - (Number(asignadoALotes) || 0))
}

/**
 * Aplana las líneas de una compra al payload de `sincronizar_lotes_compra`,
 * agrupando por (producto, fecha).
 *
 * Agrupa acá y no solo en la RPC porque el mismo producto puede aparecer en dos
 * líneas de la misma factura con la misma fecha, y dos filas con esa clave
 * violarían el UNIQUE de `producto_lotes`. La RPC vuelve a agrupar igual — es
 * barato y no depende de que el cliente lo haga bien.
 *
 * Se descartan las entradas sin fecha o con cantidad no positiva: son filas a
 * medio tipear, y mandarlas haría fallar la carga de los vencimientos entera
 * por algo que el usuario simplemente no terminó de completar.
 */
export function aplanarVencimientos(
  items: { productoId: string; vencimientos?: { fecha: string; cantidad: number }[] }[],
): { producto_id: number; fecha_vencimiento: string; cantidad: number }[] {
  const acumulado = new Map<string, { producto_id: number; fecha_vencimiento: string; cantidad: number }>()

  for (const item of items) {
    const productoId = Number(item.productoId)
    if (!Number.isFinite(productoId)) continue

    for (const v of item.vencimientos ?? []) {
      const cantidad = Number(v.cantidad) || 0
      if (!v.fecha || cantidad <= 0) continue

      const clave = `${productoId}|${v.fecha}`
      const previo = acumulado.get(clave)
      if (previo) {
        previo.cantidad += cantidad
      } else {
        acumulado.set(clave, { producto_id: productoId, fecha_vencimiento: v.fecha, cantidad })
      }
    }
  }

  return [...acumulado.values()]
}

/**
 * La fecha en dd/mm/aaaa.
 *
 * Sin construir un Date, por lo mismo que `diasHasta`: `new Date('2026-10-01')`
 * es medianoche UTC y en Argentina imprime el 30/09.
 */
export function formatearFechaVencimiento(fecha: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(fecha ?? '')
  return m ? `${m[3]}/${m[2]}/${m[1]}` : '\u2014'
}
