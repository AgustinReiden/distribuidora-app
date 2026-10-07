/**
 * Los hooks de clientes / usuarios / zonas / visitas / bot / preventistas tienen
 * que lanzar un `Error` de verdad (issue #760).
 *
 * EL BUG: supabase-js NO lanza `Error`: devuelve un objeto plano
 * `{ message, details, hint, code }` (`code: 'P0001'` si respondió el servidor;
 * `code: ''` y `'TypeError: Failed to fetch'` si no hubo red). Los hooks hacían
 * `if (error) throw error` y la UI, con `err instanceof Error ? err.message :
 * '<literal>'`, descartaba el mensaje real: se veía el literal de fallback tanto
 * para "se requiere rol admin" como para un blip de 4G.
 *
 * Por eso los errores acá son SIEMPRE los objetos planos reales, nunca
 * `new Error(...)`: mockearlos como Error hacía pasar en verde el bug.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { isTransientNetworkError } from '../../utils/retryWithBackoff'

type ErrorPlano = { message: string; details: string; hint: string; code: string }

const ERROR_SERVIDOR: ErrorPlano = {
  message: 'se requiere rol admin',
  details: 'detalle del servidor',
  hint: 'pista del servidor',
  code: 'P0001',
}
const ERROR_RED: ErrorPlano = {
  message: 'TypeError: Failed to fetch',
  details: '',
  hint: '',
  code: '',
}

let resultado: { data: unknown; error: ErrorPlano | null } = { data: null, error: null }

/** Builder de PostgREST: cualquier cadena de métodos termina en `resultado`. */
function builder(): unknown {
  const proxy: unknown = new Proxy(function () {}, {
    get(_t, prop) {
      if (prop === 'then') {
        return (resolve: (v: unknown) => void) => resolve(resultado)
      }
      return () => proxy
    },
    apply() {
      return proxy
    },
  })
  return proxy
}

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => builder(),
    rpc: () => builder(),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ perfil: { id: 'p1' }, isOnline: true }),
}))

import { useClienteQuery, useClientesByZonaQuery, useActualizarClienteMutation, useEliminarClienteMutation } from './useClientesQuery'
import { useDeudoresMoraQuery } from './useDeudoresMoraQuery'
import {
  useZonasEstandarizadasQuery,
  usePreventistaZonasQuery,
  useCrearZonaMutation,
  useAsignarZonasPrevMutation,
  useRenombrarZonaMutation,
  useEliminarZonaMutation,
  useToggleZonaActivaMutation,
} from './useZonasQuery'
import {
  useUsuariosQuery,
  useUsuarioQuery,
  useUsuariosByRolQuery,
  useTransportistasQuery,
  usePerfilRolesQuery,
  useAsignarPerfilRolesMutation,
  usePreventistasQuery,
  usePreventistasAsignablesQuery,
  useVendedoresComisionablesQuery,
  useActualizarUsuarioMutation,
  useToggleUsuarioActivoMutation,
} from './useUsuariosQuery'
import { useVisitasHoyQuery, useRegistrarVisitaMutation } from './useVisitasQuery'
import { useGeolocalizacionPreventistasQuery } from './useGeolocalizacionPreventistasQuery'
import { useJornadasPreventistaQuery, useJornadaDetalleQuery } from './useJornadasPreventistaQuery'
import {
  useAvanceMetasQuery,
  useMetasPreventistaQuery,
  useRendimientoPreventistasQuery,
  useGuardarMetaPreventistaMutation,
  useDesactivarMetaPreventistaMutation,
} from './useMetasPreventistaQuery'
import { useRevisionHorariosQuery, useGuardarHorariosMasivoMutation } from './useRevisionHorariosQuery'
import {
  useCalcularComisionesQuery,
  useComisionReglasQuery,
  useGuardarComisionReglaMutation,
  useDesactivarComisionReglaMutation,
} from './useComisionesQuery'
import {
  useBotVinculadosQuery,
  useBotAuditLogQuery,
  useBotAuditSummaryQuery,
  useBotDigestsEnviadosQuery,
  useToggleBotUsuarioMutation,
} from './useBotAdmin'
import { useBotDigestConfigQuery, useGuardarBotDigestConfigMutation } from './useBotDigestConfig'
import { useGenerarCodigoVinculacionBot } from './useBotVinculacion'
import {
  useNotificacionesQuery,
  useMarcarNotificacionLeidaMutation,
  useMarcarTodasNotificacionesLeidasMutation,
} from './useNotificacionesQuery'

function makeWrapper() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

type Caso =
  | { nombre: string; tipo: 'query'; hook: () => { error: unknown } }
  | {
      nombre: string
      tipo: 'mutation'
      hook: () => { mutateAsync: (v: never) => Promise<unknown> }
      input?: unknown
    }

