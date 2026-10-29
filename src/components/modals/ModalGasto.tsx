/**
 * ModalGasto — registrar o editar un gasto (entrega 1 de gastos).
 *
 * Arranca con lo mínimo (rubro, monto, fecha, comprobante, sucursal y mes) y el
 * resto aparece según lo que se elige: el bloque de IVA con factura A o M, el
 * vehículo con un rubro de Vehículos, los litros y km con Combustible, el reparto
 * en meses con Seguro y Bienes de uso. Los permisos los valida el server
 * (`guardar_gasto`); acá sólo se esconde lo que el rol no puede usar.
 *
 * "Con qué plata se pagó" (entrega 2): la oficina o una rendición (transportista y
 * día). Abierto desde "Cerrar rendición" (`desdeCierre`) la plata es esa rendición y
 * el modal trabaja en borrador: `onSave` no escribe nada, el cierre guarda todo junto.
 */
import React, { useId, useMemo, useState } from 'react'
import type { FormEvent, ReactNode } from 'react'
import { z } from 'zod'
import { AlertTriangle, CalendarRange, ChevronLeft, ChevronRight } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { Combobox } from '../ui/Combobox'
import { cn } from '../../lib/utils'
import { useKmDelGastoQuery } from '../../hooks/queries/useGastosQuery'
import { getErrorMessage } from '../../utils/errorHandling'
import { formatPrecio } from '../../utils/formatters'
import { parsePrecio } from '../../utils/calculations'
import {
  ALICUOTAS_IVA_GASTO,
  COMPROBANTES_GASTO,
  GRUPOS_GASTO,
  costoDeGasto,
  cuotaDeGasto,
  daCreditoFiscal,
  errorDeDesglose,
  etiquetaGrupo,
  etiquetaMes,
  ivaSugerido,
  mesSugerido,
  netoDeGasto,
  sumarMeses,
} from '../../utils/gastos'
import type {
  ComprobanteGasto,
  Gasto,
  GrupoGasto,
  GuardarGastoPayload,
  RubroGasto,
  Vehiculo,
} from '../../types/gastos'

const MENSAJE_SIN_RENDICION = 'Elegí de qué rendición salió la plata: el transportista y el día'

// Schema CO-LOCADO a propósito (no en lib/schemas.ts): ver ModalCambioProducto.tsx
// para el incidente de chunk desincronizado que motivó la regla.
// Los ids van con coerce porque llegan como number pero el Combobox trabaja con
// strings (`z.string()` tiraría "Invalid input" en runtime).
// eslint-disable-next-line react-refresh/only-export-components
export const modalGastoSchema = z
  .object({
    id: z.coerce.number().int().positive().optional(),
    fecha: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, { message: 'La fecha es obligatoria' }),
    rubro_id: z.coerce
      .number({ error: 'Elegí un rubro' })
      .int({ message: 'Elegí un rubro' })
      .positive({ message: 'Elegí un rubro' }),
    monto_total: z.coerce
      .number({ error: 'El monto tiene que ser mayor a cero' })
      .positive({ message: 'El monto tiene que ser mayor a cero' }),
    comprobante: z.enum(['factura_a', 'factura_m', 'factura_b', 'factura_c', 'recibo', 'ticket', 'ninguno']),
    comprobante_numero: z.string().nullable().optional(),
    alicuota_iva: z.union([z.literal(21), z.literal(10.5), z.literal(27)]).nullable().optional(),
    iva: z.coerce.number().min(0, { message: 'Ningún importe puede ser negativo' }).default(0),
    percepcion_iva: z.coerce.number().min(0, { message: 'Ningún importe puede ser negativo' }).default(0),
    percepcion_iibb: z.coerce.number().min(0, { message: 'Ningún importe puede ser negativo' }).default(0),
    otros_impuestos: z.coerce.number().min(0, { message: 'Ningún importe puede ser negativo' }).default(0),
    sucursal_id: z.coerce.number().int().positive({ message: 'Elegí la sucursal' }),
    compartido: z.boolean(),
    vehiculo_id: z.coerce.number().int().positive().nullable().optional(),
    litros: z.coerce.number().positive({ message: 'Los litros tienen que ser mayores a cero' }).nullable().optional(),
    km_tablero: z.coerce
      .number({ error: 'Los km del tablero tienen que ser un número' })
      .int({ message: 'Los km del tablero tienen que ser un número entero' })
      .min(0, { message: 'Los km del tablero no pueden ser negativos' })
      .nullable()
      .optional(),
    mes_imputado: z.string().regex(/^\d{4}-\d{2}-01$/, { message: 'El mes del gasto tiene que ser el primero del mes' }),
    repartir_meses: z.coerce
      .number()
      .int({ message: 'Los meses del reparto tienen que ser un número entero' })
      .min(1, { message: 'El reparto es de 1 a 120 meses' })
      .max(120, { message: 'El reparto es de 1 a 120 meses' }),
    origen_pago: z.enum(['oficina', 'rendicion']),
    rendicion_transportista_id: z.string().nullable().optional(),
    rendicion_fecha: z
      .string()
      .regex(/^\d{4}-\d{2}-\d{2}$/, { message: MENSAJE_SIN_RENDICION })
      .nullable()
      .optional(),
    observacion: z.string().nullable().optional(),
  })
  .superRefine((g, ctx) => {
    if (g.origen_pago === 'rendicion' && (!g.rendicion_transportista_id || !g.rendicion_fecha)) {
      ctx.addIssue({ code: 'custom', message: MENSAJE_SIN_RENDICION, path: ['rendicion_transportista_id'] })
    }
    const error = errorDeDesglose(g)
    if (error) ctx.addIssue({ code: 'custom', message: error, path: ['iva'] })
  })

