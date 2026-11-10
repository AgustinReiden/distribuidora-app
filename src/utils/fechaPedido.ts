import { fechaLocalISO } from './formatters'

/**
 * Hasta dónde puede ir la fecha de un pedido para quien no es admin (#1514).
 *
 * Decisión del dueño (10/11): de hoy hasta `politicas_comerciales.dias_atras_fecha_pedido`
 * días atrás, 7 por defecto, en el día argentino. El admin no tiene piso ni techo. Es el
 * espejo de `_fecha_pedido_fuera_de_rango` (mig 481), que decide en el server el alta
 * (`crear_pedido_completo`) y la edición (`pedidos_proteger_columnas`, por donde pasan
 * `actualizar_fechas_y_notas_pedido` y un PATCH directo).
 *
 * Sin piso, una fecha atrasada medía la promo y el combo en una vigencia que ya había
 * vencido (`fechaReferenciaPromo`: LEAST(fecha, hoy)) y llevaba la venta a otro mes. El
 * piso es también el margen de la cola offline: un pedido encolado más viejo se rechaza al
 * sincronizar con su motivo y queda a la vista en la cola.
 */
export const DIAS_ATRAS_FECHA_PEDIDO_POR_DEFECTO = 7

/** Mismo rango que el CHECK de la columna y la RPC del admin. */
export const DIAS_ATRAS_FECHA_PEDIDO_MAXIMO = 30

/** Los días que rigen: el valor de la política, o el default si no llegó o no se lee. */
export function diasAtrasVigentes(diasAtras: number | null | undefined): number {
  return typeof diasAtras === 'number' && Number.isInteger(diasAtras) && diasAtras >= 0
    ? diasAtras
    : DIAS_ATRAS_FECHA_PEDIDO_POR_DEFECTO
}

/**
 * 'YYYY-MM-DD' menos `dias` días. Se cuenta sobre el día calendario en UTC y no con
 * `setDate`, que depende de la zona del navegador y de los cambios de horario.
 */
function restarDias(iso: string, dias: number): string {
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d) - dias * 86_400_000).toISOString().slice(0, 10)
}

/** La fecha más vieja que puede cargar quien no es admin. */
export function pisoFechaPedido(diasAtras: number | null | undefined, hoy = fechaLocalISO()): string {
  return restarDias(hoy, diasAtrasVigentes(diasAtras))
}

export type FechaPedidoFueraDeRango =
  | { tipo: 'futura' }
  | { tipo: 'anterior'; piso: string; dias: number }

/**
 * Por qué una fecha de pedido no entra para quien no es admin, o null si entra. Una fecha
 * vacía no se juzga: el alta usa la de hoy.
 */
export function fechaPedidoFueraDeRango(
  fecha: string | null | undefined,
  diasAtras: number | null | undefined,
  hoy = fechaLocalISO(),
): FechaPedidoFueraDeRango | null {
  const f = fecha?.slice(0, 10)
  if (!f) return null
  if (f > hoy) return { tipo: 'futura' }
  const piso = pisoFechaPedido(diasAtras, hoy)
  if (f < piso) return { tipo: 'anterior', piso, dias: diasAtrasVigentes(diasAtras) }
  return null
}

/** 'YYYY-MM-DD' → 'DD/MM/YYYY', como lo escribe el server (`to_char(..., 'DD/MM/YYYY')`). */
function ddmmyyyy(iso: string): string {
  const [y, m, d] = iso.split('-')
  return `${d}/${m}/${y}`
}

/** El texto del piso, el mismo en el alta y en la edición. */
export function mensajeFechaAnteriorAlPiso(piso: string, dias: number): string {
  return dias === 0
    ? 'La fecha del pedido no puede ser anterior a hoy. Si el pedido es de antes, lo carga un admin.'
    : `La fecha del pedido no puede ser anterior al ${ddmmyyyy(piso)}: hasta ${dias} ${dias === 1 ? 'día' : 'días'} atrás. Si el pedido es de antes, lo carga un admin.`
}
