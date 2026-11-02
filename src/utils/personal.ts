/**
 * Reglas puras del módulo Personal (entrega 3 de gastos): textos del arreglo, concepto de
 * cada movimiento de la cuenta, filtros y las validaciones que el server repite con los
 * mismos mensajes. Las fechas son 'YYYY-MM-DD' y se manejan con aritmética de calendario
 * (UTC), nunca con la zona del navegador.
 */
import type {
  ArregloEmpleado,
  Empleado,
  FiltroPersonal,
  FrecuenciaSueldo,
  GuardarArregloPayload,
  MovimientoEmpleado,
  MovimientoManualPayload,
  PeriodoLiquidacion,
  PeriodoPendiente,
  PlataDelPago,
  PuestoEmpleado,
  VistaPreviaLiquidacion,
} from '../types/personal'
import { formatPrecio } from './formatters'
import { normalizarBusqueda } from './filtrarOpciones'

export const PUESTOS: ReadonlyArray<{ valor: PuestoEmpleado; etiqueta: string }> = [
  { valor: 'preventista', etiqueta: 'Preventista' },
  { valor: 'transportista', etiqueta: 'Transportista' },
  { valor: 'ayudante', etiqueta: 'Ayudante' },
  { valor: 'deposito', etiqueta: 'Depósito' },
  { valor: 'administracion', etiqueta: 'Administración' },
  { valor: 'encargado', etiqueta: 'Encargado' },
  { valor: 'otro', etiqueta: 'Otro' },
]

export function etiquetaPuesto(p: PuestoEmpleado): string {
  return PUESTOS.find(x => x.valor === p)?.etiqueta ?? p
}

// ---------------------------------------------------------------------------
// Fechas
// ---------------------------------------------------------------------------

/** 'YYYY-MM-DD' -> ms UTC de ese día a las 00:00. */
function msUTC(fecha: string): number {
  const [a, m, d] = fecha.split('-').map(Number)
  return Date.UTC(a, m - 1, d)
}

function isoDeMs(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10)
}

/** 'YYYY-MM-DD' -> 'dd/mm/aaaa'. */
export function fechaCompleta(fecha: string): string {
  const [a, m, d] = fecha.slice(0, 10).split('-')
  return `${d}/${m}/${a}`
}

/**
 * Un importe tipeado, estricto: lo que no entiende da `null`, nunca 0 (un 0 se guarda sin avisar).
 * Los puntos de miles van de a tres ("280.000"); el decimal es la coma ("280.000,50") o, sin
 * miles, el punto con uno o dos dígitos ("12.50"). El signo no se escribe: lo dan los botones.
 * `parsePrecio` sola leería "280.000" como 280.
 */
export function parseMonto(texto: string): number | null {
  const t = texto.trim().replace(/^\$\s*/, '')
  let limpio: string
  if (/^\d{1,3}(\.\d{3})+(,\d{1,2})?$/.test(t)) limpio = t.replace(/\./g, '').replace(',', '.')
  else if (/^\d{1,3}( \d{3})+(,\d{1,2})?$/.test(t)) limpio = t.replace(/ /g, '').replace(',', '.')
  else if (/^\d+(,\d{1,2})?$/.test(t)) limpio = t.replace(',', '.')
  else if (/^\d+\.\d{1,2}$/.test(t)) limpio = t
  else return null
  return Number(limpio)
}

/** Lo que se le muestra a quien tipeó un importe que `parseMonto` no entiende. */
export const MENSAJE_MONTO_ILEGIBLE = 'Escribí el monto con números, por ejemplo 280.000 o 280.000,50'

/** El sueldo se escribe siempre: en blanco no es 0 (un arreglo sin sueldo fijo comisiona y lo dice con un 0). */
export const MENSAJE_SIN_SUELDO = 'Falta el sueldo: poné 0 si es sólo comisión'

/** El lunes de esa semana, o el día 1 de ese mes. */
export function inicioDelPeriodo(fecha: string, frecuencia: FrecuenciaSueldo): string {
  if (frecuencia === 'mensual') return `${fecha.slice(0, 7)}-01`
  const ms = msUTC(fecha)
  const diaSemana = new Date(ms).getUTCDay() // 0 = domingo
  const desdeElLunes = (diaSemana + 6) % 7
  return isoDeMs(ms - desdeElLunes * 86_400_000)
}

