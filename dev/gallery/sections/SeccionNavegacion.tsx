/**
 * Navegación y login.
 *
 * `TopNavigation` es `position: fixed`: cada instancia va dentro de un contenedor
 * con `transform`, que crea un bloque contenedor propio y la ancla al marco en vez
 * de a la ventana. Así se pueden ver los cinco roles a la vez sin que se pisen.
 *
 * Cada instancia lleva su propio `AuthDataProvider` con el valor del rol que
 * muestra: el menú se filtra por `rolesEfectivos`, no por `perfil.rol`.
 *
 * Sus dependencias se resuelven así:
 *  - `useTheme` / `useAuthData`: providers reales, ver GalleryProviders.
 *  - `SucursalSelector` → `useSucursal`: contexto crudo con valor literal (dos
 *    sucursales, para que se vea el dropdown y no el badge estático).
 *  - `DbNotificationBell` → `useNotificacionesQuery`: cache precargada con la key
 *    real `['notificaciones']`.
 *  - `VincularTelegramButton`: sólo una mutation, no consulta nada al renderizar.
 */
import TopNavigation from '../../../src/components/layout/TopNavigation'
import LoginScreen from '../../../src/components/auth/LoginScreen'
import { AuthProvider } from '../../../src/hooks/supabase'
import { AuthDataProvider } from '../../../src/contexts/AuthDataContext'
import type { RolUsuario } from '../../../src/types'
import { authDataDeRol, ETIQUETA_ROL, PERFILES_FIXTURE, ROLES_GALERIA } from '../fixtures/auth'
import { Marco, Seccion, Subtitulo } from '../ui/Marco'

const noop = (): void => {}

function NavegacionDeRol({ rol }: { rol: RolUsuario }) {
  return (
    <Marco
      etiqueta={`TopNavigation · ${ETIQUETA_ROL[rol]} · ${PERFILES_FIXTURE[rol].nombre}`}
      compacto
    >
      {/*
        `transform` hace que los hijos `position: fixed` se anclen a este div.
        Sin esto las cinco barras se apilarían arriba de la ventana, una sobre otra.

        Los breakpoints miran la VENTANA, no el marco. La barra completa aparece
        desde 2xl (#713): con la ventana por debajo de 1536 px estos marcos
        muestran la hamburguesa, y al tocarla el panel desplegable. Con la
        ventana en 1536 px o más muestran la barra, que en el admin no entra en
        un marco de `max-w-7xl`: para verla entera está el marco ancho de abajo.
        Lo mismo con el tope de alto del panel y del menú del usuario, que se
        mide contra `100dvh`: para ver su scroll hay que achicar la ventana en
        alto, no el marco.

        `overflow-x-clip` (y no `overflow-x-hidden`): la barra del admin no
        entra en el marco y desbordaría la página entera con una barra
        horizontal. `clip` corta sin crear un contenedor de scroll, así que los
        dropdowns del menú siguen pudiendo salirse hacia abajo.
      */}
      <div
        className="relative h-16 overflow-x-clip"
        style={{ transform: 'translateZ(0)' }}
      >
        <AuthDataProvider value={authDataDeRol(rol)}>
          <TopNavigation perfil={PERFILES_FIXTURE[rol]} onLogout={noop} />
        </AuthDataProvider>
      </div>
    </Marco>
  )
}

function BarraCompletaAdmin() {
  return (
    <Marco
      etiqueta={`TopNavigation · ${ETIQUETA_ROL.admin} · marco de 1536 px (barra completa con la ventana en 1536 px o más)`}
      compacto
    >
      {/*
        Mismo truco del `transform` que arriba, en un div de 1536 px: el ancho
        desde el que la app muestra la barra completa. Igual la barra sólo
        aparece si la VENTANA mide 1536 px o más; con una más chica este marco
        también muestra la hamburguesa.

        `overflow-x-auto`: el marco es más angosto que 1536 px y se scrollea en
        horizontal. Un contenedor de scroll recorta en los dos ejes, así que la
        altura le deja lugar a los desplegables y al menú del usuario (el del
        admin, con la sección "Administración", baja unos 480 px).
      */}
      <div className="overflow-x-auto">
        <div className="relative w-[1536px] h-[32rem]" style={{ transform: 'translateZ(0)' }}>
          <AuthDataProvider value={authDataDeRol('admin')}>
            <TopNavigation perfil={PERFILES_FIXTURE.admin} onLogout={noop} />
          </AuthDataProvider>
        </div>
      </div>
    </Marco>
  )
}

export default function SeccionNavegacion() {
  return (
    <Seccion
      id="navegacion"
      titulo="Navegación y login"
      descripcion="La barra superior con el menú filtrado por rol, y la pantalla de ingreso."
    >
      <div>
        <Subtitulo>TopNavigation por rol</Subtitulo>
        <div className="mt-3 space-y-4">
          {ROLES_GALERIA.map((rol) => (
            <NavegacionDeRol key={rol} rol={rol} />
          ))}
        </div>
      </div>

      <div>
        <Subtitulo>Barra completa del admin (desde 1536 px)</Subtitulo>
        <div className="mt-3">
          <BarraCompletaAdmin />
        </div>
      </div>

      <div>
        <Subtitulo>LoginScreen</Subtitulo>
        <Marco etiqueta="LoginScreen · dentro del AuthProvider real (sin sesión guardada no consulta nada)">
          {/*
            `LoginScreen` llama `useAuth()`, y `AuthContext` no se exporta
            (src/hooks/supabase/useAuth.tsx:82), así que no hay forma de darle un
            valor literal: hay que montar el `AuthProvider` de verdad. Sin sesión
            en localStorage, `supabase.auth.getSession()` resuelve contra el
            storage y no sale a la red.

            El `min-h-screen` del componente se acota acá para que no mida una
            pantalla entera dentro de la galería.
          */}
          <div className="h-[520px] overflow-hidden rounded-lg [&>div]:!min-h-full">
            <AuthProvider>
              <LoginScreen />
            </AuthProvider>
          </div>
        </Marco>
      </div>
    </Seccion>
  )
}
