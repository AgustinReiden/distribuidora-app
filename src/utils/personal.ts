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
  PuestoEmpleado,
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

export function conceptoDeMovimiento(m: MovimientoEmpleado): { titulo: string; detalle: string | null } {
  const observacion = m.observacion?.trim() ? m.observacion : null

  if (m.revierte_id !== null) {
    return {
      titulo: m.tipo === 'adelanto' ? 'Revierte un adelanto en efectivo' : 'Revierte un ajuste',
      detalle: observacion,
    }
  }

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
  }
}

// ---------------------------------------------------------------------------
// Lista
// ---------------------------------------------------------------------------

const conSaldo = (e: Empleado): boolean => estadoSaldo(e.saldo) !== 'al_dia'

function cumpleFiltro(e: Empleado, filtro: FiltroPersonal): boolean {
  if (filtro === 'todos') return e.activo
  if (filtro === 'inactivos') return !e.activo
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

export function filtrarPersonal(empleados: Empleado[], filtro: FiltroPersonal, busqueda: string): Empleado[] {
  const q = normalizarBusqueda(busqueda)
  return empleados
    .filter(e => cumpleFiltro(e, filtro))
    .filter(e => !q || textosDeBusqueda(e).some(t => normalizarBusqueda(t).includes(q)))
    .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'))
}

export function contarPersonal(empleados: Empleado[]): Record<FiltroPersonal, number> {
  return {
    todos: empleados.filter(e => cumpleFiltro(e, 'todos')).length,
    con_saldo: empleados.filter(e => cumpleFiltro(e, 'con_saldo')).length,
    inactivos: empleados.filter(e => cumpleFiltro(e, 'inactivos')).length,
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
  if (m.tipo === 'adelanto') {
    if (!(m.monto > 0)) return 'El monto tiene que ser mayor a cero'
  } else {
    if (m.monto === 0) return 'El ajuste no puede ser cero'
    if (!m.observacion?.trim()) return 'El ajuste necesita una observación que diga por qué'
  }
  if (m.fecha > hoy) return 'La fecha del movimiento no puede ser futura'
  return null
}