export interface ModalGastoProps {
  /** Edición. */
  gasto?: Gasto | null
  /** Rubros activos. */
  rubros: RubroGasto[]
  /** Vehículos activos de la sucursal actual. */
  vehiculos: Vehiculo[]
  sucursalActual: { id: number; nombre: string }
  sucursalesUsuario: Array<{ id: number; nombre: string }>
  /** Para el texto del aviso de compartido. */
  sucursalesActivas: Array<{ id: number; nombre: string }>
  esAdmin: boolean
  /** Quién edita: con `tieneTodasLasSucursales` decide si puede pasar a compartido un gasto ajeno. */
  usuarioId?: string
  tieneTodasLasSucursales?: boolean
  /** Sólo admin: crea el rubro desde el buscador. */
  onCrearRubro?: (nombre: string, grupo: GrupoGasto) => Promise<RubroGasto>
  /** Para "Una rendición". Sin la lista, un gasto nuevo es siempre de la oficina. */
  transportistas?: Array<{ id: string; nombre: string }>
  /** Abierto desde "Cerrar rendición": la plata es esa rendición y el modal trabaja en borrador. */
  desdeCierre?: { transportistaId: string; transportistaNombre: string; fecha: string }
  /** Los valores con que arranca. Pisan los de `gasto` y traen sus km: no se piden al server. */
  borrador?: GuardarGastoPayload | null
  onSave: (payload: GuardarGastoPayload) => Promise<void>
  onClose: () => void
}

/** Lo que el formulario muestra al abrir: el borrador pisa al gasto. */
interface ValoresIniciales {
  rubro_id: number
  monto_total: number
  fecha: string
  comprobante: ComprobanteGasto
  comprobante_numero: string | null
  alicuota_iva: number | null
  iva: number
  percepcion_iva: number
  percepcion_iibb: number
  otros_impuestos: number
  sucursal_id: number
  compartido: boolean
  vehiculo_id: number | null
  litros: number | null
  mes_imputado: string
  repartir_meses: number
  observacion: string | null
  origen_pago: 'oficina' | 'rendicion'
  rendicion_transportista_id: string | null
  rendicion_fecha: string | null
}

function valoresIniciales(gasto: Gasto | null | undefined, borrador: GuardarGastoPayload | null | undefined): ValoresIniciales | null {
  if (borrador) {
    return {
      rubro_id: Number(borrador.rubro_id),
      monto_total: borrador.monto_total,
      fecha: borrador.fecha,
      comprobante: borrador.comprobante,
      comprobante_numero: borrador.comprobante_numero ?? null,
      alicuota_iva: borrador.alicuota_iva ?? null,
      iva: borrador.iva ?? 0,
      percepcion_iva: borrador.percepcion_iva ?? 0,
      percepcion_iibb: borrador.percepcion_iibb ?? 0,
      otros_impuestos: borrador.otros_impuestos ?? 0,
      sucursal_id: borrador.sucursal_id,
      compartido: borrador.compartido,
      vehiculo_id: borrador.vehiculo_id ?? null,
      litros: borrador.litros ?? null,
      mes_imputado: borrador.mes_imputado,
      repartir_meses: borrador.repartir_meses,
      observacion: borrador.observacion ?? null,
      origen_pago: borrador.origen_pago,
      rendicion_transportista_id: borrador.rendicion_transportista_id ?? null,
      rendicion_fecha: borrador.rendicion_fecha ?? null,
    }
  }
  if (gasto) {
    return {
      rubro_id: gasto.rubro_id,
      monto_total: gasto.monto_total,
      fecha: gasto.fecha,
      comprobante: gasto.comprobante,
      comprobante_numero: gasto.comprobante_numero,
      alicuota_iva: gasto.alicuota_iva,
      iva: gasto.iva,
      percepcion_iva: gasto.percepcion_iva,
      percepcion_iibb: gasto.percepcion_iibb,
      otros_impuestos: gasto.otros_impuestos,
      sucursal_id: gasto.sucursal_id,
      compartido: gasto.compartido,
      vehiculo_id: gasto.vehiculo_id,
      litros: gasto.litros,
      mes_imputado: gasto.mes_imputado,
      repartir_meses: gasto.repartir_meses,
      observacion: gasto.observacion,
      origen_pago: gasto.origen_pago === 'rendicion' ? 'rendicion' : 'oficina',
      rendicion_transportista_id: gasto.rendicion_transportista_id,
      rendicion_fecha: gasto.rendicion_fecha,
    }
  }
  return null
}

/** "2026-10-28" → "28/10". */
const diaYMes = (fechaISO: string): string => `${fechaISO.slice(8, 10)}/${fechaISO.slice(5, 7)}`

type Alicuota = (typeof ALICUOTAS_IVA_GASTO)[number]

const hoyEnTucuman = (): string =>
  new Date().toLocaleDateString('en-CA', { timeZone: 'America/Argentina/Tucuman' })

/** 8677.69 → "8677,69": lo que se ve en un campo de importe. */
const formatoInput = (n: number): string => n.toFixed(2).replace('.', ',')

/** "Tucumán", "Tucumán y Taco Pozo", "A, B y C". */
function unirConY(nombres: string[]): string {
  if (nombres.length <= 1) return nombres.join('')
  return `${nombres.slice(0, -1).join(', ')} y ${nombres[nombres.length - 1]}`
}

const CLASE_INPUT =
  'w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-brand-500 dark:bg-gray-700 dark:text-white'
const MENSAJE_ERROR_KM = 'No se pudo leer el km del tablero. Cerrá y volvé a abrir el gasto.'
const CLASE_LINK = 'text-sm text-brand-600 dark:text-brand-400 font-medium hover:underline'