/** 'YYYY-MM-DD' -> 'dd/mm'. */
function diaYMes(fecha: string): string {
  const [, m, d] = fecha.slice(0, 10).split('-')
  return `${d}/${m}`
}

/** Días de calendario de `desde` a `hasta` (negativo si `hasta` es anterior). */
function diasEntre(desde: string, hasta: string): number {
  return Math.round((msUTC(hasta) - msUTC(desde)) / 86_400_000)
}

const MESES = [
  'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
]

// ---------------------------------------------------------------------------
// Período de una liquidación
// ---------------------------------------------------------------------------

/** 'Semana 26/10 al 01/11', 'Octubre 2026' (mes entero) o '15/10 al 31/10' (mensual parcial). */
export function textoPeriodo(p: PeriodoLiquidacion): string {
  if (p.frecuencia === 'semanal') return `Semana ${diaYMes(p.desde)} al ${diaYMes(p.hasta)}`
  const [anio, mes] = p.desde.split('-').map(Number)
  const ultimoDia = new Date(Date.UTC(anio, mes, 0)).getUTCDate()
  const mesEntero = p.desde === `${p.desde.slice(0, 7)}-01` && p.hasta === `${p.desde.slice(0, 7)}-${String(ultimoDia).padStart(2, '0')}`
  if (mesEntero) return `${MESES[mes - 1]} ${anio}`
  return `${diaYMes(p.desde)} al ${diaYMes(p.hasta)}`
}

/**
 * La pastilla "sin liquidar" aparece dos días antes de que termine el período, y no después:
 * los semanales se pagan el viernes o el sábado, y si no el filtro "Para liquidar" estaría
 * vacío justo ese día (decisión 14 del plan).
 */
const DIAS_ANTES_DE_CERRAR = 2

export function paraLiquidar(p: PeriodoPendiente | null, hoy: string): boolean {
  if (!p) return false
  return p.desde <= hoy && diasEntre(hoy, p.hasta) <= DIAS_ANTES_DE_CERRAR
}

/** Lo que se le debe pagar con el sueldo dado: saldo + sueldo + comisiones + ajustes. */
export function aPagar(
  v: Pick<VistaPreviaLiquidacion, 'saldo_actual'> & {
    comisiones: Pick<VistaPreviaLiquidacion['comisiones'], 'total'>
    ajustes: Pick<VistaPreviaLiquidacion['ajustes'], 'total'>
  },
  sueldo: number,
): number {
  return Math.round((v.saldo_actual + sueldo + v.comisiones.total + v.ajustes.total) * 100) / 100
}

// ---------------------------------------------------------------------------
// Arreglo
// ---------------------------------------------------------------------------

export function textoArregloCorto(a: Pick<ArregloEmpleado, 'sueldo' | 'frecuencia' | 'comisiona'>): string {
  const frecuencia = a.frecuencia === 'semanal' ? 'Semanal' : 'Mensual'
  if (!(a.sueldo > 0)) return `${frecuencia} · sólo comisión`
  return `${frecuencia} · ${formatPrecio(a.sueldo)}${a.comisiona ? ' + comisión' : ''}`
}

const porPeriodo = (f: FrecuenciaSueldo): string => (f === 'semanal' ? 'por semana' : 'por mes')

export function textoArregloLargo(a: ArregloEmpleado): string {
  return `${formatPrecio(a.sueldo)} ${porPeriodo(a.frecuencia)} · ${a.comisiona ? 'comisiona' : 'no comisiona'} · desde el ${fechaCompleta(a.vigente_desde)}`
}

export function textoArregloAnterior(a: ArregloEmpleado): string {
  const hasta = a.vigente_hasta ? ` al ${fechaCompleta(a.vigente_hasta)}` : ''
  return `Antes: ${formatPrecio(a.sueldo)} ${porPeriodo(a.frecuencia)}, del ${fechaCompleta(a.vigente_desde)}${hasta}`
}

// ---------------------------------------------------------------------------
// Saldo y movimientos
// ---------------------------------------------------------------------------

export function estadoSaldo(saldo: number): 'a_favor' | 'debe' | 'al_dia' {
  if (Math.abs(saldo) < 0.005) return 'al_dia'
  return saldo > 0 ? 'a_favor' : 'debe'
}

