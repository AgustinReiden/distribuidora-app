/**
 * Panel de Pedidos: la superficie más cargada de la app y la que más estados tiene.
 *
 * `PedidoCard` se dibuja con TODOS los cruces que sabe distinguir (estado × estado
 * de pago × transportista × deuda previa × FC/ZZ × GPS), porque un rediseño que
 * sólo se probó contra "pendiente sin pagar" rompe los otros siete en silencio.
 *
 * `PanelPedidosTrabados` y `PanelPedidosNoEntregados` no reciben datos por props:
 * los piden con su propio `useQuery`. Se alimentan precargando la cache con la
 * queryKey real (ver `fixtures/cacheSeed.ts`). `AvisosPedidos`, la línea que los
 * pliega en /pedidos, lee esas mismas queries, así que la misma siembra le alcanza.
 */
import { useState } from 'react'
import PedidoCard from '../../../src/components/pedidos/PedidoCard'
import PedidoStats from '../../../src/components/pedidos/PedidoStats'
import PedidoFilters, {
  type PedidoFiltersProps,
} from '../../../src/components/pedidos/PedidoFilters'
import PanelFiltrosPedidos, {
  PieFiltrosPedidos,
} from '../../../src/components/pedidos/PanelFiltrosPedidos'
import PedidoToolbar from '../../../src/components/pedidos/PedidoToolbar'
import PedidosViewHeader from '../../../src/components/pedidos/PedidosViewHeader'
import PanelPedidosTrabados from '../../../src/components/pedidos/PanelPedidosTrabados'
import PanelPedidosNoEntregados from '../../../src/components/pedidos/PanelPedidosNoEntregados'
import AvisosPedidos from '../../../src/components/pedidos/AvisosPedidos'
import { useAuthData } from '../../../src/contexts/AuthDataContext'
import type { FiltrosPedidosState, RolUsuario } from '../../../src/types'
import { kpiActivo, type FiltrosKpi } from '../../../src/utils/kpiFiltroPedidos'
import { contarFiltrosActivos, describirFiltrosActivos } from '../../../src/utils/filtrosPedidos'
import { fechaLocalISO } from '../../../src/utils/formatters'
import {
  PEDIDOS_FIXTURE,
  STATS_APROXIMADO,
  STATS_EN_CERO,
  STATS_TIPICO,
} from '../fixtures/pedidos'
import { TRANSPORTISTAS_FIXTURE, USUARIOS_FIXTURE } from '../fixtures/catalogo'
import { ETIQUETA_ROL, ROLES_GALERIA } from '../fixtures/auth'
import { Marco, Seccion, Subtitulo } from '../ui/Marco'

const noop = (): void => {}

const FILTROS_HEADER_DIA: FiltrosPedidosState = {
  fechaDesde: null,
  fechaHasta: null,
  estado: 'todos',
  estadoPago: 'todos',
  transportistaId: 'todos',
  busqueda: '',
  conSalvedad: 'todos',
}

const FILTROS_HEADER_ENTREGA: FiltrosPedidosState = {
  ...FILTROS_HEADER_DIA,
  fechaEntregaProgramada: new Date().toISOString().slice(0, 10),
}

type FiltrosBarra = PedidoFiltersProps['filtros']

const FILTROS_BARRA_VACIOS: FiltrosBarra = {
  estado: 'todos',
  estadoPago: 'todos',
  transportistaId: 'todos',
  usuarioId: 'todos',
  conSalvedad: 'todos',
  fechaDesde: null,
  fechaHasta: null,
  verCancelados: false,
  fechaEntregaProgramada: null,
}

/** Todos los filtros puestos a la vez, para ver la fila de chips completa (#769). */
const FILTROS_BARRA_TODOS: FiltrosBarra = {
  estado: 'entregado',
  estadoPago: 'impago',
  transportistaId: TRANSPORTISTAS_FIXTURE[0].id,
  usuarioId: USUARIOS_FIXTURE[0].id,
  conSalvedad: 'con_salvedad',
  fechaDesde: '2026-04-01',
  fechaHasta: '2026-04-15',
  verCancelados: true,
  fechaEntregaProgramada: fechaLocalISO(),
}

function BloqueFiltros({
  isAdmin,
  etiqueta,
  inicial = FILTROS_BARRA_VACIOS,
}: {
  isAdmin: boolean
  etiqueta: string
  inicial?: FiltrosBarra
}) {
  const [busqueda, setBusqueda] = useState('')
  const [filtros, setFiltros] = useState<FiltrosBarra>(inicial)

  return (
    <Marco etiqueta={etiqueta}>
      <PedidoFilters
        busqueda={busqueda}
        filtros={filtros}
        transportistas={TRANSPORTISTAS_FIXTURE}
        usuarios={isAdmin ? USUARIOS_FIXTURE : []}
        isAdmin={isAdmin}
        onBusquedaChange={setBusqueda}
        onFiltrosChange={(cambios) => setFiltros((prev) => ({ ...prev, ...cambios }))}
      />
    </Marco>
  )
}

