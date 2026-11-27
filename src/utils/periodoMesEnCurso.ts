/**
 * Período «mes en curso» del panel de Pedidos y su rótulo.
 *
 * Decisión del dueño (27/11): el panel arranca en el mes en curso, del 1 hasta
 * hoy, igual que Metas, y arriba de los totales dice qué período cuentan. Antes
 * arrancaba 30 días atrás: el 27/11 contaba desde el 28/10 y no coincidía con Metas.
 *
 * Todo en día argentino (`fechaLocalISO`): a las 22 h del último día del mes en UTC
 * ya es el mes siguiente, y `new Date().toISOString()` daría el 1 del mes que viene.
 */
import { fechaLocalISO } from './formatters'

const MESES = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
] as const

const ISO = /^(\d{4})-(\d{2})-(\d{2})$/

function partes(iso: string): { y: number; m: number; d: number } | null {
  const r = ISO.exec(iso)
  return r ? { y: Number(r[1]), m: Number(r[2]), d: Number(r[3]) } : null
}

function fechaCorta(iso: string): string {
  const p = partes(iso)
  return p ? `${p.d} de ${MESES[p.m - 1]}` : iso
}

/** El 1 del mes del día argentino de `base` ('YYYY-MM-DD'). */
export function primerDiaDelMesEnCurso(base: Date = new Date()): string {
  return `${fechaLocalISO(base).slice(0, 7)}-01`
}

/**
 * Rótulo del período que cuentan los totales, en palabras simples:
 * «Noviembre · del 1 al 27» (dentro de un mes), «Del 28 de octubre al 27 de
 * noviembre» (cruza de mes), «Todo el historial» (sin límites). Sin `hasta`, el
 * período llega hasta `hoy`. `hoy` se pasa sólo para poder probarlo.
 */
export function rotuloPeriodo(
  desde: string | null | undefined,
  hasta: string | null | undefined,
  hoy: string = fechaLocalISO(),
): string {
  const d = desde ? partes(desde) : null
  const fin = hasta || hoy
  const h = partes(fin)
  if (!desde && !hasta) return 'Todo el historial'
  if (!d) return h ? `Hasta el ${fechaCorta(fin)}` : 'Período elegido'
  if (!h) return 'Período elegido'
  if (d.y === h.y && d.m === h.m) {
    const mes = MESES[d.m - 1]
    const nombre = mes.charAt(0).toUpperCase() + mes.slice(1)
    return d.d === h.d ? `${nombre} · el ${d.d}` : `${nombre} · del ${d.d} al ${h.d}`
  }
  return `Del ${fechaCorta(desde as string)} al ${fechaCorta(fin)}`
}
