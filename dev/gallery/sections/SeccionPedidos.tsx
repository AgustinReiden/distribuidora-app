/**
 * Panel de Pedidos: la superficie más cargada de la app y la que más estados tiene.
 *
 * `PedidoCard` se dibuja con TODOS los cruces que sabe distinguir (estado × estado
 * de pago × transportista × deuda previa × FC/ZZ × GPS), porque un rediseño que
 * sólo se probó contra "pendiente sin pagar" rompe los otros siete en silencio.
 *
 * `PanelPedidosTrabados` y `PanelPedidosNoEntregados` no reciben datos por props:
 * los piden con su propio `useQuery`. Se alimentan precargando la cache con la
 * queryKey real (ver `fixtures/cacheSeed.ts`).
 */
import { useState } from 'react'
import PedidoCard from '../../../src/components/pedidos/PedidoCard'
import PedidoStats from '../../../src/components/pedidos/PedidoStats'
import PedidoFilters, {
  type PedidoFiltersProps,
} from '../../../src/components/pedidos/PedidoFilters'
import PedidoToolbar from '../../../src/components/pedidos/PedidoToolbar'
import PedidosViewHeader from '../../../src/components/pedidos/PedidosViewHeader'
import PanelPedidosTrabados from '../../../src/components/pedidos/PanelPedidosTrabados'
import PanelPedidosNoEntregados from '../../../src/components/pedidos/PanelPedidosNoEntregados'
import { useAuthData } from '../../../src/contexts/AuthDataContext'
import type { FiltrosPedidosState, RolUsuario } from '../../../src/types'
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

function BloqueFiltros({ isAdmin, etiqueta }: { isAdmin: boolean; etiqueta: string }) {
  const [busqueda, setBusqueda] = useState('')
  const [filtros, setFiltros] = useState<PedidoFiltersProps['filtros']>({
    estado: 'todos',
    estadoPago: 'todos',
    transportistaId: 'todos',
    usuarioId: 'todos',
    conSalvedad: 'todos',
    fechaDesde: null,
    fechaHasta: null,
    verCancelados: false,
    fechaEntregaProgramada: null,
  })

  return (
    <Marco etiqueta={etiqueta}>
      <PedidoFilters
        busqueda={busqueda}
        filtros={filtros}
        transportistas={TRANSPORTISTAS_FIXTURE}
        usuarios={USUARIOS_FIXTURE}
        isAdmin={isAdmin}
        onBusquedaChange={setBusqueda}
        onFiltrosChange={(cambios) => setFiltros((prev) => ({ ...prev, ...cambios }))}
        onModalFiltroFecha={noop}
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
  const { isAdmin, isPreventista, isTransportista, isEncargado } = useAuthData()

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
            <PedidoStats summary={STATS_TIPICO} isEncargado={isEncargado} />
          </Marco>
          <Marco etiqueta="todo en cero">
            <PedidoStats summary={STATS_EN_CERO} isEncargado={isEncargado} />
          </Marco>
          <Marco etiqueta="aproximado · se pasó el tope de 20.000 filas (#524)">
            <PedidoStats summary={STATS_APROXIMADO} isEncargado={isEncargado} />
          </Marco>
        </div>
      </div>

      <div>
        <Subtitulo>PedidoFilters</Subtitulo>
        <div className="mt-3 space-y-4">
          <BloqueFiltros isAdmin etiqueta="isAdmin · segunda fila con pago, transportista, usuario y salvedades" />
          <BloqueFiltros isAdmin={false} etiqueta="no admin · sólo búsqueda, estado y fechas" />
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