/**
 * El panel ABIERTO, dibujado en el lugar y con el ancho del popover de escritorio.
 * El popover y el sheet del celular envuelven este mismo componente; el sheet
 * real no se monta acá porque taparía la galería entera con su overlay.
 */
function PanelAbierto({ isAdmin, etiqueta, inicial }: { isAdmin: boolean; etiqueta: string; inicial: FiltrosBarra }) {
  const [filtros, setFiltros] = useState<FiltrosBarra>(inicial)
  const activos = contarFiltrosActivos(filtros, { isAdmin })
  const cambiar = (cambios: Partial<FiltrosBarra>) => setFiltros((prev) => ({ ...prev, ...cambios }))

  return (
    <Marco etiqueta={etiqueta}>
      <div
        className="flex flex-col w-[22rem] max-w-full rounded-xl border border-stone-200 dark:border-gray-700 bg-white dark:bg-gray-800 shadow-lg"
      >
        <div className="px-4 pt-3 pb-2 border-b border-stone-200 dark:border-gray-700">
          <p className="text-sm font-semibold text-stone-900 dark:text-white">Filtros</p>
          <p className="text-xs text-stone-500 dark:text-stone-400 mt-0.5">{describirFiltrosActivos(activos)}</p>
        </div>
        <div className="px-4 py-3">
          <PanelFiltrosPedidos
            filtros={filtros}
            transportistas={TRANSPORTISTAS_FIXTURE}
            usuarios={isAdmin ? USUARIOS_FIXTURE : []}
            isAdmin={isAdmin}
            onFiltrosChange={cambiar}
          />
        </div>
        <div className="px-4 py-3 border-t border-stone-200 dark:border-gray-700">
          <PieFiltrosPedidos activosCount={activos} onFiltrosChange={cambiar} onListo={noop} tamanoListo="md" />
        </div>
      </div>
    </Marco>
  )
}

/**
 * Los tiles como filtro (#715): con `filtros` + `onFiltrosChange` son botones
 * toggle. El estado es local; arranca con "En camino" + "Impagos" aplicados para
 * que se vean los dos modos (presionado / suelto) sin tocar nada.
 */
function StatsInteractivos({ isEncargado, isDeposito }: { isEncargado: boolean; isDeposito: boolean }) {
  const [filtros, setFiltros] = useState<FiltrosKpi>({ estado: 'asignado', estadoPago: 'impago' })
  const activo = kpiActivo(filtros)

  return (
    <Marco
      etiqueta={`interactivo · estado=${filtros.estado} · pago=${filtros.estadoPago} · tile principal: ${activo ?? 'ninguno'}`}
    >
      <PedidoStats
        summary={STATS_TIPICO}
        isEncargado={isEncargado}
        isDeposito={isDeposito}
        filtros={filtros}
        onFiltrosChange={(cambios) => setFiltros((prev) => ({ ...prev, ...cambios }))}
      />
    </Marco>
  )
}

function ToolbarDeRol({ rol }: { rol: RolUsuario }) {
  const esAdmin = rol === 'admin'
  const esEncargado = rol === 'encargado'
  const esPreventista = rol === 'preventista'
  const opsMasivas = esAdmin || esEncargado

  return (
    <Marco etiqueta={`PedidoToolbar · ${ETIQUETA_ROL[rol]}`}>
      <PedidoToolbar
        isAdmin={esAdmin}
        isEncargado={esEncargado}
        isPreventista={esPreventista}
        exportando={false}
        totalCount={241}
        onNuevoPedido={noop}
        onOptimizarRuta={noop}
        onExportarPDF={noop}
        onExportarExcel={noop}
        onCambioEnRuta={opsMasivas ? noop : undefined}
        onPagosMasivos={opsMasivas ? noop : undefined}
        onEntregasMasivas={opsMasivas ? noop : undefined}
        onEntregaYPagoMasivos={opsMasivas ? noop : undefined}
        onMarcarVisita={esPreventista ? noop : undefined}
        onVerVisitasHoy={esPreventista ? noop : undefined}
        onVerMiRuta={rol === 'transportista' ? noop : undefined}
        paradasPendientes={rol === 'transportista' ? 7 : undefined}
      />
    </Marco>
  )
}

