/**
 * Tests del detector de duplicados por ubicación cuando la RLS le tapa la fila
 * (issue #543, mig 217).
 *
 * EL BUG
 * ------
 * El detector consultaba `clientes` COMO EL USUARIO, o sea bajo la RLS. Un
 * preventista no ve los clientes de OTRO preventista, así que la consulta
 * volvía vacía, el detector no avisaba nada y se creaba un CLON. Es la forma de
 * fail-open que la mig 214 ya había documentado: un guard que consulta bajo la
 * policy que le tapa la fila no falla — aprueba.
 *
 * Verificado contra prod impersonando (que es lo único que lo prueba de
 * verdad): el cliente 22 existe en esas coordenadas y la consulta del detector
 * con el JWT de Osvaldo devolvía 0 filas.
 *
 * QUÉ NO PUEDEN PROBAR ESTOS TESTS
 * --------------------------------
 * Que la RPC vea por encima de la RLS: eso vive en la base y no lo ven `tsc`,
 * ni eslint, ni vitest. Está verificado en el cuerpo de la migración.
 *
 * QUÉ SÍ FIJAN — lo que la app puede romper sola y en silencio:
 *
 * 1. Que se consulte a la RPC cuando la consulta con RLS no encontró nada. Si
 *    alguien la saca, vuelve el bug entero y ningún test de tipos se entera.
 * 2. Que el mensaje NO revele la identidad del cliente que no le corresponde
 *    ver. Filtrar el nombre por el mensaje de error sería filtrar por la
 *    ventana lo que la policy tapa por la puerta.
 * 3. Que ante un error de la RPC NO se cree el cliente (fail-closed). Seguir de
 *    largo es volver al guard que no puede mirar y aprueba igual.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const insertSpy = vi.fn()
const rpc = vi.fn()
const from = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (...args: unknown[]) => from(...args),
    rpc: (...args: unknown[]) => rpc(...args),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearClienteMutation } from './useClientesQuery'

/** El cliente que existe en esas coordenadas y que el preventista NO puede ver. */
const CLIENTE_AJENO = { id: '22', nombre_fantasia: 'LOS PORTEÑOS', razon_social: 'Los Porteños' }

const CLIENTE_NUEVO = {
  razon_social: 'Kiosco Nuevo',
  nombre_fantasia: 'Kiosco Nuevo',
  direccion: 'San Martín 100',
  latitud: -26.8355312,
  longitud: -65.2223494,
}

/**
 * `cercanosVisibles` es lo que la consulta CON RLS le muestra al usuario: vacío
 * cuando el cliente existe pero es de otro preventista, que es el caso de #543.
 */
function montarSupabase(cercanosVisibles: unknown[]): void {
  from.mockImplementation((tabla: string) => {
    const builder: Record<string, unknown> = {}
    if (tabla === 'clientes') {
      builder.insert = (filas: unknown) => { insertSpy(filas); return builder }
      builder.select = () => builder
      builder.eq = () => builder
      builder.gte = () => builder
      builder.lte = () => builder
      builder.limit = () => Promise.resolve({ data: cercanosVisibles, error: null })
      builder.single = () => Promise.resolve({ data: { id: '99' }, error: null })
      return builder
    }
    builder.delete = () => builder
    builder.eq = () => Promise.resolve({ error: null })
    builder.insert = () => Promise.resolve({ error: null })
    return builder
  })
}

