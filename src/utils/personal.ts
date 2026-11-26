/**
 * Reglas puras del módulo Personal (entrega 3 de gastos): textos del arreglo, concepto de
 * cada movimiento de la cuenta, filtros y las validaciones que el server repite con los
 * mismos mensajes. Las fechas son 'YYYY-MM-DD' y se manejan con aritmética de calendario
 * (UTC), nunca con la zona del navegador.
 */
import type {
  ArregloEmpleado,
  CargoRotura,
  Empleado,
  FiltroPersonal,
  FrecuenciaSueldo,
  GuardarArregloPayload,
  LineaCargo,
  MovimientoEmpleado,
  MovimientoManualPayload,
  PeriodoLiquidacion,
  PeriodoPendiente,
  PlataDelPago,
  PuestoEmpleado,
  RendicionDelDia,
  VistaPreviaLiquidacion,
} from '../types/personal'
import { formatPrecio } from './formatters'
import { leerNumero } from './normalizarNumero'
import { redondear } from './calculations'
import { normalizarBusqueda } from './filtrarOpciones'
import { efectivoAEntregar } from './rendicionGastos'

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
 * Es el lector de toda la app (`leerNumero`, B20: un solo lector por campo), sin signo (lo dan los
 * botones) y al centavo. Más de dos decimales («1,500», la tecla del punto tipeada por costumbre)
 * se guardan al centavo, con el aviso amarillo del campo (decisión del dueño, 17/11).
 */
export function parseMonto(texto: string): number | null {
  if (/^\s*[$]?\s*[-−]/.test(texto)) return null
  const n = leerNumero(texto)
  if (n === null || n < 0) return null
  return redondear(n, 2)
}

const conPuntosDeMiles = (digitos: string): string => digitos.replace(/\B(?=(\d{3})+(?!\d))/g, '.')

/**
 * 500000 → «500.000» y 8677.5 → «8.677,50»: un importe guardado, listo para editar. Un negativo
 * conserva el signo, que `parseMonto` rechaza: un neto calculado en rojo no se guarda callado.
 */
export function montoATexto(n: number): string {
  const [entero, decimales] = Math.abs(n).toFixed(2).split('.')
  const signo = n < 0 && Number(`${entero}.${decimales}`) > 0 ? '-' : ''
  return signo + (decimales === '00' ? conPuntosDeMiles(entero) : `${conPuntosDeMiles(entero)},${decimales}`)
}

/**
 * Reparte un costo en `n` partes iguales, en centavos: lo que sobra va a la primera
 * (1000 en 3 → 333,34 · 333,33 · 333,33). La suma siempre da el total.
 */
export function repartirCosto(total: number, n: number): number[] {
  if (n <= 0) return []
  const centavos = Math.round(Math.max(total, 0) * 100)
  const base = Math.floor(centavos / n)
  const resto = centavos - base * n
  return Array.from({ length: n }, (_, i) => (base + (i === 0 ? resto : 0)) / 100)
}

export const MENSAJE_CARGO_INCOMPLETO = 'Completá el empleado y el monto de cada línea, o quitá la que no uses'
export const MENSAJE_CARGO_EN_CERO = 'El monto que se le carga a cada empleado tiene que ser mayor a cero'
export const MENSAJE_CARGO_REPETIDO = 'No podés cargarle a un empleado más de una vez: sumá los montos en una sola línea'

/**
 * Las líneas de «A cargo de empleados» listas para `p_cargos`: sin líneas es `null` (nada que
 * cobrar). Una línea a medias o con un monto que `parseMonto` no entiende no se manda: bloquea.
 */
export function armarCargos(lineas: ReadonlyArray<LineaCargo>): { cargos: CargoRotura[] | null; error: string | null } {
  if (lineas.length === 0) return { cargos: null, error: null }
  const cargos: CargoRotura[] = []
  for (const l of lineas) {
    const monto = parseMonto(l.monto)
    if (l.empleado_id === null || monto === null) return { cargos: null, error: MENSAJE_CARGO_INCOMPLETO }
    if (!(monto > 0)) return { cargos: null, error: MENSAJE_CARGO_EN_CERO }
    cargos.push({ empleado_id: l.empleado_id, monto })
  }
  if (new Set(cargos.map(c => c.empleado_id)).size !== cargos.length) {
    return { cargos: null, error: MENSAJE_CARGO_REPETIDO }
  }
  return { cargos, error: null }
}

