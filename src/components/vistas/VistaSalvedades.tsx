/**
 * Vista de salvedades para admin
 * Permite ver y resolver salvedades pendientes de items
 */
import React, { useState, useEffect } from 'react'
import {
  AlertTriangle,
  Calendar,
  User,
  Package,
  Truck,
  CheckCircle,
  Filter,
  RefreshCw,
  ChevronDown,
  ChevronUp,
  Image,
  Undo2
} from 'lucide-react'
import { fechaLocalISO, fechaHaceDias, formatPrecio } from '../../utils/formatters'
import { Button } from '../ui/Button'
import { PeriodPicker } from '../ui/PeriodPicker'
import Paginacion from '../layout/Paginacion'
import {
  useAnularSalvedadMutation,
  useSalvedadesQuery,
  useEstadisticasSalvedadesQuery,
  useResolverSalvedadMutation,
  useTransportistasQuery,
  SALVEDADES_PAGE_SIZE,
  type SalvedadesFiltros,
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useSucursal } from '../../contexts/SucursalContext'
import { puedeAnularSalvedad, puedeResolverSalvedad } from '../../lib/permisos'
import { MOTIVOS_SALVEDAD_LABELS, ESTADOS_RESOLUCION_LABELS } from '../../lib/schemas'
import ModalResolverSalvedad from '../modals/ModalResolverSalvedad'
import ModalAnularSalvedad from '../modals/ModalAnularSalvedad'
import type { SalvedadItemDBExtended, MotivoSalvedad, EstadoResolucionSalvedad } from '../../types'

interface SalvedadCardProps {
  salvedad: SalvedadItemDBExtended;
  onResolver: (salvedad: SalvedadItemDBExtended) => void;
  onAnular: (salvedad: SalvedadItemDBExtended) => void;
  puedeAnular: boolean;
  puedeResolver: boolean;
}

interface EstadoResolucionStyle {
  iconBg: string;
  iconText: string;
  badge: string;
}

// WP-15 (#705): mapa estático, clases completas — Tailwind no ve una clase de
// color armada en runtime por interpolación (no hay safelist), así que sin
// esto el badge/icono queda sin color en producción. Cubre TODAS las claves
// del dominio
// (EstadoResolucionSalvedad, ver ESTADOS_RESOLUCION_LABELS en lib/schemas.ts),
// preservando exactamente los mismos tonos que tenía el ternario:
// pendiente=amber, anulada=gray, cualquier resolución concretada=green.
const ESTADO_RESOLUCION_STYLES: Record<EstadoResolucionSalvedad, EstadoResolucionStyle> = {
  pendiente: {
    iconBg: 'bg-amber-100 dark:bg-amber-900/30',
    iconText: 'text-amber-600',
    badge: 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400'
  },
  anulada: {
    iconBg: 'bg-gray-100 dark:bg-gray-900/30',
    iconText: 'text-gray-600',
    badge: 'bg-gray-100 text-gray-700 dark:bg-gray-900/30 dark:text-gray-400'
  },
  reprogramada: {
    iconBg: 'bg-green-100 dark:bg-green-900/30',
    iconText: 'text-green-600',
    badge: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
  },
  nota_credito: {
    iconBg: 'bg-green-100 dark:bg-green-900/30',
    iconText: 'text-green-600',
    badge: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
  },
  descuento_transportista: {
    iconBg: 'bg-green-100 dark:bg-green-900/30',
    iconText: 'text-green-600',
    badge: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
  },
  absorcion_empresa: {
    iconBg: 'bg-green-100 dark:bg-green-900/30',
    iconText: 'text-green-600',
    badge: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
  },
  resuelto_otro: {
    iconBg: 'bg-green-100 dark:bg-green-900/30',
    iconText: 'text-green-600',
    badge: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
  }
}