function Pastilla({
  activa, onClick, children, className,
}: { activa: boolean; onClick: () => void; children: ReactNode; className?: string }) {
  return (
    <button
      type="button"
      aria-pressed={activa}
      onClick={onClick}
      className={cn(
        'p-2 border rounded-lg text-sm transition-colors',
        activa
          ? 'border-brand-500 bg-brand-50 dark:bg-brand-900/20 text-brand-700 dark:text-brand-300 font-medium'
          : 'border-gray-200 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700 text-gray-700 dark:text-gray-300',
        className,
      )}
    >
      {children}
    </button>
  )
}

function Segmentado<T extends string | number>({
  etiqueta, opciones, valor, onChange,
}: { etiqueta: string; opciones: Array<{ valor: T; texto: string }>; valor: T; onChange: (v: T) => void }) {
  return (
    <div
      role="group"
      aria-label={etiqueta}
      className="inline-flex rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 p-0.5 text-xs"
    >
      {opciones.map(o => (
        <button
          key={String(o.valor)}
          type="button"
          aria-pressed={o.valor === valor}
          onClick={() => onChange(o.valor)}
          className={cn(
            'px-2 py-1 rounded-md',
            o.valor === valor
              ? 'bg-brand-100 dark:bg-brand-900/40 text-brand-800 dark:text-brand-200 font-semibold'
              : 'text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700',
          )}
        >
          {o.texto}
        </button>
      ))}
    </div>
  )
}

const textoAlicuota = (a: Alicuota): string => `${String(a).replace('.', ',')}%`