export default function SeccionPedidos() {
  const { isAdmin, isPreventista, isTransportista, isEncargado, isDeposito } = useAuthData()

  return (
    <Seccion
      id="pedidos"
      titulo="Pedidos"
      descripcion={
        <>
          Componentes reales de <code>src/components/pedidos/</code>. Los booleanos de rol
          salen del selector de la barra de arriba, salvo en <code>PedidoToolbar</code>, que
          los recibe por props y por eso se muestra en los cinco roles a la vez.
        </>
      }
    >
      <div>
        <Subtitulo>PedidosViewHeader</Subtitulo>
        <div className="mt-3 space-y-4">
          <Marco etiqueta="sin filtros · con PedidoToolbar como acciones">
            <PedidosViewHeader
              filtros={FILTROS_HEADER_DIA}
              totalCount={241}
              loading={false}
              actions={
                <PedidoToolbar
                  isAdmin={isAdmin}
                  isEncargado={isEncargado}
                  isPreventista={isPreventista}
                  exportando={false}
                  totalCount={241}
                  onNuevoPedido={noop}
                  onOptimizarRuta={noop}
                  onExportarPDF={noop}
                  onExportarExcel={noop}
                  onPagosMasivos={isAdmin || isEncargado ? noop : undefined}
                  onEntregasMasivas={isAdmin || isEncargado ? noop : undefined}
                />
              }
            />
          </Marco>
          <Marco etiqueta="filtrado por entrega de hoy · cargando">
            <PedidosViewHeader
              filtros={FILTROS_HEADER_ENTREGA}
              totalCount={0}
              loading
            />
          </Marco>
        </div>
      </div>

      <div>
        <Subtitulo>PedidoStats</Subtitulo>
        <div className="mt-3 space-y-4">
          <Marco etiqueta="summary típico · el encargado sólo ve el monto de impagos">
            <PedidoStats summary={STATS_TIPICO} isEncargado={isEncargado} isDeposito={isDeposito} />
          </Marco>
          <Marco etiqueta="todo en cero">
            <PedidoStats summary={STATS_EN_CERO} isEncargado={isEncargado} isDeposito={isDeposito} />
          </Marco>
          <Marco etiqueta="aproximado · se pasó el tope de 20.000 filas (#524)">
            <PedidoStats summary={STATS_APROXIMADO} isEncargado={isEncargado} isDeposito={isDeposito} />
          </Marco>
          <StatsInteractivos isEncargado={isEncargado} isDeposito={isDeposito} />
        </div>
      </div>

      <div>
        <Subtitulo>PedidoFilters</Subtitulo>
        <div className="mt-3 space-y-4">
          <BloqueFiltros isAdmin etiqueta="admin · sin filtros: buscador + un solo trigger «Filtros»" />
          <BloqueFiltros
            isAdmin
            inicial={FILTROS_BARRA_TODOS}
            etiqueta="admin · todos los filtros puestos: un chip por filtro, cada uno con su X"
          />
          <BloqueFiltros isAdmin={false} etiqueta="no admin · sin filtros" />
          <BloqueFiltros
            isAdmin={false}
            inicial={FILTROS_BARRA_TODOS}
            etiqueta="no admin · mismos filtros puestos: sólo ve estado, impagos (del tile), cancelados y fechas (#733)"
          />
          <PanelAbierto
            isAdmin
            inicial={FILTROS_BARRA_TODOS}
            etiqueta="panel abierto · admin · las ocho secciones con los valores vigentes"
          />
          <PanelAbierto
            isAdmin={false}
            inicial={{ ...FILTROS_BARRA_VACIOS, fechaDesde: '2026-05-31', fechaHasta: '2026-05-01' }}
            etiqueta="panel abierto · no admin · estado, fecha de carga y cancelados; rango invertido avisado (#734)"
          />
        </div>
      </div>

      <div>
        <Subtitulo>PedidoToolbar por rol</Subtitulo>
        <div className="mt-3 space-y-4">
          {ROLES_GALERIA.map((rol) => (
            <ToolbarDeRol key={rol} rol={rol} />
          ))}
        </div>
      </div>

      <div>
        <Subtitulo>Paneles de rescate (alimentados por cache)</Subtitulo>
        <div className="mt-3 space-y-4">
          <Marco etiqueta="AvisosPedidos · admin/encargado · plegado; al desplegar muestra los dos paneles">
            <AvisosPedidos enabled onVolverAPendiente={noop} />
          </Marco>
          <Marco etiqueta="AvisosPedidos · sin permiso de rescate · los trabados no cuentan">
            <AvisosPedidos enabled={false} onVolverAPendiente={noop} />
          </Marco>
          <Marco etiqueta="PanelPedidosTrabados · admin/encargado · 4 pedidos, el más viejo de 23 días">
            <PanelPedidosTrabados enabled onVolverAPendiente={noop} />
          </Marco>
          <Marco etiqueta="PanelPedidosNoEntregados · vista del preventista">
            <PanelPedidosNoEntregados />
          </Marco>
        </div>
      </div>

      <div>
        <Subtitulo>PedidoCard</Subtitulo>
        <div className="mt-3 space-y-4">
          {PEDIDOS_FIXTURE.map(({ etiqueta, pedido }) => (
            <Marco key={pedido.id} etiqueta={`#${pedido.id} · ${etiqueta}`}>
              <PedidoCard
                pedido={pedido}
                isAdmin={isAdmin}
                isPreventista={isPreventista}
                isTransportista={isTransportista}
                isEncargado={isEncargado}
                onVerHistorial={noop}
                onEditarPedido={noop}
                onEditarNotas={noop}
                onMarcarEnPreparacion={noop}
                onVolverAPendiente={noop}
                onMarcarEntregado={noop}
                onMarcarEntregadoConSalvedad={noop}
                onDesmarcarEntregado={noop}
                onCancelarPedido={noop}
                onRegistrarPago={noop}
              />
            </Marco>
          ))}
        </div>
      </div>
    </Seccion>
  )
}