// Clave fuera del dominio conocido (dato viejo/inesperado): cae al neutro en
// vez de romper el render con `undefined`.
const ESTADO_RESOLUCION_STYLE_NEUTRAL: EstadoResolucionStyle = {
  iconBg: 'bg-gray-100 dark:bg-gray-900/30',
  iconText: 'text-gray-600',
  badge: 'bg-gray-100 text-gray-700 dark:bg-gray-900/30 dark:text-gray-400'
}

export function SalvedadCard({ salvedad, onResolver, onAnular, puedeAnular, puedeResolver }: SalvedadCardProps) {
  const [expandido, setExpandido] = useState(false)

  const formatDate = (dateStr: string | undefined): string => {
    if (!dateStr) return '-'
    return new Date(dateStr).toLocaleString('es-AR', { dateStyle: 'short', timeStyle: 'short' })
  }

  const estadoStyle = ESTADO_RESOLUCION_STYLES[salvedad.estado_resolucion] ?? ESTADO_RESOLUCION_STYLE_NEUTRAL

  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg border dark:border-gray-700 overflow-hidden">
      {/* Header */}
      <div
        className="p-4 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-750"
        onClick={() => setExpandido(!expandido)}
      >
        {/* En el celular (#1116) los números bajan a su propia fila, alineada con
            el texto (pl-12 = ícono + gap); desde `sm` vuelven a la derecha. En
            una sola fila, el bloque que no se encoge empujaba el Monto fuera de
            pantalla. `min-w-0` deja achicar la columna para que el nombre trunque. */}
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
          <div className="flex items-start gap-3 flex-1 min-w-0">
            <div className={`p-2 rounded-lg ${estadoStyle.iconBg}`}>
              <AlertTriangle className={`w-5 h-5 ${estadoStyle.iconText}`} />
            </div>
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-2 flex-wrap">
                <Package className="w-4 h-4 text-gray-400" />
                <span className="font-medium text-gray-800 dark:text-white truncate">
                  {salvedad.producto_nombre || salvedad.producto?.nombre || 'Producto'}
                </span>
                <span className={`px-2 py-0.5 rounded-full text-xs ${estadoStyle.badge}`}>
                  {ESTADOS_RESOLUCION_LABELS[salvedad.estado_resolucion]}
                </span>
              </div>
              <div className="flex items-center gap-4 text-sm text-gray-500 mt-1 flex-wrap">
                <span className="flex items-center gap-1">
                  <User className="w-3 h-3" />
                  {salvedad.cliente_nombre || '-'}
                </span>
                <span className="flex items-center gap-1">
                  <Truck className="w-3 h-3" />
                  {salvedad.transportista_nombre || '-'}
                </span>
                <span className="flex items-center gap-1">
                  <Calendar className="w-3 h-3" />
                  {formatDate(salvedad.created_at)}
                </span>
              </div>
              <div className="flex items-center gap-2 mt-2">
                <span className="px-2 py-0.5 bg-amber-100 dark:bg-amber-900/30 text-amber-700 dark:text-amber-400 rounded text-xs">
                  {MOTIVOS_SALVEDAD_LABELS[salvedad.motivo]}
                </span>
              </div>
            </div>
          </div>

          <div className="flex items-center gap-4 pl-12 sm:pl-0 sm:flex-shrink-0">
            <div className="sm:text-right">
              <p className="text-xs text-gray-500">Afectado</p>
              <p className="font-bold text-red-600">{salvedad.cantidad_afectada} u.</p>
            </div>
            <div className="sm:text-right">
              <p className="text-xs text-gray-500">Monto</p>
              <p className="font-bold text-red-600">{formatPrecio(salvedad.monto_afectado)}</p>
            </div>
            {expandido
              ? <ChevronUp className="w-5 h-5 text-gray-400 ml-auto sm:ml-0" />
              : <ChevronDown className="w-5 h-5 text-gray-400 ml-auto sm:ml-0" />}
          </div>
        </div>
      </div>

      {/* Contenido expandido */}
      {expandido && (
        <div className="border-t dark:border-gray-700 p-4 space-y-4">
          {/* Detalle de cantidades */}
          <div className="grid grid-cols-3 gap-3">
            <div className="p-2 bg-gray-50 dark:bg-gray-900 rounded-lg text-center">
              <p className="text-xs text-gray-500">Original</p>
              <p className="font-bold text-gray-800 dark:text-white">{salvedad.cantidad_original} u.</p>
            </div>
            <div className="p-2 bg-red-50 dark:bg-red-900/20 rounded-lg text-center">
              <p className="text-xs text-red-500">Afectado</p>
              <p className="font-bold text-red-600">{salvedad.cantidad_afectada} u.</p>
            </div>
            <div className="p-2 bg-green-50 dark:bg-green-900/20 rounded-lg text-center">
              <p className="text-xs text-green-500">Entregado</p>
              <p className="font-bold text-green-600">{salvedad.cantidad_entregada} u.</p>
            </div>
          </div>

          {/* Descripcion */}
          {salvedad.descripcion && (
            <div className="p-3 bg-gray-50 dark:bg-gray-900 rounded-lg">
              <p className="text-xs text-gray-500 mb-1">Descripcion:</p>
              <p className="text-sm text-gray-700 dark:text-gray-300">{salvedad.descripcion}</p>
            </div>
          )}

          {/* Estado del stock */}
          <div className={`flex items-center gap-2 p-2 rounded-lg text-sm ${
            salvedad.stock_devuelto
              ? 'bg-green-50 dark:bg-green-900/20 text-green-700 dark:text-green-400'
              : 'bg-red-50 dark:bg-red-900/20 text-red-700 dark:text-red-400'
          }`}>
            {salvedad.stock_devuelto
              ? <CheckCircle className="w-4 h-4" />
              : <AlertTriangle className="w-4 h-4" />
            }
            <span>
              {salvedad.stock_devuelto
                ? 'Stock devuelto al inventario'
                : 'Stock NO devuelto (perdida)'}
            </span>
          </div>

          {/* Foto de evidencia */}
          {salvedad.foto_url && (
            <div>
              <p className="text-xs text-gray-500 mb-1 flex items-center gap-1">
                <Image className="w-3 h-3" />
                Evidencia:
              </p>
              <img
                src={salvedad.foto_url}
                alt="Evidencia"
                className="max-h-32 rounded-lg border dark:border-gray-700"
              />
            </div>
          )}

          {/* Notas de resolucion (si esta resuelta) */}
          {salvedad.estado_resolucion !== 'pendiente' && salvedad.resolucion_notas && (
            <div className="p-3 bg-blue-50 dark:bg-blue-900/20 rounded-lg">
              <p className="text-xs text-blue-600 dark:text-blue-400 mb-1">
                Resolucion ({formatDate(salvedad.resolucion_fecha ?? undefined)}):
              </p>
              <p className="text-sm text-blue-800 dark:text-blue-300">{salvedad.resolucion_notas}</p>
              {salvedad.resuelto_por_nombre && (
                <p className="text-xs text-blue-500 mt-1">Por: {salvedad.resuelto_por_nombre}</p>
              )}
            </div>
          )}

          {/* Boton resolver (solo si esta pendiente y el rol puede). El gate
              es el espejo de `es_encargado_o_admin()`, que desde la mig 252 es
              el de `resolver_salvedad`: antes el encargado veia el boton y el
              servidor le contestaba "Solo admin". */}
          {puedeResolver && salvedad.estado_resolucion === 'pendiente' && (
            <Button
              onClick={() => onResolver(salvedad)}
              variant="primary"
              size="md"
              className="w-full"
            >
              <CheckCircle className="w-4 h-4" />
              Resolver Salvedad
            </Button>
          )}

          {/* Anular es otra cosa que resolver (mig 244, #621): deshace la
              salvedad entera --linea, totales y merma--, asi que va aparte, con
              su propia confirmacion, y sólo para quien el RPC deja anular. Una
              ya anulada no se vuelve a anular: la RPC lo rechaza. */}
          {puedeAnular && salvedad.estado_resolucion !== 'anulada' && (
            <button
              onClick={() => onAnular(salvedad)}
              className="w-full px-4 py-2 border border-red-300 dark:border-red-800 text-red-700 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/20 rounded-lg flex items-center justify-center gap-2"
            >
              <Undo2 className="w-4 h-4" />
              Anular salvedad
            </button>
          )}
        </div>
      )}
    </div>
  )
}

