/**
 * ¿Esta pantalla de /pedidos es la "ruta activa" del transportista? (#823)
 *
 * Es UNA condición con tres lectores, y los tres tienen que coincidir:
 *  - VistaPedidos monta el mapa (`RutaActivaTransportista`) en vez de la lista.
 *  - PedidosContainer decide si el multi-rol alterna entre lista y mapa
 *    (`?vista=ruta`) y le pasa a la vista el `modoRuta`.
 *  - TopNavigation no monta la barra inferior del celular en esa pantalla: el
 *    mapa ya ocupa el borde de abajo con la barra de la parada y el FAB.
 *
 * Si divergen, la barra aparece encima de la barra de la parada, o desaparece
 * donde tenía que estar, y ningún otro test lo une. Por eso vive acá, pura y
 * con una prueba de equivalencia contra las tres expresiones anteriores
 * (`rutaActiva.test.ts`).
 *
 * Los flags son los de `AuthDataContext`: `isAdmin`, `isPreventista` e
 * `isEncargado` salen del rol PRIMARIO; `isTransportista` también suma el rol
 * extra (mig 155).
 */

export interface RolesRutaActiva {
  isAdmin: boolean
  isPreventista: boolean
  isEncargado: boolean
  isTransportista: boolean
}

/** Valor de `?vista=` con el que el multi-rol pasa del listado al mapa. */
const VISTA_RUTA = 'ruta'

/**
 * Transportista puro: el mapa es su pantalla única, sin lista ni toolbar.
 *
 * El `!isEncargado` es no-op hoy (un encargado no puede tener el rol extra),
 * pero evita que si algún día lo tuviera perdiera toda la pantalla de Pedidos.
 */
export function esTransportistaPuro(roles: RolesRutaActiva): boolean {
  return roles.isTransportista && !roles.isAdmin && !roles.isPreventista && !roles.isEncargado
}

/**
 * Multi-rol (mig 155): el preventista o el encargado que además reparte tiene
 * las dos pantallas y alterna con "Mi ruta". El admin no alterna: no ve el
 * mapa desde Pedidos.
 */
export function puedeAlternarRuta(roles: RolesRutaActiva): boolean {
  return roles.isTransportista && !roles.isAdmin && (roles.isPreventista || roles.isEncargado)
}

/**
 * La pantalla de Pedidos es el mapa de la ruta activa: siempre para el
 * transportista puro, y para el multi-rol sólo con `?vista=ruta`.
 *
 * @param vista valor del parámetro `vista` de la URL (`null` si no está).
 */
export function muestraRutaActiva(roles: RolesRutaActiva, vista: string | null): boolean {
  return esTransportistaPuro(roles) || (puedeAlternarRuta(roles) && vista === VISTA_RUTA)
}

/**
 * Arma los flags desde la lista de roles efectivos, para quien no los recibe ya
 * calculados (TopNavigation). Replica `App.tsx`: los tres flags de pantalla
 * salen del rol primario (el primero de `rolesEfectivos`) y `isTransportista`
 * suma el rol extra, que ya está dentro de `tieneTransportista`.
 */
export function rolesRutaActivaDesdeRolPrimario(
  rolPrimario: string | undefined,
  tieneTransportista: boolean,
): RolesRutaActiva {
  return {
    isAdmin: rolPrimario === 'admin',
    isPreventista: rolPrimario === 'preventista',
    isEncargado: rolPrimario === 'encargado',
    isTransportista: tieneTransportista,
  }
}