/** Lo que se le muestra a quien tipeó un importe que `parseMonto` no entiende. */
export const MENSAJE_MONTO_ILEGIBLE = 'Escribí el monto con números, por ejemplo 280000 (se ve 280.000) o 280000,50'

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
  faltante: 'Se deshizo un faltante de rendición',
  rotura: 'Revierte una rotura',
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
    case 'faltante':
      return {
        titulo: m.rendicion
          ? `Faltante de rendición del ${diaYMes(m.rendicion.fecha)} (${m.rendicion.transportista_nombre})`
          : 'Faltante de rendición',
        detalle: observacion,
      }
    case 'rotura':
      return { titulo: 'Rotura a su cargo', detalle: observacion }
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

/** Un arreglo nuevo vale desde una fecha a no más de estos días de hoy, para cada lado (GTO-3, #1521). */
export const DIAS_TOPE_ARREGLO = 60

/** Hoy ± `DIAS_TOPE_ARREGLO` días, 'YYYY-MM-DD'. */
export function topeDeArreglo(hoy: string): { min: string; max: string } {
  const ms = msUTC(hoy)
  const dia = 86_400_000
  return { min: isoDeMs(ms - DIAS_TOPE_ARREGLO * dia), max: isoDeMs(ms + DIAS_TOPE_ARREGLO * dia) }
}

/** La fecha desde la que vale un arreglo, contra el tope. */
export function errorDeDesdeArreglo(desde: string, hoy: string): string | null {
  const { min, max } = topeDeArreglo(hoy)
  if (desde >= min && desde <= max) return null
  return `El arreglo vale desde una fecha entre el ${fechaCompleta(min)} y el ${fechaCompleta(max)} (hasta ${DIAS_TOPE_ARREGLO} días antes o después de hoy)`
}

/** El mensaje de `guardar_empleado` ante una fecha de ingreso futura (1597-b6, #1597). */
export const MENSAJE_INGRESO_FUTURO = 'La fecha de ingreso no puede ser futura'

/**
 * La fecha de ingreso no es futura. Como en el server, rige al cargarla o al cambiarla: una ficha
 * que ya la tiene así (`original`) se sigue editando sin tocarla. Vacía no se mide.
 */
export function errorDeFechaIngreso(fecha: string, original: string | null, hoy: string): string | null {
  if (!fecha || fecha === (original ?? '')) return null
  return fecha > hoy ? MENSAJE_INGRESO_FUTURO : null
}

/**
 * La fecha de un gasto, de un movimiento de empleado y del pago de una liquidación va hasta estos
 * días antes de hoy, para todos (GTO-A, #1545; decisión del dueño, 12/11).
 */
export const DIAS_ATRAS_FECHA_CARGA = 60

/** El primer día que se puede cargar: hoy − `DIAS_ATRAS_FECHA_CARGA`, 'YYYY-MM-DD'. */
export function pisoDeFechaDeCarga(hoy: string): string {
  return isoDeMs(msUTC(hoy) - DIAS_ATRAS_FECHA_CARGA * 86_400_000)
}

/**
 * El piso de una fecha que se tipea, con el mensaje de `_fecha_carga_validar_piso`. `deQue` lo
 * completa: «del gasto», «del movimiento», «del pago». La fecha que sale de una rendición no se
 * tipea y no pasa por acá: el server la exime sólo si esa rendición existe (GTO-1, #1562,
 * `_fecha_rendicion_validar_piso`), y el front no lo puede saber.
 */
export function errorDeFechaVieja(fecha: string, hoy: string, deQue: string): string | null {
  const piso = pisoDeFechaDeCarga(hoy)
  if (fecha >= piso) return null
  return `La fecha ${deQue} no puede ser anterior al ${fechaCompleta(piso)} (hasta ${DIAS_ATRAS_FECHA_CARGA} días antes de hoy)`
}