// Presets del período. El rango lo calcula la pantalla (PeriodPicker no sabe
// de fechas) en día argentino: `fechaLocalISO` / `fechaHaceDias` ya cortan en
// America/Argentina/Buenos_Aires. «Este mes» es del 1 a hoy, como en el Dashboard.
type PresetPeriodo = 'hoy' | '7d' | '30d' | 'mes'
const PRESETS_PERIODO: ReadonlyArray<{ id: PresetPeriodo; label: string }> = [
  { id: 'hoy', label: 'Hoy' },
  { id: '7d', label: '7 días' },
  { id: '30d', label: '30 días' },
  { id: 'mes', label: 'Este mes' },
]

function rangoDePreset(preset: PresetPeriodo): { desde: string; hasta: string } {
  const hoy = fechaLocalISO()
  switch (preset) {
    case 'hoy': return { desde: hoy, hasta: hoy }
    case '7d': return { desde: fechaHaceDias(7), hasta: hoy }
    case '30d': return { desde: fechaHaceDias(30), hasta: hoy }
    case 'mes': return { desde: `${hoy.slice(0, 8)}01`, hasta: hoy }
  }
}

const CLASES_SELECT = 'h-10 px-3 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white'

export default function VistaSalvedades(): React.ReactElement {
  // Filtros y página. Cambiar cualquier filtro vuelve a la página 1: la página
  // 3 de otra lista no es nada.
  const [filtros, setFiltros] = useState<SalvedadesFiltros>(() => ({
    estado: 'pendientes',
    motivo: 'todos',
    ...rangoDePreset('7d'),
    transportistaId: null,
  }))
  const [preset, setPreset] = useState<PresetPeriodo | null>('7d')
  const [pagina, setPagina] = useState(1)

  const cambiarFiltros = (cambio: Partial<SalvedadesFiltros>) => {
    setFiltros(prev => ({ ...prev, ...cambio }))
    setPagina(1)
  }

  // Cambiar de sucursal no remonta la vista. Los transportistas son por
  // sucursal: el elegido no está en el selector de la nueva, que mostraría
  // "Todos" mientras la consulta sigue filtrando por él. Se suelta, y la
  // página vuelve a 1; estado, motivo y período siguen valiendo.
  const { currentSucursalId } = useSucursal()
  const [sucursalVista, setSucursalVista] = useState(currentSucursalId)
  if (sucursalVista !== currentSucursalId) {
    setSucursalVista(currentSucursalId)
    setFiltros(prev => ({ ...prev, transportistaId: null }))
    setPagina(1)
  }

  const [salvedadResolver, setSalvedadResolver] = useState<SalvedadItemDBExtended | null>(null)
  const [salvedadAnular, setSalvedadAnular] = useState<SalvedadItemDBExtended | null>(null)

  const { perfil } = useAuthData()
  // Espejo de los gates de los RPCs (mig 252). La vista la ven admin y
  // encargado (App.tsx); resolver, los dos; anular, sólo admin. Qué salvedades
  // ve cada uno lo decide la RLS (mig 346: admin y encargado, toda la sucursal).
  const puedeAnular = puedeAnularSalvedad(perfil?.rol)
  const puedeResolver = puedeResolverSalvedad(perfil?.rol)

  // Lista y KPIs del servidor, con los mismos filtros. Resolver y anular
  // invalidan las dos (salvedadesKeys.all): no hay que recargar a mano.
  const lista = useSalvedadesQuery(filtros, pagina)
  const kpis = useEstadisticasSalvedadesQuery(filtros)
  const { data: transportistas = [] } = useTransportistasQuery()
  const resolverMutation = useResolverSalvedadMutation()
  const anularMutation = useAnularSalvedadMutation()

  const salvedades = lista.data ?? []
  const totalPaginas = Math.ceil(lista.total / SALVEDADES_PAGE_SIZE)
  const estadisticas = kpis.data
  const actualizando = lista.isFetching || kpis.isFetching

  // Se resolvió la última pendiente de la última página y esa página ya no
  // existe: volver a la última que sí existe, en vez de una lista vacía sin
  // paginador para salir.
  const { isSuccess, isPlaceholderData } = lista
  useEffect(() => {
    if (isSuccess && !isPlaceholderData && pagina > Math.max(1, totalPaginas)) {
      setPagina(Math.max(1, totalPaginas))
    }
  }, [isSuccess, isPlaceholderData, pagina, totalPaginas])

  const actualizar = () => {
    void lista.refetch()
    void kpis.refetch()
  }

  const handleResolver = async (data: {
    salvedadId: string;
    estadoResolucion: Exclude<EstadoResolucionSalvedad, 'pendiente' | 'anulada'>;
    notas: string;
  }) => {
    await resolverMutation.mutateAsync(data)
    setSalvedadResolver(null)
    return { success: true }
  }

  // Si la RPC rechaza --regalo de promo, merma no encontrada-- el error sube
  // al modal, que lo muestra y no se cierra.
  const handleAnular = async (salvedadId: string, notas: string) => {
    await anularMutation.mutateAsync({ salvedadId, notas })
  }

  return (
    <div className="p-4 md:p-6 space-y-6">
      {/* Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white flex items-center gap-2">
            <AlertTriangle className="w-7 h-7 text-amber-600" />
            Salvedades de Entregas
          </h1>
          <p className="text-gray-500 mt-1">Gestiona los items con problemas de entrega</p>
        </div>
        <Button
          onClick={actualizar}
          disabled={actualizando}
          variant="primary"
          size="md"
        >
          <RefreshCw className={`w-4 h-4 ${actualizando ? 'animate-spin' : ''}`} />
          Actualizar
        </Button>
      </div>

      {/* Filtros. El período (día argentino, sobre la fecha en que se registró)
          sólo rige con «Todas»: «Solo pendientes» muestra todas las pendientes,
          de cualquier fecha. Motivo y transportista rigen siempre. */}
      <div className="space-y-3">
        <div className="flex flex-wrap gap-3 items-center">
          <div className="flex items-center gap-2">
            <Filter className="w-5 h-5 text-gray-400" aria-hidden="true" />
            <select
              aria-label="Estado"
              value={filtros.estado}
              onChange={(e) => cambiarFiltros({ estado: e.target.value as SalvedadesFiltros['estado'] })}
              className={CLASES_SELECT}
            >
              <option value="pendientes">Solo pendientes</option>
              <option value="todas">Todas</option>
            </select>
          </div>

          <select
            aria-label="Motivo"
            value={filtros.motivo}
            onChange={(e) => cambiarFiltros({ motivo: e.target.value as MotivoSalvedad | 'todos' })}
            className={CLASES_SELECT}
          >
            <option value="todos">Todos los motivos</option>
            {Object.entries(MOTIVOS_SALVEDAD_LABELS).map(([value, label]) => (
              <option key={value} value={value}>{label}</option>
            ))}
          </select>

          <div className="flex items-center gap-2 min-w-0 max-w-full">
            <Truck className="w-5 h-5 text-gray-400 flex-shrink-0" aria-hidden="true" />
            <select
              aria-label="Transportista"
              value={filtros.transportistaId ?? ''}
              onChange={(e) => cambiarFiltros({ transportistaId: e.target.value || null })}
              className={`${CLASES_SELECT} min-w-0 max-w-full`}
            >
              <option value="">Todos los transportistas</option>
              {transportistas.map(t => (
                <option key={t.id} value={t.id}>{t.nombre}</option>
              ))}
            </select>
          </div>
        </div>

        {filtros.estado === 'todas' && (
          <PeriodPicker
            presets={PRESETS_PERIODO}
            activePresetId={preset}
            onSelectPreset={(id) => {
              setPreset(id)
              cambiarFiltros(rangoDePreset(id))
            }}
            desde={filtros.desde}
            hasta={filtros.hasta}
            onDesdeChange={(desde) => {
              setPreset(null)
              cambiarFiltros({ desde })
            }}
            onHastaChange={(hasta) => {
              setPreset(null)
              cambiarFiltros({ hasta })
            }}
            desdeMax={filtros.hasta || undefined}
            hastaMin={filtros.desde || undefined}
            etiqueta="Período"
          />
        )}
      </div>

      {/* Estadisticas: de TODA la lista filtrada (consulta aparte, mismos
          filtros), no de la página que se está mirando. */}
      {kpis.isError && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400 break-words">
          No se pudo calcular el resumen. {kpis.error?.message}
        </p>
      )}
      {estadisticas && (
        <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Total</p>
            <p className="text-2xl font-bold text-gray-800 dark:text-white" data-testid="kpi-total">{estadisticas.total}</p>
          </div>
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Pendientes</p>
            <p className="text-2xl font-bold text-amber-600" data-testid="kpi-pendientes">{estadisticas.pendientes}</p>
          </div>
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Resueltas</p>
            <p className="text-2xl font-bold text-green-600" data-testid="kpi-resueltas">{estadisticas.resueltas}</p>
          </div>
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Monto Total</p>
            <p className="text-xl font-bold text-red-600" data-testid="kpi-monto-total">{formatPrecio(estadisticas.monto_total_afectado)}</p>
          </div>
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Monto Pendiente</p>
            <p className="text-xl font-bold text-amber-600" data-testid="kpi-monto-pendiente">{formatPrecio(estadisticas.monto_pendiente)}</p>
          </div>
        </div>
      )}

      {/* Lista de salvedades */}
      {lista.isLoading ? (
        <div className="flex items-center justify-center py-12">
          <RefreshCw className="w-8 h-8 animate-spin text-blue-600" />
        </div>
      ) : lista.isError ? (
        <div className="text-center py-12">
          <AlertTriangle className="w-12 h-12 mx-auto text-red-300 dark:text-red-700" />
          <p className="mt-4 text-gray-500 break-words">{lista.error?.message || 'No se pudieron cargar las salvedades'}</p>
        </div>
      ) : salvedades.length === 0 ? (
        <div className="text-center py-12">
          <AlertTriangle className="w-12 h-12 mx-auto text-gray-300 dark:text-gray-600" />
          <p className="mt-4 text-gray-500">
            {filtros.estado === 'pendientes' ? 'No hay salvedades pendientes' : 'No hay salvedades en este periodo'}
          </p>
        </div>
      ) : (
        <>
          <div className="space-y-4">
            {salvedades.map(salvedad => (
              <SalvedadCard
                key={salvedad.id}
                salvedad={salvedad}
                onResolver={setSalvedadResolver}
                onAnular={setSalvedadAnular}
                puedeAnular={puedeAnular}
                puedeResolver={puedeResolver}
              />
            ))}
          </div>
          <Paginacion
            paginaActual={pagina}
            totalPaginas={totalPaginas}
            onPageChange={setPagina}
            totalItems={lista.total}
            itemsLabel="salvedades"
          />
        </>
      )}

      {/* Modal resolver salvedad */}
      {salvedadResolver && (
        <ModalResolverSalvedad
          salvedad={salvedadResolver}
          onResolver={handleResolver}
          onClose={() => setSalvedadResolver(null)}
        />
      )}

      {/* Modal anular salvedad (mig 244, #621) */}
      {salvedadAnular && (
        <ModalAnularSalvedad
          salvedad={salvedadAnular}
          onAnular={(notas) => handleAnular(salvedadAnular.id, notas)}
          onClose={() => setSalvedadAnular(null)}
        />
      )}
    </div>
  )
}

