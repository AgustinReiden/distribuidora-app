/**
 * Los componentes compartidos: lo que se repite en todas las vistas y por eso es
 * lo primero que hay que mirar cuando se cambia el lenguaje visual.
 *
 * Los modales se abren con un botón en vez de renderizarse siempre: un `Dialog`
 * de Radix monta un overlay a pantalla completa y taparía el resto de la galería.
 */
import { useState } from 'react'
import { Plus, Package, Truck } from 'lucide-react'
import LoadingSpinner from '../../../src/components/layout/LoadingSpinner'
import Paginacion from '../../../src/components/layout/Paginacion'
import QueryErrorState from '../../../src/components/layout/QueryErrorState'
import EmptyState, {
  EmptyClientes,
  EmptyPedidos,
  EmptyProductos,
  EmptySearchResults,
  ErrorState,
  NotFoundState,
} from '../../../src/components/ui/EmptyState'
import Skeleton, {
  SkeletonText,
  SkeletonTitle,
  SkeletonAvatar,
  SkeletonListItem,
  SkeletonTable,
  SkeletonForm,
  SkeletonStatCard,
  SkeletonPedidoCard,
  SkeletonProductCard,
} from '../../../src/components/ui/Skeleton'
import ModalConfirmacion, {
  type ModalConfirmacionConfig,
  type ModalConfirmacionTipo,
} from '../../../src/components/modals/ModalConfirmacion'
import ModalBase from '../../../src/components/modals/ModalBase'
import BottomSheet from '../../../src/components/ui/BottomSheet'
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
} from '../../../src/components/ui/DropdownMenu'
import { Marco, Seccion, Subtitulo } from '../ui/Marco'

const noop = (): void => {}

const BOTON =
  'inline-flex items-center gap-2 h-10 px-4 rounded-lg text-sm font-medium bg-white dark:bg-gray-800 text-stone-700 dark:text-gray-200 border border-stone-200 dark:border-gray-700 shadow-warm hover:bg-stone-50 dark:hover:bg-gray-700/50 transition-colors'

const CONFIGS_CONFIRMACION: Record<ModalConfirmacionTipo, Omit<ModalConfirmacionConfig, 'onConfirm'>> = {
  danger: {
    visible: true,
    tipo: 'danger',
    titulo: 'Cancelar pedido #18398',
    mensaje:
      'Se le devuelve el stock al depósito y el total del pedido pasa a $0. La acción queda en el historial.',
  },
  warning: {
    visible: true,
    tipo: 'warning',
    titulo: 'Volver a pendiente',
    mensaje:
      'El pedido se desasigna del transportista y sale de la ruta en curso. Va a volver a aparecer al armar la ruta del día.',
  },
  success: {
    visible: true,
    tipo: 'success',
    titulo: 'Marcar como entregado',
    mensaje: 'Elegí el día real de la entrega: es el que define en qué rendición entra.',
    campoFecha: {
      label: 'Fecha de entrega',
      valorInicial: new Date().toISOString().slice(0, 10),
      max: new Date().toISOString().slice(0, 10),
      ayuda: 'Marcar hoy las entregas de ayer deja la rendición de ayer vacía.',
    },
  },
}

function BloqueConfirmaciones() {
  const [tipo, setTipo] = useState<ModalConfirmacionTipo | null>(null)

  const config: ModalConfirmacionConfig | null = tipo
    ? { ...CONFIGS_CONFIRMACION[tipo], onConfirm: () => setTipo(null) }
    : null

  return (
    <Marco etiqueta="ModalConfirmacion · danger / warning / success (el success trae campo de fecha)">
      <div className="flex flex-wrap gap-2">
        <button type="button" className={BOTON} onClick={() => setTipo('danger')}>
          Abrir danger
        </button>
        <button type="button" className={BOTON} onClick={() => setTipo('warning')}>
          Abrir warning
        </button>
        <button type="button" className={BOTON} onClick={() => setTipo('success')}>
          Abrir success
        </button>
      </div>
      <ModalConfirmacion config={config} onClose={() => setTipo(null)} />
    </Marco>
  )
}

/**
 * El caso de 8 de los 15 usos reales: la confirmación se dispara desde ADENTRO
 * de un `ModalBase` y se renderiza como hija suya. Tiene que verse por encima
 * del modal, y Escape tiene que cerrar sólo la confirmación.
 */
