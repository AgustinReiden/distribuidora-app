import { fechaLocalISO } from './formatters'
import { diasAtrasVigentes } from './fechaPedido'
import { DIAS_ATRAS_FECHA_CARGA } from './personal'

/**
 * Hasta dónde puede ir la fecha de una entrega (GTO-15, #1597; 1598-b2, #1598).
 *
 * Decisión del dueño: quien no es admin fecha una entrega de hoy hasta
 * `politicas_comerciales.dias_atras_fecha_pedido` días atrás (los de la fecha del pedido, 7
 * por defecto); el admin, hasta 60 días atrás (el piso de la fecha de un gasto); nadie con
 * fecha futura. Es el espejo de `_fecha_entrega_fuera_de_rango` (mig 505), que decide en las
 * entregas masivas y en `pedidos_proteger_columnas` (la entrega de a una por PATCH y la
 * edición). Sin piso, una entrega fechada años atrás fabricaba la "rendición que existe" con
 * la que un gasto viejo se salteaba su piso.
 */
export interface ReglaFechaEntrega {
  esAdmin: boolean
  /** `politicas_comerciales.dias_atras_fecha_pedido` de la sucursal (sólo para quien no es admin). */
  diasAtras: number | null | undefined
  /** Hoy en Argentina, 'YYYY-MM-DD'. */
  hoy?: string
}

/** 'YYYY-MM-DD' menos `dias` días, sobre el día calendario en UTC (como `fechaPedido`). */
function restarDias(iso: string, dias: number): string {
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d) - dias * 86_400_000).toISOString().slice(0, 10)
}

/** 'YYYY-MM-DD' → 'DD/MM/YYYY', como lo escribe el server. */
function ddmmyyyy(iso: string): string {
  const [y, m, d] = iso.split('-')
  return `${d}/${m}/${y}`
}

/** Los días atrás que rigen para ese rol. */
export function diasAtrasFechaEntrega(regla: ReglaFechaEntrega): number {
  return regla.esAdmin ? DIAS_ATRAS_FECHA_CARGA : diasAtrasVigentes(regla.diasAtras)
}

/** El rango que acepta el server para ese rol: `min` y `max` del campo de fecha. */
export function rangoFechaEntrega(regla: ReglaFechaEntrega): { min: string; max: string } {
  const hoy = regla.hoy ?? fechaLocalISO()
  return { min: restarDias(hoy, diasAtrasFechaEntrega(regla)), max: hoy }
}

/**
 * Por qué una fecha de entrega no entra, con el texto del server, o null si entra. Una fecha
 * vacía no se juzga.
 */
export function errorDeFechaEntrega(fecha: string | null | undefined, regla: ReglaFechaEntrega): string | null {
  const f = fecha?.slice(0, 10)
  if (!f) return null
  const { min, max } = rangoFechaEntrega(regla)
  if (f > max) return `La fecha de entrega (${ddmmyyyy(f)}) no puede ser posterior a hoy.`
  if (f >= min) return null
  const dias = diasAtrasFechaEntrega(regla)
  if (regla.esAdmin) {
    return `La fecha de entrega (${ddmmyyyy(f)}) no puede ser anterior al ${ddmmyyyy(min)}: hasta ${dias} días atrás.`
  }
  if (dias === 0) {
    return `La fecha de entrega (${ddmmyyyy(f)}) no puede ser anterior a hoy. Si la entrega es de antes, la carga un admin.`
  }
  return `La fecha de entrega (${ddmmyyyy(f)}) no puede ser anterior al ${ddmmyyyy(min)}: hasta ${dias} ${dias === 1 ? 'día' : 'días'} atrás. Si la entrega es de antes, la carga un admin.`
}
