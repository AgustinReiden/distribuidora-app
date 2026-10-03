/**
 * "Hoy" del preventista (WP-48, #773): la `VistaHoy` REAL con datos de fixture.
 *
 * Los marcos muestran los estados que importan: el día con visitas y metas, el
 * día recién empezado (sin visitas ni metas), la carga y el error. El último
 * marco es un celular de 375 px con el header y la barra inferior reales del
 * preventista alrededor, para ver la pantalla entre los dos (mismo truco de
 * `transform` que la sección Navegación). La galería corre en /pedidos, así que
 * en esa barra el destino marcado es Pedidos y no Hoy.
 */
import TopNavigation from '../../../src/components/layout/TopNavigation'
import VistaHoy from '../../../src/components/vistas/VistaHoy'
import { AuthDataProvider } from '../../../src/contexts/AuthDataContext'
import { authDataDeRol, PERFILES_FIXTURE } from '../fixtures/auth'
import { AVANCE_METAS_HOY, FECHA_HOY, VISITAS_HOY } from '../fixtures/hoy'
import { Marco, Seccion } from '../ui/Marco'

const noop = (): void => {}

export default function SeccionHoy() {
  return (
    <Seccion
      id="hoy"
      titulo="Hoy"
      descripcion={
        <>
          <code>VistaHoy</code>: la primera pestaña del preventista. Fecha, las dos acciones de
          un toque, los objetivos del mes (el <code>PanelMisMetas</code> del dashboard) y las
          visitas del día (<code>ListaVisitasHoy</code>, la misma del modal &quot;Visitas del
          día&quot;).
        </>
      }
    >
      <Marco etiqueta="Preventista · con visitas y objetivos">
        <VistaHoy
          fecha={FECHA_HOY}
          visitas={VISITAS_HOY}
          cargandoVisitas={false}
          errorVisitas={null}
          avanceMetas={AVANCE_METAS_HOY}
          onNuevoPedido={noop}
          onMarcarVisita={noop}
        />
      </Marco>

      <Marco etiqueta="Preventista · día recién empezado: sin visitas y sin metas cargadas">
        <VistaHoy
          fecha={FECHA_HOY}
          visitas={[]}
          cargandoVisitas={false}
          errorVisitas={null}
          onNuevoPedido={noop}
          onMarcarVisita={noop}
        />
      </Marco>

      <Marco etiqueta="Preventista · visitas cargando">
        <VistaHoy
          fecha={FECHA_HOY}
          visitas={[]}
          cargandoVisitas
          errorVisitas={null}
          avanceMetas={AVANCE_METAS_HOY}
          onNuevoPedido={noop}
          onMarcarVisita={noop}
        />
      </Marco>

      <Marco etiqueta="Preventista · error al traer las visitas">
        <VistaHoy
          fecha={FECHA_HOY}
          visitas={[]}
          cargandoVisitas={false}
          errorVisitas={new Error('No se pudo conectar con el servidor')}
          avanceMetas={AVANCE_METAS_HOY}
          onNuevoPedido={noop}
          onMarcarVisita={noop}
        />
      </Marco>

      <Marco etiqueta="Preventista · 375 px, entre el header de 56 px y la barra inferior" compacto>
        {/*
          `transform` ancla el header y la barra (los dos `fixed`) a este div.
          El contenido lleva el mismo padding que el <main> de src/App.tsx:
          `--header-h` + 1rem arriba y `--bottom-nav-h` + 1.5rem abajo. La
          barra (y su alto en `--bottom-nav-h`) sólo aparece con la VENTANA por
          debajo de lg, como en la app.
        */}
        <div
          className="relative w-[375px] max-w-full h-[44rem] overflow-hidden"
          style={{ transform: 'translateZ(0)' }}
        >
          <AuthDataProvider value={authDataDeRol('preventista')}>
            <TopNavigation perfil={PERFILES_FIXTURE.preventista} onLogout={noop} />
            <div className="absolute inset-0 overflow-y-auto pt-[calc(var(--header-h)+1rem)] pb-[calc(var(--bottom-nav-h)+1.5rem)] px-4">
              <VistaHoy
                fecha={FECHA_HOY}
                visitas={VISITAS_HOY}
                cargandoVisitas={false}
                errorVisitas={null}
                avanceMetas={AVANCE_METAS_HOY}
                onNuevoPedido={noop}
                onMarcarVisita={noop}
              />
            </div>
          </AuthDataProvider>
        </div>
      </Marco>
    </Seccion>
  )
}