function BloqueConfirmacionAnidada() {
  const [abierto, setAbierto] = useState(false)
  const [confirmando, setConfirmando] = useState(false)

  const config: ModalConfirmacionConfig | null = confirmando
    ? {
        visible: true,
        tipo: 'danger',
        titulo: 'Quitar línea',
        mensaje: 'Se quita "Manaos Cola 2,25 L × 12" del pedido. El stock vuelve al depósito al guardar.',
        onConfirm: () => setConfirmando(false),
      }
    : null

  return (
    <Marco etiqueta="ModalConfirmacion anidada · se abre desde adentro de un ModalBase y queda por encima">
      <button type="button" className={BOTON} onClick={() => setAbierto(true)}>
        Abrir ModalBase con confirmación
      </button>
      {abierto && (
        <ModalBase title="Editar pedido #18398" onClose={() => setAbierto(false)}>
          <div className="p-4 space-y-3 text-sm text-gray-700 dark:text-gray-300">
            <div className="flex items-center justify-between border-b dark:border-gray-700 pb-2">
              <span>Manaos Cola 2,25 L × 12</span>
              <button
                type="button"
                onClick={() => setConfirmando(true)}
                className="px-3 py-1.5 rounded-lg text-sm font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/30"
              >
                Quitar
              </button>
            </div>
            <p className="text-xs text-gray-500 dark:text-gray-400">
              Escape con la confirmación abierta cierra sólo la confirmación; el modal sigue abierto.
            </p>
          </div>
          <ModalConfirmacion config={config} onClose={() => setConfirmando(false)} />
        </ModalBase>
      )}
    </Marco>
  )
}

function BloqueModalBase() {
  const [abierto, setAbierto] = useState(false)

  return (
    <Marco etiqueta="ModalBase · Radix Dialog con focus trap, Escape y contenido largo con scroll interno">
      <button type="button" className={BOTON} onClick={() => setAbierto(true)}>
        Abrir ModalBase
      </button>
      {abierto && (
        <ModalBase
          title="Detalle de la compra #2481"
          description="Manaos Tucumán S.A. · factura ZZ 0003-00018204"
          maxWidth="max-w-2xl"
          onClose={() => setAbierto(false)}
          headerExtra={
            <span className="px-2 py-0.5 rounded text-[11px] font-bold tracking-wider bg-gray-100 text-gray-500 dark:bg-gray-700 dark:text-gray-400">
              ZZ
            </span>
          }
        >
          <div className="p-4 space-y-3 text-sm text-gray-700 dark:text-gray-300">
            {Array.from({ length: 14 }).map((_, i) => (
              <div
                key={i}
                className="flex items-center justify-between border-b dark:border-gray-700 pb-2 last:border-0"
              >
                <span>Línea {i + 1} · Manaos Cola 2,25 L × {12 + i * 6}</span>
                <span className="tabular-nums font-medium">
                  $ {((12 + i * 6) * 1450).toLocaleString('es-AR')}
                </span>
              </div>
            ))}
          </div>
        </ModalBase>
      )}
    </Marco>
  )
}

const LINEAS_COMPRA = Array.from({ length: 30 }).map((_, i) => {
  const cantidad = 12 + i * 6
  const costo = 1450 + (i % 5) * 120
  return { id: i + 1, cantidad, costo, subtotal: cantidad * costo }
})

/**
 * `bodyBare`: el hijo trae su propia columna, con el área larga en
 * `flex-1 overflow-y-auto` y un footer `flex-shrink-0`. Scrollea sólo la lista;
 * el footer con los botones queda siempre a la vista (con el `DialogBody` de
 * siempre se iría abajo junto con el contenido).
 */