/** Dispara el hook y devuelve el error con el que terminó. */
async function errorDe(caso: Caso): Promise<unknown> {
  const { result } = renderHook(() => caso.hook(), { wrapper: makeWrapper() })
  if (caso.tipo === 'query') {
    await waitFor(() => expect((result.current as { error: unknown }).error).not.toBeNull())
    return (result.current as { error: unknown }).error
  }
  let capturado: unknown = null
  await act(async () => {
    try {
      await (result.current as { mutateAsync: (v: never) => Promise<unknown> }).mutateAsync(
        caso.input as never,
      )
    } catch (e) {
      capturado = e
    }
  })
  return capturado
}

const q = (nombre: string, hook: () => { error: unknown }): Caso => ({ nombre, tipo: 'query', hook })
const m = (
  nombre: string,
  hook: () => { mutateAsync: (v: never) => Promise<unknown> },
  input?: unknown,
): Caso => ({ nombre, tipo: 'mutation', hook, input })

const CASOS: Caso[] = [
  // useClientesQuery
  q('useClienteQuery', () => useClienteQuery('1')),
  q('useClientesByZonaQuery', () => useClientesByZonaQuery('Norte')),
  m('useActualizarClienteMutation', () => useActualizarClienteMutation(), { id: '1', data: { notas: 'x' } }),
  m('useEliminarClienteMutation', () => useEliminarClienteMutation(), '1'),
  // useDeudoresMoraQuery
  q('useDeudoresMoraQuery', () => useDeudoresMoraQuery(1)),
  // useZonasQuery
  q('useZonasEstandarizadasQuery', () => useZonasEstandarizadasQuery()),
  q('usePreventistaZonasQuery', () => usePreventistaZonasQuery('p1')),
  m('useCrearZonaMutation', () => useCrearZonaMutation(), 'Norte'),
  m('useAsignarZonasPrevMutation', () => useAsignarZonasPrevMutation(), { perfilId: 'p1', zonaIds: ['1'] }),
  m('useRenombrarZonaMutation', () => useRenombrarZonaMutation(), { id: '1', nombre: 'Sur' }),
  m('useEliminarZonaMutation', () => useEliminarZonaMutation(), '1'),
  m('useToggleZonaActivaMutation', () => useToggleZonaActivaMutation(), { id: '1', activo: false }),
  // useUsuariosQuery
  q('useUsuariosQuery', () => useUsuariosQuery()),
  q('useUsuarioQuery', () => useUsuarioQuery('u1')),
  q('useUsuariosByRolQuery', () => useUsuariosByRolQuery('admin')),
  q('useTransportistasQuery', () => useTransportistasQuery()),
  q('usePerfilRolesQuery', () => usePerfilRolesQuery('u1')),
  m('useAsignarPerfilRolesMutation', () => useAsignarPerfilRolesMutation(), { usuarioId: 'u1', roles: ['admin'] }),
  q('usePreventistasQuery', () => usePreventistasQuery()),
  q('usePreventistasAsignablesQuery', () => usePreventistasAsignablesQuery()),
  q('useVendedoresComisionablesQuery', () => useVendedoresComisionablesQuery()),
  m('useActualizarUsuarioMutation', () => useActualizarUsuarioMutation(), { id: 'u1', data: { nombre: 'x' } }),
  m('useToggleUsuarioActivoMutation', () => useToggleUsuarioActivoMutation(), { id: 'u1', activo: false }),
  // useVisitasQuery
  q('useVisitasHoyQuery', () => useVisitasHoyQuery('u1')),
  m('useRegistrarVisitaMutation', () => useRegistrarVisitaMutation(), { clienteId: 1, status: 'denied' }),
  // geolocalizacion / jornadas / metas
  q('useGeolocalizacionPreventistasQuery', () => useGeolocalizacionPreventistasQuery('2026-10-01', '2026-10-07')),
  q('useJornadasPreventistaQuery', () => useJornadasPreventistaQuery('2026-10-01', '2026-10-07')),
  q('useJornadaDetalleQuery', () => useJornadaDetalleQuery('2026-10-01')),
  q('useAvanceMetasQuery', () => useAvanceMetasQuery('p1')),
  q('useMetasPreventistaQuery', () => useMetasPreventistaQuery()),
  q('useRendimientoPreventistasQuery', () => useRendimientoPreventistasQuery()),
  m('useGuardarMetaPreventistaMutation', () => useGuardarMetaPreventistaMutation(), {
    sucursalId: 2,
    preventistaId: 'p1',
    periodo: '2026-10-01',
    tipoMeta: 'ventas',
    valorObjetivo: 100,
  }),
  m('useDesactivarMetaPreventistaMutation', () => useDesactivarMetaPreventistaMutation(), 1),
  // revision de horarios
  q('useRevisionHorariosQuery', () => useRevisionHorariosQuery()),
  m('useGuardarHorariosMasivoMutation', () => useGuardarHorariosMasivoMutation(), []),
  // comisiones
  q('useCalcularComisionesQuery', () => useCalcularComisionesQuery('2026-10-01', '2026-10-07')),
  q('useComisionReglasQuery', () => useComisionReglasQuery()),
  m('useGuardarComisionReglaMutation', () => useGuardarComisionReglaMutation(), { porcentaje: 1 }),
  m('useDesactivarComisionReglaMutation', () => useDesactivarComisionReglaMutation(), 1),
  // bot
  q('useBotVinculadosQuery', () => useBotVinculadosQuery()),
  q('useBotAuditLogQuery', () => useBotAuditLogQuery({ desde: '2026-10-01', hasta: '2026-10-07' })),
  q('useBotAuditSummaryQuery', () => useBotAuditSummaryQuery('2026-10-01', '2026-10-07')),
  q('useBotDigestsEnviadosQuery', () => useBotDigestsEnviadosQuery('2026-10-01', '2026-10-07')),
  m('useToggleBotUsuarioMutation', () => useToggleBotUsuarioMutation(), { telegram_user_id: 1, activo: true }),
  q('useBotDigestConfigQuery', () => useBotDigestConfigQuery()),
  m('useGuardarBotDigestConfigMutation', () => useGuardarBotDigestConfigMutation(), {
    perfil_id: 'p1',
    activo: true,
    hora_local: 8,
    dias_semana: [1],
    secciones: [],
  }),
  m('useGenerarCodigoVinculacionBot', () => useGenerarCodigoVinculacionBot(), undefined),
  // notificaciones
  q('useNotificacionesQuery', () => useNotificacionesQuery()),
  m('useMarcarNotificacionLeidaMutation', () => useMarcarNotificacionLeidaMutation(), 1),
  m('useMarcarTodasNotificacionesLeidasMutation', () => useMarcarTodasNotificacionesLeidasMutation(), undefined),
]