/**
 * `vigente` es el último arreglo del empleado y `anterior`, el que tenía antes. La baja la valida
 * el server. Con `a.id` se corrige el último arreglo, también su fecha; sin `id`, un arreglo con
 * la misma fecha que el vigente lo corrige (sin tope) y uno con otra fecha es nuevo.
 * Sin `hoy` no se mide el tope.
 */
export function errorDeArreglo(
  a: GuardarArregloPayload,
  vigente: ArregloEmpleado | null,
  hoy?: string,
  anterior: ArregloEmpleado | null = null,
): string | null {
  if (a.sueldo < 0) return 'El sueldo no puede ser negativo'
  if (a.sueldo === 0 && !a.comisiona) return 'Un arreglo sin sueldo fijo tiene que comisionar'
  const tope = (): string | null => (hoy === undefined ? null : errorDeDesdeArreglo(a.vigente_desde, hoy))
  if (a.id !== undefined) {
    if (!vigente || a.id !== vigente.id) return 'Sólo se corrige el último arreglo del empleado'
    if (a.vigente_desde === vigente.vigente_desde) return null
    if (anterior && a.vigente_desde <= anterior.vigente_desde) {
      return `El arreglo corregido vale desde después del anterior (${fechaCompleta(anterior.vigente_desde)})`
    }
    return tope()
  }
  if (vigente && a.vigente_desde < vigente.vigente_desde) {
    return `Un arreglo nuevo vale desde después del vigente (${fechaCompleta(vigente.vigente_desde)}): para cambiarle la fecha al vigente, elegí «Corregir el vigente»`
  }
  if (vigente && a.vigente_desde === vigente.vigente_desde) return null
  return tope()
}

/**
 * `saldo` (+ la empresa le debe) topa el pago: con saldo ≤ 0 no se le puede pagar nada. El
 * adelanto no tiene tope (GTO-8, #1521). Si el pago sale de una rendición, el server mira también
 * el efectivo de ésa. Con `hoy` en null no se miden las fechas (el schema del modal no lo conoce).
 */