function wrapper({ children }: { children: React.ReactNode }): React.ReactElement {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

const crear = async (datos = CLIENTE_NUEVO) => {
  const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })
  return result.current.mutateAsync(datos)
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('duplicado que la RLS le tapa al preventista', () => {
  describe('lo detecta aunque no lo vea', () => {
    beforeEach(() => {
      // La consulta con RLS no devuelve nada (el cliente es de otro), pero la
      // base sí sabe que está.
      montarSupabase([])
      rpc.mockResolvedValue({ data: true, error: null })
    })

    it('le pregunta a la RPC cuando la consulta con RLS vino vacía', async () => {
      await expect(crear()).rejects.toThrow()
      expect(rpc).toHaveBeenCalledWith('existe_cliente_en_ubicacion', {
        p_latitud: CLIENTE_NUEVO.latitud,
        p_longitud: CLIENTE_NUEVO.longitud,
      })
    })

    it('no crea el cliente', async () => {
      await expect(crear()).rejects.toThrow()
      expect(insertSpy).not.toHaveBeenCalled()
    })

    it('avisa que ya hay uno en esa ubicación', async () => {
      await expect(crear()).rejects.toThrow(/[Yy]a existe un cliente en esta ubicación/)
    })

    it('dice que administración ya fue avisada', async () => {
      await expect(crear()).rejects.toThrow(/administración/)
    })
  })

  describe('no revela de quién se trata', () => {
    beforeEach(() => {
      montarSupabase([])
      rpc.mockResolvedValue({ data: true, error: null })
    })

    // El corazón del asunto: el mensaje es lo único que vuelve al preventista.
    // Si lleva el nombre, la RLS deja de servir para nada.
    it('el mensaje no trae el nombre de fantasía del cliente ajeno', async () => {
      await expect(crear()).rejects.toThrow(
        expect.not.stringContaining(CLIENTE_AJENO.nombre_fantasia) as unknown as string,
      )
    })

    it('el mensaje no trae la razón social ni el id', async () => {
      let mensaje: string | null = null
      try { await crear() } catch (e) { mensaje = (e as Error).message }
      // Sin esto el test pasa solo: si el alta NO falla no hay mensaje, y
      // "el mensaje vacío no contiene el nombre" es verdad y no prueba nada.
      expect(mensaje).not.toBeNull()
      expect(mensaje).not.toContain(CLIENTE_AJENO.razon_social)
      expect(mensaje).not.toContain(`#${CLIENTE_AJENO.id}`)
    })

    it('la RPC recibe solo coordenadas: nada del cliente que se está creando', async () => {
      await expect(crear()).rejects.toThrow()
      expect(Object.keys(rpc.mock.calls[0][1] as object).sort()).toEqual(['p_latitud', 'p_longitud'])
    })
  })

  describe('cuando el cliente SÍ es visible, no cambia nada', () => {
    beforeEach(() => {
      montarSupabase([{ ...CLIENTE_AJENO, activo: true }])
      rpc.mockResolvedValue({ data: true, error: null })
    })

    it('sigue diciendo cuál es, porque el usuario ya lo puede ver', async () => {
      await expect(crear()).rejects.toThrow(new RegExp(CLIENTE_AJENO.nombre_fantasia))
    })

    it('no llama a la RPC: ya sabe la respuesta y no hace falta molestar a administración', async () => {
      await expect(crear()).rejects.toThrow()
      expect(rpc).not.toHaveBeenCalled()
    })
  })

  describe('fail-closed: si no puede verificar, no crea', () => {
    beforeEach(() => {
      montarSupabase([])
      rpc.mockResolvedValue({ data: null, error: { message: 'boom' } })
    })

    it('no crea el cliente cuando la RPC falla', async () => {
      await expect(crear()).rejects.toThrow()
      expect(insertSpy).not.toHaveBeenCalled()
    })

    it('lo dice, en vez de crear a ciegas', async () => {
      await expect(crear()).rejects.toThrow(/No se pudo verificar/)
    })
  })

  describe('sin duplicado, el alta sigue de largo', () => {
    beforeEach(() => {
      montarSupabase([])
      rpc.mockResolvedValue({ data: false, error: null })
    })

    it('crea el cliente', async () => {
      await crear()
      expect(insertSpy).toHaveBeenCalled()
    })
  })

  describe('sin coordenadas no hay nada que consultar', () => {
    beforeEach(() => {
      montarSupabase([])
      rpc.mockResolvedValue({ data: false, error: null })
    })

    it('no llama a la RPC si el cliente no trae lat/long', async () => {
      await crear({ ...CLIENTE_NUEVO, latitud: undefined, longitud: undefined } as never)
      expect(rpc).not.toHaveBeenCalled()
      expect(insertSpy).toHaveBeenCalled()
    })
  })
})