/** Mercadería y reintegro no se revierten a mano; caen en el título de siempre. */
const TITULO_REVERSION: Partial<Record<MovimientoEmpleado['tipo'], string>> = {
  adelanto: 'Revierte un adelanto en efectivo',
  sueldo: 'Revierte un sueldo',
  comision: 'Revierte una comisión',
  ajuste_comision: 'Revierte un ajuste de comisión',
  pago: 'Revierte un pago',
}

/** Lo que hace falta para titular un movimiento: lo comparten la cuenta y la vista previa de la liquidación. */
export type MovimientoParaConcepto =
  Pick<MovimientoEmpleado, 'tipo' | 'monto' | 'observacion' | 'pedido_id' | 'gasto' | 'revierte_id' | 'liquidacion' | 'rendicion'>

export function conceptoDeMovimiento(m: MovimientoParaConcepto): { titulo: string; detalle: string | null } {
  const observacion = m.observacion?.trim() ? m.observacion : null

  if (m.revierte_id !== null) {
    return { titulo: TITULO_REVERSION[m.tipo] ?? 'Revierte un ajuste', detalle: observacion }
  }

  const periodo = m.liquidacion ? textoPeriodo(m.liquidacion) : ''
  const rendicion = m.rendicion
    ? `salió de la rendición de ${m.rendicion.transportista_nombre} del ${diaYMes(m.rendicion.fecha)}`
    : null

  switch (m.tipo) {
    case 'mercaderia':
      return {
        titulo: 'Mercadería',
        detalle: observacion ?? (m.pedido_id !== null
          ? `Pedido #${m.pedido_id} · pagado con adelanto de sueldo`
          : 'Pago a cuenta · pagado con adelanto de sueldo'),
      }
    case 'reintegro': {
      const origen = m.gasto ? [m.gasto.rubro, m.gasto.vehiculo].filter(Boolean).join(' ') : ''
      return {
        titulo: 'Reintegro de gasto',
        detalle: observacion ?? (origen ? `${origen} · pagó con plata propia` : 'Pagó con plata propia'),
      }
    }
    case 'adelanto':
      return { titulo: 'Adelanto en efectivo', detalle: observacion }
    case 'ajuste':
      return { titulo: m.monto < 0 ? 'Ajuste en contra' : 'Ajuste a favor', detalle: observacion }
    case 'sueldo':
      return { titulo: 'Sueldo fijo', detalle: observacion ? `${periodo} · ${observacion}` : periodo }
    case 'comision': {
      const n = m.liquidacion?.pedidos ?? 0
      return { titulo: 'Comisión', detalle: `${n} ${n === 1 ? 'pedido' : 'pedidos'} · ${periodo}` }
    }
    case 'ajuste_comision':
      return { titulo: 'Ajuste de comisión', detalle: periodo }
    case 'pago': {
      if (m.liquidacion) {
        const liq = `Liquidación ${periodo}${m.liquidacion.anulada ? ', anulada' : ''}`
        return { titulo: 'Pago', detalle: `${liq} · ${rendicion ?? 'la pagó la oficina'}` }
      }
      return { titulo: 'Pago', detalle: observacion ?? `Pago suelto · ${rendicion ?? 'lo pagó la oficina'}` }
    }
  }
}

// ---------------------------------------------------------------------------
// Lista
// ---------------------------------------------------------------------------

const conSaldo = (e: Empleado): boolean => estadoSaldo(e.saldo) !== 'al_dia'

function cumpleFiltro(e: Empleado, filtro: FiltroPersonal, hoy: string): boolean {
  if (filtro === 'todos') return e.activo
  if (filtro === 'inactivos') return !e.activo
  if (filtro === 'para_liquidar') return paraLiquidar(e.periodo, hoy) // activos o no: el que se fue cobra lo que vendió
  return conSaldo(e) // con_saldo: activos o no, porque el que se fue debiendo importa
}

function textosDeBusqueda(e: Empleado): string[] {
  return [
    e.nombre,
    etiquetaPuesto(e.puesto),
    e.usuario?.nombre ?? '',
    e.cliente?.nombre_fantasia ?? '',
    e.vehiculo?.patente ?? '',
  ]
}