describe('errores de supabase en los hooks de clientes y afines (#760)', () => {
  beforeEach(() => {
    resultado = { data: null, error: null }
  })

  describe.each(CASOS.map((c) => [c.nombre, c] as const))('%s', (_nombre, caso) => {
    it('con error del servidor lanza un Error con el mensaje y el code del servidor', async () => {
      resultado = { data: null, error: ERROR_SERVIDOR }
      const e = await errorDe(caso)
      expect(e).toBeInstanceOf(Error)
      expect((e as Error).message).toBe('se requiere rol admin')
      expect((e as { code?: string }).code).toBe('P0001')
      expect((e as { details?: string }).details).toBe('detalle del servidor')
      expect((e as { hint?: string }).hint).toBe('pista del servidor')
    })

    it('sin red lanza un Error con el mensaje de sin conexión y sigue siendo transitorio', async () => {
      resultado = { data: null, error: ERROR_RED }
      const e = await errorDe(caso)
      expect(e).toBeInstanceOf(Error)
      expect((e as Error).message).toMatch(/^Sin conexión: no se pudo (cargar|confirmar)/)
      expect((e as Error).message).not.toMatch(/failed to fetch/i)
      expect(isTransientNetworkError(e)).toBe(true)
    })
  })

  it('las escrituras no idempotentes dicen "no se pudo confirmar" y mandan a revisar antes de reintentar', async () => {
    resultado = { data: null, error: ERROR_RED }
    const e = await errorDe(
      m('registrar visita', () => useRegistrarVisitaMutation(), { clienteId: 1, status: 'denied' }),
    )
    expect((e as Error).message).toMatch(/no se pudo confirmar/)
    expect((e as Error).message).toMatch(/antes de reintentar/)
  })

  it('el 23503 al borrar un cliente sigue traduciéndose (el chequeo por code es sobre el objeto crudo)', async () => {
    resultado = {
      data: [],
      error: { message: 'violates foreign key', details: '', hint: '', code: '23503' },
    }
    const e = await errorDe(m('eliminar cliente', () => useEliminarClienteMutation(), '1'))
    expect(e).toBeInstanceOf(Error)
    expect((e as Error).message).toMatch(/^No se puede eliminar: el cliente tiene/)
  })

  it('el 23505 al crear una zona sigue traduciéndose', async () => {
    resultado = {
      data: null,
      error: { message: 'duplicate key', details: '', hint: '', code: '23505' },
    }
    const e = await errorDe(m('crear zona', () => useCrearZonaMutation(), 'Norte'))
    expect((e as Error).message).toBe('La zona "Norte" ya existe')
  })
})