export function errorDeMovimiento(m: MovimientoManualPayload, hoy: string | null, saldo?: number): string | null {
  if (m.tipo === 'adelanto' || m.tipo === 'pago') {
    if (!(m.monto > 0)) return 'El monto tiene que ser mayor a cero'
    if (m.tipo === 'pago' && saldo !== undefined && m.monto - Math.max(saldo, 0) >= 0.005) {
      return 'No se le puede pagar más de lo que se le debe: si le adelantás plata, cargá un adelanto'
    }
  } else {
    if (m.monto === 0) return 'El ajuste no puede ser cero'
    if (!m.observacion?.trim()) return 'El ajuste necesita una observación que diga por qué'
  }
  if (hoy === null) return null
  if (m.fecha > hoy) return 'La fecha del movimiento no puede ser futura'
  // GTO-A (#1545): ni anterior al piso. El pago que sale de una rendición lleva el día de esa
  // rendición, que no se tipea. Si esa rendición no existe, el piso lo pone el server (#1562).
  const deRendicion = m.tipo === 'pago' && m.origen_pago === 'rendicion'
  return deRendicion ? null : errorDeFechaVieja(m.fecha, hoy, 'del movimiento')
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
export function errorDePago(
  pago: number,
  tope: number,
  fecha: string,
  hoy: string,
  deRendicion = false,
): string | null {
  if (pago < 0) return 'El pago no puede ser negativo'
  if (pago > Math.max(tope, 0) + 0.005) {
    return 'No se le puede pagar más de lo que le toca: si le adelantás plata, cargá un adelanto'
  }
  if (fecha > hoy) return 'La fecha del pago no puede ser futura'
  // GTO-A (#1545): ni anterior al piso, salvo el día de la rendición de la que sale el pago. Si esa
  // rendición no existe, el piso lo pone el server (#1562).
  return deRendicion ? null : errorDeFechaVieja(fecha, hoy, 'del pago')
}

/** El pago que sale de la oficina: no toca ninguna rendición. */
export const PLATA_OFICINA: PlataDelPago = {
  origen_pago: 'oficina',
  rendicion_transportista_id: null,
  rendicion_fecha: null,
}

export const MENSAJE_SIN_RENDICION_DEL_PAGO = 'Elegí de qué rendición sale la plata: el transportista y el día'

/** #1534: el mismo mensaje con que `liquidar_empleado` y `registrar_movimiento_empleado` lo rechazan. */
export const MENSAJE_SUPERA_EFECTIVO = 'El pago supera el efectivo que le queda por entregar a esa rendición'

/**
 * #1534: de una rendición no sale más efectivo del que le queda por entregar (el tope del server,
 * `_rendicion_efectivo_a_entregar`, con la cuenta de la grilla de rendiciones). `null` si entra o si
 * todavía no se sabe el efectivo (el server lo vuelve a mirar con la rendición bloqueada).
 */
export function errorDePagoDeRendicion(pago: number, efectivo: number | null): string | null {
  if (efectivo === null) return null
  return pago > efectivo + 0.005 ? MENSAJE_SUPERA_EFECTIVO : null
}

/** Una fila de `obtener_resumen_rendiciones`, con lo que hace falta para pagar con su plata. */
export interface FilaResumenRendicion {
  transportista_id: string | null
  transportista_nombre: string | null
  total_efectivo: number | string | null
  total_gastos: number | string | null
  total_pagos_personal: number | string | null
  total_faltantes_empleados: number | string | null
  estado: string | null
}

/**
 * Las rendiciones de un día (#1534, m7 de #1392): quién tiene rendición, con la regla del server (la
 * grilla de rendiciones: cobró, entregó o pagó con esa plata ese día, sea chofer o encargado), y el
 * efectivo que le queda por entregar, con la misma cuenta del cierre (`efectivoAEntregar`).
 */
export function rendicionesDelDia(filas: ReadonlyArray<FilaResumenRendicion> | null | undefined): RendicionDelDia[] {
  return (filas ?? []).flatMap(f => (f.transportista_id
    ? [{
      transportista_id: f.transportista_id,
      transportista_nombre: f.transportista_nombre || 'Sin nombre',
      efectivo_a_entregar: efectivoAEntregar(
        Number(f.total_efectivo) || 0,
        Number(f.total_gastos) || 0,
        Number(f.total_pagos_personal) || 0,
        Number(f.total_faltantes_empleados) || 0,
      ),
      cerrada: f.estado === 'confirmada' || f.estado === 'resuelta',
    }]
    : []))
}

/**
 * m7 (#1392): los que se pueden elegir como «la plata de una rendición». Los transportistas (los de
 * siempre) más quien tiene rendición ese día aunque no sea chofer (un encargado que cobró él mismo),
 * sin repetir, por nombre.
 */
export function opcionesDePlata(
  transportistas: ReadonlyArray<{ id: string; nombre: string }>,
  delDia: ReadonlyArray<RendicionDelDia>,
): Array<{ id: string; nombre: string }> {
  const vistos = new Set(transportistas.map(t => t.id))
  const extra = delDia
    .filter(r => !vistos.has(r.transportista_id))
    .map(r => ({ id: r.transportista_id, nombre: r.transportista_nombre }))
  return [...transportistas, ...extra].sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'))
}

/** m2 (#1392): por qué un movimiento que se revertiría no se revierte. `null` si nada lo impide. */
export function motivoSinReversion(m: Pick<MovimientoEmpleado, 'tipo' | 'rendicion'>): string | null {
  return m.tipo === 'pago' && m.rendicion?.cerrada === true
    ? 'Salió de una rendición ya cerrada: corregilo con un ajuste'
    : null
}

/**
 * m4 (#1392, decisión del dueño del 25/11): lo pendiente no se arrastra de una sucursal a otra. El
 * mismo mensaje con que `guardar_empleado` lo rechaza. `null` si no tiene comisión sin liquidar.
 */
export function avisoComisionSinLiquidar(monto: number, sucursal: string): string | null {
  if (Math.abs(monto) < 0.005) return null
  const plata = formatPrecio(Math.abs(monto))
  return `Tiene ${monto < 0 ? '-' : ''}${plata} de comisión sin liquidar en ${sucursal}: liquidalo antes de pasarlo de sucursal`
}