export function filtrarPersonal(empleados: Empleado[], filtro: FiltroPersonal, busqueda: string, hoy: string): Empleado[] {
  const q = normalizarBusqueda(busqueda)
  return empleados
    .filter(e => cumpleFiltro(e, filtro, hoy))
    .filter(e => !q || textosDeBusqueda(e).some(t => normalizarBusqueda(t).includes(q)))
    .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'))
}

export function contarPersonal(empleados: Empleado[], hoy: string): Record<FiltroPersonal, number> {
  return {
    todos: empleados.filter(e => cumpleFiltro(e, 'todos', hoy)).length,
    para_liquidar: empleados.filter(e => cumpleFiltro(e, 'para_liquidar', hoy)).length,
    con_saldo: empleados.filter(e => cumpleFiltro(e, 'con_saldo', hoy)).length,
    inactivos: empleados.filter(e => cumpleFiltro(e, 'inactivos', hoy)).length,
  }
}

// ---------------------------------------------------------------------------
// CUIL
// ---------------------------------------------------------------------------

/** Deja los dígitos, o `null` si no queda ninguno. */
export function normalizarCuil(texto: string): string | null {
  const digitos = texto.replace(/\D/g, '')
  return digitos === '' ? null : digitos
}

/** '20301234567' -> '20-30123456-7'. Si no son 11 dígitos, lo deja como está. */
export function formatCuil(cuil: string): string {
  const d = cuil.replace(/\D/g, '')
  return d.length === 11 ? `${d.slice(0, 2)}-${d.slice(2, 10)}-${d.slice(10)}` : cuil
}

// ---------------------------------------------------------------------------
// Validaciones (mismos mensajes que el server)
// ---------------------------------------------------------------------------

/** `vigente` es el último arreglo del empleado. La baja la valida el server. */
export function errorDeArreglo(a: GuardarArregloPayload, vigente: ArregloEmpleado | null): string | null {
  if (a.sueldo < 0) return 'El sueldo no puede ser negativo'
  if (a.sueldo === 0 && !a.comisiona) return 'Un arreglo sin sueldo fijo tiene que comisionar'
  if (vigente && a.vigente_desde < vigente.vigente_desde) {
    return `Un arreglo nuevo vale desde después del vigente (${fechaCompleta(vigente.vigente_desde)}): para corregir el vigente usá su misma fecha`
  }
  return null
}

export function errorDeMovimiento(m: MovimientoManualPayload, hoy: string): string | null {
  if (m.tipo === 'adelanto' || m.tipo === 'pago') {
    if (!(m.monto > 0)) return 'El monto tiene que ser mayor a cero'
  } else {
    if (m.monto === 0) return 'El ajuste no puede ser cero'
    if (!m.observacion?.trim()) return 'El ajuste necesita una observación que diga por qué'
  }
  if (m.fecha > hoy) return 'La fecha del movimiento no puede ser futura'
  return null
}

/** El sueldo de una liquidación: no negativo, y si se corrige respecto del arreglo, con motivo. */
export function errorDeSueldo(sueldo: number, propuesto: number, motivo: string | null): string | null {
  if (sueldo < 0) return 'El sueldo no puede ser negativo'
  if (Math.abs(sueldo - propuesto) >= 0.005 && !motivo?.trim()) return 'Escribí por qué cambia el sueldo'
  return null
}

/**
 * El pago de una liquidación va de 0 a lo que le toca (`tope` = `aPagar`). Al que debe se le
 * puede pagar 0: el tope negativo se trata como 0. Más que eso es un adelanto, y se carga aparte.
 */
export function errorDePago(pago: number, tope: number, fecha: string, hoy: string): string | null {
  if (pago < 0) return 'El pago no puede ser negativo'
  if (pago > Math.max(tope, 0) + 0.005) {
    return 'No se le puede pagar más de lo que le toca: si le adelantás plata, cargá un adelanto'
  }
  if (fecha > hoy) return 'La fecha del pago no puede ser futura'
  return null
}

/** El pago que sale de la oficina: no toca ninguna rendición. */
export const PLATA_OFICINA: PlataDelPago = {
  origen_pago: 'oficina',
  rendicion_transportista_id: null,
  rendicion_fecha: null,
}

export const MENSAJE_SIN_RENDICION_DEL_PAGO = 'Elegí de qué rendición sale la plata: el transportista y el día'