export default function ModalGasto({
  gasto, rubros, vehiculos, sucursalActual, sucursalesUsuario, sucursalesActivas,
  esAdmin, usuarioId, tieneTodasLasSucursales = false, onCrearRubro,
  transportistas, desdeCierre, borrador, onSave, onClose,
}: ModalGastoProps): React.ReactElement {
  const edicion = Boolean(gasto) || Boolean(borrador)
  const ini = valoresIniciales(gasto, borrador)
  const id = useId()

  // ---- Rubro --------------------------------------------------------------
  const [rubroId, setRubroId] = useState<string>(ini ? String(ini.rubro_id) : '')
  const [rubrosCreados, setRubrosCreados] = useState<RubroGasto[]>([])
  const [nuevoRubro, setNuevoRubro] = useState<{ nombre: string; grupo: GrupoGasto | null } | null>(null)
  const [creandoRubro, setCreandoRubro] = useState(false)

  const rubrosTodos = useMemo<RubroGasto[]>(() => {
    const lista = [...rubros, ...rubrosCreados.filter(c => !rubros.some(r => r.id === c.id))]
    // Un gasto viejo puede tener un rubro dado de baja: no está en la lista de
    // activos pero tiene que seguir viéndose elegido.
    if (gasto?.rubro && !lista.some(r => r.id === gasto.rubro_id)) {
      lista.push({
        id: gasto.rubro_id, nombre: gasto.rubro.nombre, grupo: gasto.rubro.grupo, palabras_busqueda: null,
        pide_litros_km: false, reparto_sugerido_meses: null, sugiere_mes_anterior: false, activo: false,
      })
    }
    // Agrupados por grupo, en el orden del spec, y por nombre dentro de cada uno.
    const orden = (g: GrupoGasto) => GRUPOS_GASTO.findIndex(x => x.valor === g)
    return lista.sort((a, b) => orden(a.grupo) - orden(b.grupo) || a.nombre.localeCompare(b.nombre, 'es'))
  }, [rubros, rubrosCreados, gasto])

  const rubro = rubroId ? rubrosTodos.find(r => String(r.id) === rubroId) ?? null : null

  // ---- Importes y comprobante ---------------------------------------------
  const [montoTxt, setMontoTxt] = useState(ini ? formatoInput(ini.monto_total) : '')
  const [fecha, setFecha] = useState(ini?.fecha ?? desdeCierre?.fecha ?? hoyEnTucuman())
  const [comprobante, setComprobante] = useState<ComprobanteGasto>(ini?.comprobante ?? 'ticket')
  const [alicuota, setAlicuota] = useState<Alicuota>(
    (ini?.alicuota_iva as Alicuota | null | undefined) ?? 21,
  )
  const [ivaManualTxt, setIvaManualTxt] = useState<string | null>(ini && daCreditoFiscal(ini.comprobante) ? formatoInput(ini.iva) : null)
  const [percIvaTxt, setPercIvaTxt] = useState(ini?.percepcion_iva ? formatoInput(ini.percepcion_iva) : '')
  const [percIibbTxt, setPercIibbTxt] = useState(ini?.percepcion_iibb ? formatoInput(ini.percepcion_iibb) : '')
  const [otrosTxt, setOtrosTxt] = useState(ini?.otros_impuestos ? formatoInput(ini.otros_impuestos) : '')
  const [mostrarPerc, setMostrarPerc] = useState(
    Boolean(ini && (ini.percepcion_iva || ini.percepcion_iibb || ini.otros_impuestos)),
  )
  const [numero, setNumero] = useState(ini?.comprobante_numero ?? '')
  const [mostrarNumero, setMostrarNumero] = useState(Boolean(ini?.comprobante_numero))

  const conCredito = daCreditoFiscal(comprobante)
  const montoTotal = parsePrecio(montoTxt)
  const percIva = conCredito ? parsePrecio(percIvaTxt) : 0
  const percIibb = conCredito ? parsePrecio(percIibbTxt) : 0
  const otros = conCredito ? parsePrecio(otrosTxt) : 0
  const ivaTxt = ivaManualTxt ?? formatoInput(ivaSugerido(montoTotal, alicuota, percIva + percIibb, otros))
  const iva = conCredito ? parsePrecio(ivaTxt) : 0
  const desglose = { monto_total: montoTotal, iva, percepcion_iva: percIva, percepcion_iibb: percIibb, otros_impuestos: otros }
  const neto = netoDeGasto(desglose)
  const costo = costoDeGasto(desglose)

  // ---- Vehículo, litros y km ----------------------------------------------
  const [vehiculoId, setVehiculoId] = useState(ini?.vehiculo_id ? String(ini.vehiculo_id) : '')
  const [litrosTxt, setLitrosTxt] = useState(ini?.litros ? formatoInput(ini.litros) : '')
  // Los km del tablero no viajan en `Gasto`: la lectura vive en `vehiculo_km`. Al editar se
  // la trae y se precarga (si el campo no viaja, `guardar_gasto` la borra). `kmEditado` es
  // null mientras nadie tocó el campo: ahí se ve lo que trajo la lectura.
  const { data: kmPrevio, isLoading: cargandoKm, isError: errorKm } = useKmDelGastoQuery(gasto?.vehiculo_id != null && !borrador ? gasto.id : null)
  const [kmEditado, setKmEditado] = useState<string | null>(null)
  // Un borrador trae sus km: no hay lectura que pedir.
  const kmInicial = borrador ? (borrador.km_tablero ?? null) : (kmPrevio ?? null)
  const kmTxt = kmEditado ?? (kmInicial != null ? String(kmInicial) : '')
  const [mostrarLitrosManual, setMostrarLitros] = useState(Boolean(ini?.litros))
  const mostrarLitros = mostrarLitrosManual || kmInicial != null
  const pideVehiculo = rubro?.grupo === 'vehiculos'
  const pideLitros = Boolean(rubro?.pide_litros_km)

  // ---- Sucursal ------------------------------------------------------------
  const [sucursalSel, setSucursalSel] = useState<number>(ini?.sucursal_id ?? sucursalActual.id)
  const [compartido, setCompartido] = useState(ini?.compartido ?? false)
  const puedeCompartir = esAdmin
  const variasSucursales = sucursalesUsuario.length > 1
  const nombresActivas = unirConY(sucursalesActivas.map(s => s.nombre))
  // Una edición NUNCA cambia la sucursal: el server no lo deja (`guardar_gasto`), así que
  // viaja la del gasto aunque el usuario esté parado en otra. En el alta, el compartido se
  // carga donde está el usuario: de ahí cuelga el crédito fiscal.
  const sucursalDelGasto = ini ? ini.sucursal_id : compartido ? sucursalActual.id : sucursalSel
  const sucursalDelGastoNombre =
    sucursalesUsuario.find(s => s.id === sucursalDelGasto)?.nombre
    ?? sucursalesActivas.find(s => s.id === sucursalDelGasto)?.nombre
    ?? sucursalActual.nombre
  // Los vehículos que llegan son los de la sucursal actual (RLS): para un gasto de otra
  // sucursal no hay con qué elegir. En una edición se conserva el vehículo que ya tenía.
  const vehiculoOtraSucursal = sucursalDelGasto !== sucursalActual.id
  // Con quién se comparte: las demás sucursales activas. En el alta de un admin de una sola
  // son "las otras"; al editar, las que no son la del gasto.
  const otrasSucursales = sucursalesActivas.filter(s => s.id !== sucursalDelGasto)
  // Pasar a compartido un gasto que cargó otro lo rechaza el server, salvo a un admin con todas
  // las sucursales: en la edición la casilla sólo está si ya es compartido, si lo cargó el
  // usuario o si tiene todas.
  const puedeCambiarCompartido = !gasto || gasto.compartido || gasto.creado_por === usuarioId || tieneTodasLasSucursales

  // ---- Mes y reparto ------------------------------------------------------
  const [mesManual, setMesManual] = useState<string | null>(ini?.mes_imputado ?? null)
  const [repartirManual, setRepartirManual] = useState<boolean | null>(ini ? ini.repartir_meses > 1 : null)
  const [mesesManual, setMesesManual] = useState<number | null>(ini && ini.repartir_meses > 1 ? ini.repartir_meses : null)
  const [mostrarMes, setMostrarMes] = useState(false)

  const sugerencia = rubro?.reparto_sugerido_meses ?? null
  const mesImputado = mesManual ?? mesSugerido(fecha, { sugiere_mes_anterior: rubro?.sugiere_mes_anterior ?? false })
  const repartir = repartirManual ?? sugerencia != null
  const nMeses = Math.min(120, Math.max(2, mesesManual ?? sugerencia ?? 2))
  const repartirMeses = repartir ? nMeses : 1
  const bloqueMesAbierto = mostrarMes || repartir || Boolean(rubro?.sugiere_mes_anterior)
  const mesFin = sumarMeses(mesImputado, repartirMeses - 1)

  // ---- Con qué plata -------------------------------------------------------
  // Un gasto de una rendición se conserva aunque no llegue la lista de transportistas: la
  // plata sólo cambia si el usuario la cambia.
  const [origen, setOrigen] = useState<'oficina' | 'rendicion'>(
    desdeCierre ? 'rendicion' : ini?.origen_pago ?? 'oficina',
  )
  const [transportistaId, setTransportistaId] = useState(ini?.rendicion_transportista_id ?? '')
  // El día de la rendición sigue a la fecha del gasto hasta que se lo cambia a mano.
  const [diaManual, setDiaManual] = useState<string | null>(ini?.rendicion_fecha ?? null)
  const diaRendicion = diaManual ?? fecha
  const mostrarPlata = Boolean(transportistas) && !desdeCierre

  // ---- Observación y estado -----------------------------------------------
  const [observacion, setObservacion] = useState(ini?.observacion ?? '')
  const [mostrarObs, setMostrarObs] = useState(Boolean(ini?.observacion))
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  const elegirRubro = (r: RubroGasto) => {
    if (String(r.id) === rubroId) return
    setRubroId(String(r.id))
    // El rubro nuevo trae sus propias sugerencias de mes y de reparto.
    setMesManual(null)
    setRepartirManual(null)
    setMesesManual(null)
  }

  const crearRubro = async () => {
    if (!nuevoRubro?.grupo || !onCrearRubro) return
    setCreandoRubro(true)
    setError('')
    try {
      const creado = await onCrearRubro(nuevoRubro.nombre, nuevoRubro.grupo)
      setRubrosCreados(prev => [...prev, creado])
      elegirRubro(creado)
      setNuevoRubro(null)
    } catch (err) {
      setError(getErrorMessage(err))
    } finally {
      setCreandoRubro(false)
    }
  }

  const handleEscapeKeyDown = (event: KeyboardEvent) => {
    // Radix escucha Escape en captura, antes que el buscador: con la lista
    // abierta, Escape tiene que cerrar sólo la lista (ver ModalCompra).
    const enfocado = document.activeElement
    const comboboxAbierto = enfocado?.getAttribute('role') === 'combobox' &&
      enfocado.getAttribute('aria-expanded') === 'true'
    if (comboboxAbierto) event.preventDefault()
  }

  const handleSubmit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    setError('')
    if (errorKm) return // el mensaje ya está a la vista y el botón deshabilitado

    const litros = pideVehiculo && pideLitros && litrosTxt.trim() ? parsePrecio(litrosTxt) : null
    // Los puntos son separadores de miles (`parsePrecio('150.000')` daría 150); la coma es
    // decimal y el schema la rechaza: los km son enteros. Igual que la ficha del vehículo.
    const kmLimpio = kmTxt.trim().replace(/\./g, '').replace(',', '.')
    const km = pideVehiculo && pideLitros && kmLimpio ? Number(kmLimpio) : null
    // El número sólo viaja si el comprobante elegido muestra el campo.
    const tieneCampoNumero = conCredito
      || ((comprobante === 'factura_b' || comprobante === 'factura_c' || comprobante === 'recibo') && mostrarNumero)
    const payload: GuardarGastoPayload = {
      ...(gasto ? { id: gasto.id } : {}),
      fecha,
      rubro_id: rubroId as unknown as number,
      monto_total: montoTotal,
      comprobante,
      comprobante_numero: tieneCampoNumero && numero.trim() ? numero.trim() : null,
      alicuota_iva: conCredito ? alicuota : null,
      iva,
      percepcion_iva: percIva,
      percepcion_iibb: percIibb,
      otros_impuestos: otros,
      sucursal_id: sucursalDelGasto,
      compartido: puedeCompartir && compartido,
      vehiculo_id: vehiculoOtraSucursal
        ? (ini?.vehiculo_id ?? null)
        : pideVehiculo && vehiculoId ? (vehiculoId as unknown as number) : null,
      litros,
      km_tablero: km,
      mes_imputado: mesImputado,
      repartir_meses: repartirMeses,
      origen_pago: origen,
      rendicion_transportista_id: origen === 'rendicion' ? (desdeCierre?.transportistaId ?? (transportistaId || null)) : null,
      rendicion_fecha: origen === 'rendicion' ? (desdeCierre?.fecha ?? (diaRendicion || null)) : null,
      observacion: observacion.trim() ? observacion.trim() : null,
    }

    const resultado = modalGastoSchema.safeParse(payload)
    if (!resultado.success) {
      setError(resultado.error.issues[0]?.message ?? 'Revisá los datos del gasto')
      return
    }

    setGuardando(true)
    try {
      // El schema coacciona los ids a number: se manda lo validado, no el crudo.
      await onSave(resultado.data as GuardarGastoPayload)
      onClose()
    } catch (err) {
      // getErrorMessage, no `err instanceof Error`: el error de supabase-js es
      // un objeto plano. Ver src/utils/errorDeSupabase.ts.
      setError(getErrorMessage(err))
    } finally {
      setGuardando(false)
    }
  }

  const cuotaMensual = repartir ? cuotaDeGasto(costo, repartirMeses, 1) : null

  return (
    <ModalBase
      title={edicion ? 'Editar gasto' : 'Registrar gasto'}
      onClose={onClose}
      maxWidth="max-w-xl"
      onEscapeKeyDown={handleEscapeKeyDown}
    >
      <form onSubmit={handleSubmit} className="p-4 space-y-4">
        {/* Rubro */}
        <div>
          <label htmlFor={`${id}-rubro`} className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            Rubro <span className="text-red-500">*</span>
          </label>
          <Combobox
            id={`${id}-rubro`}
            opciones={rubrosTodos}
            getKey={r => String(r.id)}
            getLabel={r => r.nombre}
            getTextosBusqueda={r => [r.nombre, r.palabras_busqueda, etiquetaGrupo(r.grupo)]}
            renderOpcion={r => (
              <span className="flex items-center justify-between gap-2">
                <span>{r.nombre}</span>
                <span className="text-xs text-gray-500">{etiquetaGrupo(r.grupo)}</span>
              </span>
            )}
            valor={rubroId}
            onSeleccionar={elegirRubro}
            onCrear={onCrearRubro ? texto => setNuevoRubro({ nombre: texto, grupo: null }) : undefined}
            textoCrear={t => `+ Crear rubro "${t}"`}
            placeholder="Buscá o creá un rubro"
          />
          {nuevoRubro && (
            <div className="mt-2 p-3 rounded-lg bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-700 text-sm">
              <p className="text-gray-700 dark:text-gray-300">
                Rubro nuevo: <b>{nuevoRubro.nombre}</b>. ¿En qué grupo va?
              </p>
              <div className="mt-2 grid grid-cols-3 gap-1.5">
                {GRUPOS_GASTO.map(g => (
                  <Pastilla
                    key={g.valor}
                    activa={nuevoRubro.grupo === g.valor}
                    onClick={() => setNuevoRubro({ ...nuevoRubro, grupo: g.valor })}
                    className="p-1.5 text-xs"
                  >
                    {g.etiqueta}
                  </Pastilla>
                ))}
              </div>
              <div className="mt-2 flex items-center justify-between gap-2">
                <p className="text-xs text-gray-500">El grupo decide en qué renglón del resultado cae.</p>
                <div className="flex gap-2">
                  <Button type="button" variant="ghost" size="sm" onClick={() => setNuevoRubro(null)}>
                    Descartar
                  </Button>
                  <Button
                    type="button"
                    variant="primary"
                    size="sm"
                    disabled={!nuevoRubro.grupo || creandoRubro}
                    loading={creandoRubro}
                    onClick={crearRubro}
                  >
                    Agregar y usar
                  </Button>
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Monto y fecha */}
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label htmlFor={`${id}-monto`} className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Monto total <span className="text-red-500">*</span>
            </label>
            <div className="relative">
              <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" aria-hidden="true">$</span>
              <input
                id={`${id}-monto`}
                type="text"
                inputMode="decimal"
                autoComplete="off"
                value={montoTxt}
                onChange={e => setMontoTxt(e.target.value)}
                placeholder="0,00"
                className={cn(CLASE_INPUT, 'pl-7 text-right')}
              />
            </div>
          </div>
          <div>
            <label htmlFor={`${id}-fecha`} className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Fecha <span className="text-red-500">*</span>
            </label>
            <input
              id={`${id}-fecha`}
              type="date"
              value={fecha}
              onChange={e => setFecha(e.target.value)}
              className={CLASE_INPUT}
            />
          </div>
        </div>

        {/* Comprobante */}
        <div>
          <span className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            Comprobante <span className="text-red-500">*</span>
          </span>
          <div className="grid grid-cols-3 sm:grid-cols-6 gap-1.5">
            {COMPROBANTES_GASTO.map(c => (
              <Pastilla
                key={c.valor}
                activa={c.valor === 'factura_a' ? conCredito : comprobante === c.valor}
                onClick={() => {
                  // Volver a "Factura A" desde la M conserva la letra elegida.
                  setComprobante(c.valor === 'factura_a' && comprobante === 'factura_m' ? 'factura_m' : c.valor)
                }}
              >
                {c.etiqueta}
              </Pastilla>
            ))}
          </div>

          {conCredito && (
            <div className="mt-2 p-3 rounded-lg bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-700 text-sm space-y-2">
              <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
                <div className="flex items-center gap-2 text-gray-700 dark:text-gray-300">
                  Letra
                  <Segmentado<ComprobanteGasto>
                    etiqueta="Letra A · M"
                    opciones={[{ valor: 'factura_a', texto: 'A' }, { valor: 'factura_m', texto: 'M' }]}
                    valor={comprobante}
                    onChange={setComprobante}
                  />
                </div>
                <div className="flex items-center gap-2 text-gray-700 dark:text-gray-300">
                  Alícuota
                  <Segmentado<Alicuota>
                    etiqueta="Alícuota de IVA"
                    opciones={ALICUOTAS_IVA_GASTO.map(a => ({ valor: a, texto: textoAlicuota(a) }))}
                    valor={alicuota}
                    onChange={setAlicuota}
                  />
                </div>
              </div>
              <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
                <label className="inline-flex items-center gap-2 text-gray-700 dark:text-gray-300">
                  IVA
                  <input
                    type="text"
                    inputMode="decimal"
                    autoComplete="off"
                    value={ivaTxt}
                    onChange={e => setIvaManualTxt(e.target.value)}
                    className="w-32 px-3 py-1.5 border border-gray-300 dark:border-gray-600 rounded-lg text-right dark:bg-gray-700 dark:text-white"
                  />
                </label>
                <span className="font-semibold text-gray-900 dark:text-white">{`Neto ${formatPrecio(neto)}`}</span>
                <button type="button" className={CLASE_LINK} onClick={() => setMostrarPerc(v => !v)}>
                  + percepciones e impuestos
                </button>
              </div>
              {mostrarPerc && (
                <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
                  {([
                    ['Percepción de IVA', percIvaTxt, setPercIvaTxt],
                    ['Percepción de IIBB', percIibbTxt, setPercIibbTxt],
                    ['Otros impuestos', otrosTxt, setOtrosTxt],
                  ] as const).map(([etiqueta, valor, set]) => (
                    <label key={etiqueta} className="text-xs text-gray-600 dark:text-gray-400">
                      {etiqueta}
                      <input
                        type="text"
                        inputMode="decimal"
                        autoComplete="off"
                        value={valor}
                        onChange={e => set(e.target.value)}
                        placeholder="0,00"
                        className="mt-1 w-full px-3 py-1.5 border border-gray-300 dark:border-gray-600 rounded-lg text-right text-sm dark:bg-gray-700 dark:text-white"
                      />
                    </label>
                  ))}
                </div>
              )}
              <input
                type="text"
                aria-label="Número de factura"
                value={numero}
                onChange={e => setNumero(e.target.value)}
                placeholder="Número de factura (opcional)"
                className="w-full px-3 py-1.5 border border-gray-300 dark:border-gray-600 rounded-lg font-mono text-sm dark:bg-gray-700 dark:text-white"
              />
              <p className="text-xs text-gray-500">
                El IVA y las percepciones suman a la posición fiscal; al resultado va el costo sin ellos.
                Si la factura está a nombre de otra empresa del grupo, cargala como Sin comprobante: su IVA no es de la distribuidora.
              </p>
            </div>
          )}

          {(comprobante === 'factura_b' || comprobante === 'factura_c' || comprobante === 'recibo') && (
            mostrarNumero ? (
              <input
                type="text"
                aria-label="Número de comprobante"
                value={numero}
                onChange={e => setNumero(e.target.value)}
                placeholder="Número (opcional)"
                className="mt-2 w-full px-3 py-1.5 border border-gray-300 dark:border-gray-600 rounded-lg font-mono text-sm dark:bg-gray-700 dark:text-white"
              />
            ) : (
              <button type="button" className={cn(CLASE_LINK, 'mt-1')} onClick={() => setMostrarNumero(true)}>
                + número de comprobante
              </button>
            )
          )}
        </div>

        {/* Vehículo, litros y km */}
        {pideVehiculo && (
          <div>
            <label htmlFor={`${id}-vehiculo`} className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Vehículo
            </label>
            <Combobox
              id={`${id}-vehiculo`}
              opciones={vehiculos}
              getKey={v => String(v.id)}
              getLabel={v => `${v.patente} · ${v.descripcion}`}
              getTextosBusqueda={v => [v.patente, v.descripcion]}
              valor={vehiculoId}
              // Un vehículo dado de baja no está en la lista de activos: se sigue viendo elegido.
              textoSinOpcion={
                gasto?.vehiculo ? `${gasto.vehiculo.patente} · ${gasto.vehiculo.descripcion}`
                  // La RLS de `vehiculos` es por sucursal actual: el embed puede llegar null.
                  : gasto?.vehiculo_id != null ? `Vehículo de ${sucursalDelGastoNombre}` : ''
              }
              onSeleccionar={v => setVehiculoId(String(v.id))}
              placeholder="Buscá por patente o modelo"
              textoSinResultados="No hay vehículos cargados"
              disabled={vehiculoOtraSucursal}
            />
            {vehiculoOtraSucursal && (
              <p className="mt-1 text-xs text-gray-500">
                {`Los vehículos son de ${sucursalActual.nombre}. Para cargar un gasto de un vehículo de ${sucursalDelGastoNombre}, cambiá de sucursal.`}
              </p>
            )}
            {pideLitros && (mostrarLitros ? (
              <div className="mt-2 grid grid-cols-2 gap-2">
                <input
                  type="text"
                  inputMode="decimal"
                  aria-label="Litros"
                  placeholder="Litros"
                  value={litrosTxt}
                  onChange={e => setLitrosTxt(e.target.value)}
                  className="px-3 py-1.5 border border-gray-300 dark:border-gray-600 rounded-lg text-right text-sm dark:bg-gray-700 dark:text-white"
                />
                <input
                  type="text"
                  inputMode="numeric"
                  aria-label="Km del tablero"
                  placeholder="Km del tablero"
                  value={kmTxt}
                  onChange={e => setKmEditado(e.target.value)}
                  className="px-3 py-1.5 border border-gray-300 dark:border-gray-600 rounded-lg text-right text-sm dark:bg-gray-700 dark:text-white"
                />
              </div>
            ) : (
              <button type="button" className={cn(CLASE_LINK, 'mt-1')} onClick={() => setMostrarLitros(true)}>
                + litros y km del tablero
              </button>
            ))}
          </div>
        )}

        {/* Sucursal */}
        {puedeCompartir && variasSucursales && !edicion && !desdeCierre ? (
          <div>
            <span className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Sucursal <span className="text-red-500">*</span>
            </span>
            <div role="group" aria-label="Sucursal" className="grid grid-cols-3 gap-2">
              {sucursalesUsuario.map(s => (
                <Pastilla
                  key={s.id}
                  activa={!compartido && sucursalSel === s.id}
                  onClick={() => {
                    setSucursalSel(s.id)
                    setCompartido(false)
                    // Los vehículos son de la sucursal actual: al pasar a otra, el elegido ya no vale.
                    if (s.id !== sucursalActual.id) setVehiculoId('')
                  }}
                >
                  {s.nombre}
                </Pastilla>
              ))}
              <Pastilla activa={compartido} onClick={() => setCompartido(true)}>Compartido</Pastilla>
            </div>
          </div>
        ) : (
          <div className="flex items-center justify-between gap-3 flex-wrap">
            <p className="text-sm text-gray-700 dark:text-gray-300">
              Sucursal{' '}
              <span className="ml-1 inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold bg-brand-100 text-brand-700 dark:bg-brand-900/30 dark:text-brand-300">
                {sucursalDelGastoNombre}
              </span>
            </p>
            {puedeCompartir && puedeCambiarCompartido && otrasSucursales.length > 0 && (
              <label className="inline-flex items-center gap-2 text-sm text-gray-700 dark:text-gray-300">
                <input
                  type="checkbox"
                  className="w-4 h-4"
                  checked={compartido}
                  onChange={e => setCompartido(e.target.checked)}
                />
                Es compartido con {unirConY(otrasSucursales.map(s => s.nombre))}
              </label>
            )}
          </div>
        )}

        {puedeCompartir && compartido && (
          <div role="alert" className="flex items-start gap-3 p-3 rounded-xl border border-amber-300 bg-amber-50 dark:bg-amber-900/20 dark:border-amber-700">
            <AlertTriangle className="w-5 h-5 shrink-0 mt-0.5 text-amber-600" aria-hidden="true" />
            <div className="text-sm text-amber-800 dark:text-amber-200 space-y-1">
              <p>
                <b>Gasto compartido entre {nombresActivas}.</b> Se reparte entre las dos según lo que vendió cada una en el mes, y lo ven los admins de las dos. Usalo sólo para lo que es de las dos, como la oficina o el contador.
              </p>
              {conCredito && (
                <p>
                  El crédito fiscal queda en {sucursalDelGastoNombre}: cargala desde la sucursal a cuyo nombre está la factura.
                </p>
              )}
            </div>
          </div>
        )}

        {/* Con qué plata */}
        {desdeCierre && (
          <p className="text-sm text-gray-700 dark:text-gray-300">
            Con la plata de la rendición de <b className="text-gray-900 dark:text-white">{desdeCierre.transportistaNombre}</b> del {diaYMes(desdeCierre.fecha)}. Se descuenta del efectivo que entrega.
          </p>
        )}
        {mostrarPlata && transportistas && (
          <div>
            <span id={`${id}-plata`} className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Con qué plata se pagó <span className="text-red-500">*</span>
            </span>
            <div role="group" aria-labelledby={`${id}-plata`} className="grid grid-cols-2 gap-2">
              <Pastilla activa={origen === 'oficina'} onClick={() => setOrigen('oficina')}>La oficina</Pastilla>
              <Pastilla activa={origen === 'rendicion'} onClick={() => setOrigen('rendicion')}>Una rendición</Pastilla>
            </div>
            {origen === 'rendicion' && (
              <div className="mt-2 grid grid-cols-1 sm:grid-cols-2 gap-2">
                <Combobox
                  aria-label="Transportista de la rendición"
                  opciones={transportistas}
                  getKey={t => t.id}
                  getLabel={t => t.nombre}
                  valor={transportistaId}
                  textoSinOpcion={ini?.rendicion_transportista_id ? 'Otro usuario' : ''}
                  onSeleccionar={t => setTransportistaId(t.id)}
                  placeholder="Transportista"
                  textoSinResultados="No hay transportistas"
                />
                <input
                  type="date"
                  aria-label="Día de la rendición"
                  value={diaRendicion}
                  onChange={e => setDiaManual(e.target.value)}
                  className={CLASE_INPUT}
                />
              </div>
            )}
            <p className="mt-1 text-xs text-gray-500">
              {origen === 'rendicion'
                ? 'Se descuenta del efectivo que entrega ese día. Si esa rendición ya está cerrada, el gasto se carga desde «Editar cierre» en Rendiciones.'
                : 'Sale de la caja de la oficina: no toca ninguna rendición.'}
            </p>
          </div>
        )}

        {/* Mes */}
        <div className="text-sm text-gray-600 dark:text-gray-400 flex flex-wrap items-center gap-x-2 gap-y-1">
          <CalendarRange className="w-4 h-4 text-gray-500" aria-hidden="true" />
          <span>
            Va al resultado de <b className="text-gray-900 dark:text-white">{etiquetaMes(mesImputado)}</b>
          </span>
          <button type="button" className={CLASE_LINK} onClick={() => setMostrarMes(v => !v)}>
            cambiar
          </button>
        </div>
        {bloqueMesAbierto && (
          <div className="p-3 rounded-lg bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-700 text-sm space-y-2">
            <div className="flex flex-wrap items-center gap-3">
              <div className="inline-flex items-center rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800">
                <button
                  type="button"
                  aria-label="Mes anterior"
                  className="px-2 py-1 text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 rounded-l-lg"
                  onClick={() => setMesManual(sumarMeses(mesImputado, -1))}
                >
                  <ChevronLeft className="w-4 h-4" aria-hidden="true" />
                </button>
                <span className="px-2 min-w-[130px] text-center text-gray-800 dark:text-gray-100 font-medium">
                  {etiquetaMes(mesImputado)}
                </span>
                <button
                  type="button"
                  aria-label="Mes siguiente"
                  className="px-2 py-1 text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 rounded-r-lg"
                  onClick={() => setMesManual(sumarMeses(mesImputado, 1))}
                >
                  <ChevronRight className="w-4 h-4" aria-hidden="true" />
                </button>
              </div>
              <label className="inline-flex items-center gap-2 text-gray-700 dark:text-gray-300">
                <input
                  type="checkbox"
                  className="w-4 h-4"
                  checked={repartir}
                  onChange={e => setRepartirManual(e.target.checked)}
                />
                Repartir en
              </label>
              <span className="inline-flex items-center gap-1 text-gray-700 dark:text-gray-300">
                <input
                  type="text"
                  inputMode="numeric"
                  aria-label="Meses del reparto"
                  disabled={!repartir}
                  value={String(nMeses)}
                  onChange={e => {
                    const n = parseInt(e.target.value.replace(/\D/g, ''), 10)
                    setMesesManual(Number.isFinite(n) ? n : null)
                  }}
                  className="w-16 px-2 py-1 border border-gray-300 dark:border-gray-600 rounded-md text-right dark:bg-gray-700 dark:text-white disabled:opacity-50"
                />
                meses
              </span>
            </div>
            {rubro?.sugiere_mes_anterior && (
              <p className="text-xs text-gray-500">Este rubro corresponde al mes anterior al del pago.</p>
            )}
            {cuotaMensual != null && (
              <p className="rounded-md bg-brand-50 dark:bg-brand-900/20 text-brand-800 dark:text-brand-200 px-2.5 py-1.5">
                {`${formatPrecio(cuotaMensual)} por mes al resultado, de ${etiquetaMes(mesImputado)} a ${etiquetaMes(mesFin)}`}
              </p>
            )}
          </div>
        )}

        {/* Observación */}
        <div>
          {mostrarObs ? (
            <textarea
              aria-label="Observación"
              rows={2}
              value={observacion}
              onChange={e => setObservacion(e.target.value)}
              placeholder="Algo que convenga saber de este gasto"
              className={cn(CLASE_INPUT, 'text-sm')}
            />
          ) : (
            <button type="button" className={CLASE_LINK} onClick={() => setMostrarObs(true)}>
              + Agregar observación
            </button>
          )}
        </div>

        {errorKm && (
          <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
            <p className="text-sm text-red-600 dark:text-red-400">{MENSAJE_ERROR_KM}</p>
          </div>
        )}

        {error && (
          <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
            <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
          </div>
        )}

        <div className="flex gap-3 pt-2">
          <Button type="button" variant="secondary" size="md" onClick={onClose} className="flex-1">
            Cancelar
          </Button>
          <Button type="submit" variant="primary" size="md" loading={guardando} disabled={guardando || cargandoKm || errorKm} className="flex-1">
            {desdeCierre ? (edicion ? 'Aplicar cambios' : 'Agregar a la rendición') : 'Guardar gasto'}
          </Button>
        </div>
        {desdeCierre && (
          <p className="text-xs text-gray-500 text-center">Se guarda cuando confirmes el cierre.</p>
        )}
      </form>
    </ModalBase>
  )
}
