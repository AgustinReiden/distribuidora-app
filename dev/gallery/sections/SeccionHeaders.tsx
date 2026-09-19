/**
 * Los tres headers editoriales hermanos de `PedidosViewHeader`.
 *
 * El sufijo en cursiva sale de los filtros activos (`labelCategoriaProductos`,
 * `labelPeriodoDashboard`), así que cada combinación es un texto distinto: por eso
 * hay varias por header y no una sola.
 */
import ClientesViewHeader from '../../../src/components/clientes/ClientesViewHeader'
import ProductosViewHeader from '../../../src/components/productos/ProductosViewHeader'
import DashboardViewHeader from '../../../src/components/dashboard/DashboardViewHeader'
import { Marco, Seccion, Subtitulo } from '../ui/Marco'

function BotonDemo({ children }: { children: string }) {
  return (
    <button
      type="button"
      className="inline-flex items-center h-11 px-5 rounded-lg text-[14px] font-medium bg-white dark:bg-gray-800 text-stone-700 dark:text-gray-200 border border-stone-200/80 dark:border-gray-700 shadow-warm"
    >
      {children}
    </button>
  )
}

export default function SeccionHeaders() {
  return (
    <Seccion
      id="headers"
      titulo="Headers de vista"
      descripcion="Clientes, Productos y Dashboard. Comparten crumb, título con peso 800, sufijo en cursiva y el subrayado azul de 12 px."
    >
      <div>
        <Subtitulo>ClientesViewHeader</Subtitulo>
        <div className="mt-3 space-y-4">
          <Marco etiqueta="sin filtro descriptivo · con acciones">
            <ClientesViewHeader
              totalClientes={649}
              loading={false}
              actions={<BotonDemo>Nuevo cliente</BotonDemo>}
            />
          </Marco>
          <Marco etiqueta="filtrado por deuda">
            <ClientesViewHeader totalClientes={38} loading={false} filtroDescriptivo="con deuda" />
          </Marco>
          <Marco etiqueta="cargando · 1 resultado (singular)">
            <ClientesViewHeader totalClientes={1} loading filtroDescriptivo="del rubro Almacén" />
          </Marco>
        </div>
      </div>

      <div>
        <Subtitulo>ProductosViewHeader</Subtitulo>
        <div className="mt-3 space-y-4">
          <Marco etiqueta="catálogo completo">
            <ProductosViewHeader
              busqueda=""
              categoriaSeleccionada="todas"
              mostrarSoloStockBajo={false}
              totalCount={312}
              loading={false}
              actions={<BotonDemo>Nuevo producto</BotonDemo>}
            />
          </Marco>
          <Marco etiqueta="filtrado por categoría">
            <ProductosViewHeader
              busqueda=""
              categoriaSeleccionada="Gaseosas"
              mostrarSoloStockBajo={false}
              totalCount={44}
              loading={false}
            />
          </Marco>
          <Marco etiqueta="stock bajo (gana sobre los otros filtros)">
            <ProductosViewHeader
              busqueda="manaos"
              categoriaSeleccionada="Gaseosas"
              mostrarSoloStockBajo
              totalCount={6}
              loading={false}
            />
          </Marco>
        </div>
      </div>

      <div>
        <Subtitulo>DashboardViewHeader</Subtitulo>
        <div className="mt-3 space-y-4">
          <Marco etiqueta="admin · período mes">
            <DashboardViewHeader
              filtroPeriodo="mes"
              periodoLabel="Este mes"
              loading={false}
              actions={<BotonDemo>Exportar</BotonDemo>}
            />
          </Marco>
          <Marco etiqueta="preventista · verbo propio · período hoy">
            <DashboardViewHeader
              filtroPeriodo="hoy"
              verbo="Mis métricas"
              periodoLabel="Hoy"
              loading={false}
            />
          </Marco>
          <Marco etiqueta="rango personalizado · cargando">
            <DashboardViewHeader
              filtroPeriodo="personalizado"
              fechaDesde="2026-09-01"
              fechaHasta="2026-09-15"
              periodoLabel="1 al 15 de septiembre"
              loading
            />
          </Marco>
        </div>
      </div>
    </Seccion>
  )
}
