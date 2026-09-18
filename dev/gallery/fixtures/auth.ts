/**
 * Identidad de fixture de la galería: perfil, sucursal y el `AuthDataContextValue`
 * LITERAL que consume `AuthDataProvider`.
 *
 * Los booleanos de rol se calculan igual que `src/App.tsx` (líneas ~225-257): el
 * rol efectivo es el de la sucursal activa, los roles extra SUMAN capacidades
 * (mig 155) y `rolesEfectivos` es la unión. Si esa cuenta cambia en App.tsx,
 * cambia acá: la galería miente sobre el gating de rol si se desincroniza.
 */
import type { AuthDataContextValue } from '../../../src/contexts/AuthDataContext'
import type { SucursalContextValue, SucursalInfo } from '../../../src/contexts/SucursalContext'
import type { PerfilDB, RolUsuario } from '../../../src/types'

export const ROLES_GALERIA: RolUsuario[] = [
  'admin',
  'encargado',
  'preventista',
  'transportista',
  'deposito',
]

export const ETIQUETA_ROL: Record<RolUsuario, string> = {
  admin: 'Admin',
  encargado: 'Encargado',
  preventista: 'Preventista',
  transportista: 'Transportista',
  deposito: 'Depósito',
}

export const SUCURSAL_ID_FIXTURE = 1

export const SUCURSALES_FIXTURE: SucursalInfo[] = [
  { id: 1, nombre: 'San Miguel de Tucumán', rol: 'admin', rolesExtra: [] },
  { id: 2, nombre: 'Taco Pozo', rol: 'encargado', rolesExtra: [] },
]

const USUARIO_ID_FIXTURE = '11111111-1111-4111-8111-111111111111'

export const PERFILES_FIXTURE: Record<RolUsuario, PerfilDB> = {
  admin: {
    id: USUARIO_ID_FIXTURE,
    nombre: 'Marcela Ibáñez',
    email: 'marcela@distribuidora.test',
    rol: 'admin',
    activo: true,
  },
  encargado: {
    id: '22222222-2222-4222-8222-222222222222',
    nombre: 'Rubén Correa',
    email: 'ruben@distribuidora.test',
    rol: 'encargado',
    activo: true,
  },
  preventista: {
    id: '33333333-3333-4333-8333-333333333333',
    nombre: 'Nahuel Juárez',
    email: 'nahuel@distribuidora.test',
    rol: 'preventista',
    activo: true,
  },
  transportista: {
    id: '44444444-4444-4444-8444-444444444444',
    nombre: 'Gustavo Paz',
    email: 'gustavo@distribuidora.test',
    rol: 'transportista',
    activo: true,
  },
  deposito: {
    id: '55555555-5555-4555-8555-555555555555',
    nombre: 'Silvia Moreno',
    email: 'silvia@distribuidora.test',
    rol: 'deposito',
    activo: true,
  },
}

/** Capacidades extra por rol (mig 155). Vacías en la galería salvo que se declaren acá. */
const ROLES_EXTRA: Record<RolUsuario, RolUsuario[]> = {
  admin: [],
  encargado: [],
  preventista: [],
  transportista: [],
  deposito: [],
}

export function authDataDeRol(rol: RolUsuario): AuthDataContextValue {
  const perfil = PERFILES_FIXTURE[rol]
  const rolesExtra = ROLES_EXTRA[rol]

  const isAdmin = rol === 'admin'
  const isPreventista = rol === 'preventista'
  // Los roles extra SUMAN: el preventista que acompaña al camión es preventista
  // Y transportista. Ver el comentario de App.tsx.
  const isTransportista = rol === 'transportista' || rolesExtra.includes('transportista')
  const isEncargado = rol === 'encargado'

  return {
    user: { id: perfil.id, email: perfil.email },
    perfil,
    authReady: true,
    isAdmin,
    isPreventista,
    isTransportista,
    isEncargado,
    isAdminOrEncargado: isAdmin || isEncargado,
    rolesEfectivos: [rol, ...rolesExtra],
    isOnline: true,
    logout: async () => {},
    currentSucursalId: SUCURSAL_ID_FIXTURE,
    currentSucursalNombre: SUCURSALES_FIXTURE[0].nombre,
  }
}

/**
 * Valor literal para `SucursalContext`. El `SucursalProvider` real consulta
 * `usuario_sucursales` contra Supabase al montarse, así que la galería usa el
 * contexto crudo (`SucursalContext.Provider`) y se saltea el fetch.
 */
export function sucursalContextDeRol(rol: RolUsuario): SucursalContextValue {
  return {
    userId: PERFILES_FIXTURE[rol].id,
    currentSucursalId: SUCURSAL_ID_FIXTURE,
    currentSucursalNombre: SUCURSALES_FIXTURE[0].nombre,
    currentSucursalRol: rol,
    currentSucursalRolesExtra: ROLES_EXTRA[rol],
    sucursales: SUCURSALES_FIXTURE,
    loading: false,
    hasMultipleSucursales: SUCURSALES_FIXTURE.length > 1,
    switchSucursal: async () => {},
  }
}