function BloqueModalBaseBare() {
  const [abierto, setAbierto] = useState(false)
  const total = LINEAS_COMPRA.reduce((acc, l) => acc + l.subtotal, 0)

  return (
    <Marco etiqueta="ModalBase · bodyBare + max-w-6xl: el contenido trae su scroll y el footer queda fijo">
      <button type="button" className={BOTON} onClick={() => setAbierto(true)}>
        Abrir ModalBase bodyBare
      </button>
      {abierto && (
        <ModalBase
          title="Nueva compra"
          description="Manaos Tucumán S.A. · 30 líneas"
          maxWidth="max-w-6xl"
          bodyBare
          onClose={() => setAbierto(false)}
        >
          <div className="flex flex-1 min-h-0 flex-col">
            <div className="flex-1 overflow-y-auto overscroll-contain p-4">
              <table className="w-full text-sm text-gray-700 dark:text-gray-300">
                <thead className="text-xs text-left text-gray-500 dark:text-gray-400">
                  <tr className="border-b dark:border-gray-700">
                    <th className="py-2 font-medium">Producto</th>
                    <th className="py-2 font-medium text-right">Cantidad</th>
                    <th className="py-2 font-medium text-right">Costo unit.</th>
                    <th className="py-2 font-medium text-right">Subtotal</th>
                  </tr>
                </thead>
                <tbody>
                  {LINEAS_COMPRA.map((l) => (
                    <tr key={l.id} className="border-b dark:border-gray-700 last:border-0">
                      <td className="py-2">Línea {l.id} · Manaos Cola 2,25 L</td>
                      <td className="py-2 text-right tabular-nums">{l.cantidad}</td>
                      <td className="py-2 text-right tabular-nums">
                        $ {l.costo.toLocaleString('es-AR')}
                      </td>
                      <td className="py-2 text-right tabular-nums font-medium">
                        $ {l.subtotal.toLocaleString('es-AR')}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="flex-shrink-0 flex flex-wrap items-center justify-between gap-3 p-4 border-t dark:border-gray-700">
              <span className="text-sm text-gray-600 dark:text-gray-300">
                Total{' '}
                <span className="tabular-nums font-semibold text-gray-900 dark:text-white">
                  $ {total.toLocaleString('es-AR')}
                </span>
              </span>
              <div className="flex gap-2">
                <button type="button" className={BOTON} onClick={() => setAbierto(false)}>
                  Cancelar
                </button>
                <button
                  type="button"
                  onClick={() => setAbierto(false)}
                  className="h-10 px-4 rounded-lg bg-blue-600 text-white text-sm font-medium"
                >
                  Registrar compra
                </button>
              </div>
            </div>
          </div>
        </ModalBase>
      )}
    </Marco>
  )
}

function BloqueBottomSheet() {
  const [abierto, setAbierto] = useState(false)

  return (
    <Marco etiqueta="BottomSheet · sube desde abajo, drag handle visual, footer sticky con safe-area">
      <button type="button" className={BOTON} onClick={() => setAbierto(true)}>
        Abrir BottomSheet
      </button>
      <BottomSheet
        open={abierto}
        onClose={() => setAbierto(false)}
        title="Filtros"
        description="3 filtros activos"
        footer={
          <div className="flex gap-2">
            <button type="button" className={`${BOTON} flex-1 justify-center`}>
              Limpiar
            </button>
            <button
              type="button"
              onClick={() => setAbierto(false)}
              className="flex-1 h-10 rounded-lg bg-blue-600 text-white text-sm font-medium"
            >
              Listo
            </button>
          </div>
        }
      >
        <div className="space-y-3 text-sm text-stone-700 dark:text-stone-300">
          {['Estado', 'Estado de pago', 'Transportista', 'Usuario', 'Salvedades', 'Entrega'].map(
            (campo) => (
              <div key={campo}>
                <p className="text-xs font-medium text-stone-500 dark:text-stone-400">{campo}</p>
                <div className="mt-1 h-10 rounded-lg border border-stone-200 dark:border-gray-700 bg-white dark:bg-gray-900 flex items-center px-3">
                  Todos
                </div>
              </div>
            ),
          )}
        </div>
      </BottomSheet>
    </Marco>
  )
}

export default function SeccionCompartidos() {
  const [pagina, setPagina] = useState(3)

  return (
    <Seccion
      id="compartidos"
      titulo="Compartidos"
      descripcion="Estados de carga, vacío y error; paginación; modales y menús. Lo que aparece en todas las vistas."
    >
      <div className="grid gap-4 md:grid-cols-2">
        <Marco etiqueta="LoadingSpinner · texto por defecto">
          <LoadingSpinner />
        </Marco>
        <Marco etiqueta="LoadingSpinner · texto propio">
          <LoadingSpinner text="Armando la ruta del día…" />
        </Marco>
        <Marco etiqueta="QueryErrorState · con reintento">
          <QueryErrorState onRetry={noop} />
        </Marco>
        <Marco etiqueta="QueryErrorState · sin reintento">
          <QueryErrorState />
        </Marco>
      </div>

      <div>
        <Subtitulo>Paginacion</Subtitulo>
        <div className="mt-3 grid gap-4 md:grid-cols-2">
          <Marco etiqueta="página 3 de 12">
            <Paginacion
              paginaActual={pagina}
              totalPaginas={12}
              onPageChange={setPagina}
              totalItems={241}
              itemsLabel="pedidos"
            />
          </Marco>
          <Marco etiqueta="1 sola página · el componente devuelve null a propósito">
            <Paginacion
              paginaActual={1}
              totalPaginas={1}
              onPageChange={noop}
              totalItems={7}
              itemsLabel="pedidos"
            />
            <p className="text-xs text-stone-500 dark:text-stone-400">(no renderiza nada)</p>
          </Marco>
        </div>
      </div>

      <div>
        <Subtitulo>EmptyState y sus variantes</Subtitulo>
        <div className="mt-3 grid gap-4 md:grid-cols-2">
          <Marco etiqueta="EmptyState · sin datos, con acción">
            <EmptyState
              entityName="pedidos"
              action={
                <button type="button" className={BOTON}>
                  <Plus className="w-4 h-4" />
                  Nuevo pedido
                </button>
              }
            />
          </Marco>
          <Marco etiqueta="EmptyState · filtrado con término de búsqueda">
            <EmptyState entityName="productos" isFiltered searchTerm="manaos lima" />
          </Marco>
          <Marco etiqueta="EmptyState · size sm / lg + icono propio">
            <div className="space-y-2">
              <EmptyState size="sm" icon={Package} title="Sin lotes cargados" description="Este producto todavía no tiene vencimientos." />
              <EmptyState size="lg" icon={Truck} title="Sin ruta para hoy" description="Armá la ruta del día para ver las paradas." />
            </div>
          </Marco>
          <Marco etiqueta="EmptyClientes / EmptyPedidos / EmptyProductos">
            <div className="space-y-2">
              <EmptyClientes />
              <EmptyPedidos searchTerm="don ramón" />
              <EmptyProductos />
            </div>
          </Marco>
          <Marco etiqueta="EmptySearchResults">
            <EmptySearchResults searchTerm="yerba 3 kg" entityName="productos" />
          </Marco>
          <Marco etiqueta="ErrorState / NotFoundState">
            <div className="space-y-2">
              <ErrorState />
              <NotFoundState />
            </div>
          </Marco>
        </div>
      </div>

      <div>
        <Subtitulo>Skeleton</Subtitulo>
        <div className="mt-3 grid gap-4 md:grid-cols-2">
          <Marco etiqueta="primitivas · Skeleton, SkeletonText, SkeletonTitle, SkeletonAvatar">
            <div className="space-y-3">
              <Skeleton height={40} rounded="rounded-lg" />
              <SkeletonTitle />
              <SkeletonText width="80%" />
              <SkeletonText width="55%" />
              <SkeletonAvatar size={48} />
              <Skeleton height={24} rounded="rounded-full" width={120} animate={false} />
            </div>
          </Marco>
          <Marco etiqueta="SkeletonListItem × 3">
            <div>
              <SkeletonListItem />
              <SkeletonListItem />
              <SkeletonListItem />
            </div>
          </Marco>
          <Marco etiqueta="SkeletonPedidoCard">
            <SkeletonPedidoCard />
          </Marco>
          <Marco etiqueta="SkeletonProductCard">
            <SkeletonProductCard />
          </Marco>
          <Marco etiqueta="SkeletonStatCard × 2">
            <div className="grid grid-cols-2 gap-3">
              <SkeletonStatCard />
              <SkeletonStatCard />
            </div>
          </Marco>
          <Marco etiqueta="SkeletonForm · 3 campos">
            <SkeletonForm fields={3} />
          </Marco>
          <Marco etiqueta="SkeletonTable · 4 filas × 5 columnas">
            <SkeletonTable rows={4} columns={5} />
          </Marco>
        </div>
      </div>

      <div>
        <Subtitulo>Modales y menús</Subtitulo>
        <div className="mt-3 space-y-4">
          <BloqueConfirmaciones />
          <BloqueConfirmacionAnidada />
          <BloqueModalBase />
          <BloqueModalBaseBare />
          <BloqueBottomSheet />
          <Marco etiqueta="DropdownMenu · label, items, separador y shortcut">
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <button type="button" className={BOTON}>
                  Abrir menú
                </button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start" className="w-60">
                <DropdownMenuLabel>Acciones del pedido</DropdownMenuLabel>
                <DropdownMenuItem>
                  <Package className="w-4 h-4 text-orange-600" />
                  <span>Marcar en preparación</span>
                </DropdownMenuItem>
                <DropdownMenuItem>
                  <Truck className="w-4 h-4 text-blue-600" />
                  <span>Asignar transportista</span>
                  <DropdownMenuShortcut>⌘T</DropdownMenuShortcut>
                </DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem disabled>
                  <Plus className="w-4 h-4" />
                  <span>Item deshabilitado</span>
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </Marco>
        </div>
      </div>
    </Seccion>
  )
}
