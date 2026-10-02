/**
 * Dashboard (WP-47, #772): la `VistaDashboard` REAL con métricas de fixture.
 *
 * Los booleanos de rol se pasan por props en cada marco (no salen del selector de
 * la barra), así que Admin y Preventista se ven a la vez. La diferencia a mirar:
 * el preventista puro no tiene Tasa de entrega y su grilla de métricas pasa a dos
 * columnas desde 375px (`min-[375px]`). Para ver esa grilla hay que angostar la
 * ventana: los marcos no emulan viewport.
 */
import VistaDashboard from '../../../src/components/vistas/VistaDashboard'
import {
  AVANCE_METAS_DASHBOARD,
  METRICAS_DASHBOARD,
  PRODUCTOS_STOCK_BAJO_DASHBOARD,
  TOTAL_CLIENTES_DASHBOARD,
} from '../fixtures/dashboard'
import { Marco, Seccion } from '../ui/Marco'

const noop = (): void => {}
const sinBackup = async (): Promise<void> => {}

function Dashboard({ isAdmin, isPreventista }: { isAdmin: boolean; isPreventista: boolean }) {
  return (
    <VistaDashboard
      metricas={METRICAS_DASHBOARD}
      loading={false}
      filtroPeriodo="mes"
      onCambiarPeriodo={noop}
      onRefetch={noop}
      onDescargarBackup={sinBackup}
      exportando={false}
      productosStockBajo={PRODUCTOS_STOCK_BAJO_DASHBOARD}
      totalClientes={TOTAL_CLIENTES_DASHBOARD}
      avanceMetas={AVANCE_METAS_DASHBOARD}
      isAdmin={isAdmin}
      isPreventista={isPreventista}
      isEncargado={false}
    />
  )
}

export default function SeccionDashboard() {
  return (
    <Seccion
      id="dashboard"
      titulo="Dashboard"
      descripcion={
        <>
          <code>VistaDashboard</code> con las mismas métricas de fixture en dos roles. El
          preventista puro no ve la Tasa de entrega (decisión del dueño del 26/09) y su
          grilla de métricas principales pasa a dos columnas desde 375&nbsp;px.
        </>
      }
    >
      <Marco etiqueta="Admin · isAdmin · Resumen, con Top 5 y Tasa de entrega">
        <Dashboard isAdmin isPreventista={false} />
      </Marco>
      <Marco etiqueta="Preventista · isPreventista · Mis métricas, sin Tasa de entrega">
        <Dashboard isAdmin={false} isPreventista />
      </Marco>
    </Seccion>
  )
}
