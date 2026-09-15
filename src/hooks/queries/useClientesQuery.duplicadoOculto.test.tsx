/**
 * Tests del guard de duplicados en `createCliente` (issue #543 + #663,
 * migs 217 y 250).
 *
 * EL BUG ORIGINAL (#543)
 * ----------------------
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
 * LO QUE CAMBIÓ CON LA MIG 250 (#663)
 * -----------------------------------
 * Ya no hay consulta bajo RLS ni box en grados: el alta llama a
 * `verificar_duplicado_cliente` y nada más. La RPC decide con tres reglas
 * (dirección con altura, distancia real en metros, nombre por tokens) y
 * devuelve `cliente_visible` en null cuando la RLS le tapa ese cliente al
 * caller.
 *
 * QUÉ NO PUEDEN PROBAR ESTOS TESTS
 * --------------------------------
 * Que la RPC vea por encima de la RLS ni que el criterio esté bien: eso vive en
 * la base y no lo ven `tsc`, ni eslint, ni vitest. El criterio está en
 * `src/utils/duplicadoCliente.test.ts` y en el bloque DO de la mig 250.
 *
 * QUÉ SÍ FIJAN — lo que la app puede romper sola y en silencio:
 *
 * 1. Que el alta consulte SIEMPRE a la RPC. Si alguien la saca, vuelve el bug
 *    entero y ningún test de tipos se entera.
 * 2. Que el mensaje NO revele la identidad de un cliente que no le corresponde
 *    ver. Filtrar el nombre por el mensaje de error sería filtrar por la
 *    ventana lo que la policy tapa por la puerta.
 * 3. Que ante un error de la RPC NO se cree el cliente (fail-closed).
 * 4. Que un AVISO sin confirmar tampoco cree nada, y que confirmado sí.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const insertSpy = vi.fn()
const updateSpy = vi.fn()
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

import { useCrearClienteMutation, useActualizarClienteMutation } from './useClientesQuery'

/** El cliente que existe en esas coordenadas y que el preventista NO puede ver. */
const CLIENTE_AJENO = { id: 22, nombre: 'LOS PORTEÑOS', razon_social: 'Los Porteños' }

const CLIENTE_NUEVO = {
  razon_social: 'Kiosco Nuevo',
  nombre_fantasia: 'Kiosco Nuevo',
  direccion: 'San Martín 100',
  latitud: -26.8355312,
  longitud: -65.2223494,
}

/** El veredicto de la RPC, con los defaults de "no pasa nada". */
function veredicto(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    bloquea: false,
    avisa: false,
    motivo: null,
    distancia_m: null,
    cliente_visible: null,
    ...over,
  }
}

function montarSupabase(): void {
  from.mockImplementation((tabla: string) => {
    const builder: Record<string, unknown> = {}
    if (tabla === 'clientes') {
      builder.insert = (filas: unknown) => { insertSpy(filas); return builder }
      builder.update = (payload: unknown) => { updateSpy(payload); return builder }
      builder.select = () => builder
      builder.eq = () => builder
      builder.limit = () => Promise.resolve({ data: [], error: null })
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

const crear = async (datos: Record<string, unknown> = CLIENTE_NUEVO) => {
  const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })
  return result.current.mutateAsync(datos as never)
}

beforeEach(() => {
  vi.clearAllMocks()
  montarSupabase()
})

describe('el alta siempre pasa por el guard', () => {
  beforeEach(() => {
    rpc.mockResolvedValue({ data: veredicto(), error: null })
  })

  it('llama a verificar_duplicado_cliente con los cinco campos del criterio', async () => {
    await crear()
    expect(rpc).toHaveBeenCalledWith('verificar_duplicado_cliente', {
      p_latitud: CLIENTE_NUEVO.latitud,
      p_longitud: CLIENTE_NUEVO.longitud,
      p_direccion: CLIENTE_NUEVO.direccion,
      p_razon_social: CLIENTE_NUEVO.razon_social,
      p_nombre_fantasia: CLIENTE_NUEVO.nombre_fantasia,
      p_excluir_id: null,
    })
  })

  it('sin veredicto en contra, crea el cliente', async () => {
    await crear()
    expect(insertSpy).toHaveBeenCalled()
  })

  // Antes, sin coordenadas no se consultaba nada. Ahora la dirección y el
  // nombre son reglas por sí mismas: un alta sin GPS igual tiene que pasar.
  it('consulta igual cuando el cliente no trae coordenadas', async () => {
    await crear({ ...CLIENTE_NUEVO, latitud: undefined, longitud: undefined })
    expect(rpc).toHaveBeenCalledWith('verificar_duplicado_cliente', expect.objectContaining({
      p_latitud: null,
      p_longitud: null,
      p_direccion: CLIENTE_NUEVO.direccion,
    }))
    expect(insertSpy).toHaveBeenCalled()
  })
})

describe('duplicado que la RLS le tapa al preventista', () => {
  beforeEach(() => {
    // La RPC lo ve —es SECURITY DEFINER— pero no dice quién es.
    rpc.mockResolvedValue({
      data: veredicto({ bloquea: true, motivo: 'direccion' }),
      error: null,
    })
  })

  it('no crea el cliente', async () => {
    await expect(crear()).rejects.toThrow()
    expect(insertSpy).not.toHaveBeenCalled()
  })

  it('avisa que ya hay uno en esa dirección', async () => {
    await expect(crear()).rejects.toThrow(/misma dirección/i)
  })

  it('dice que administración ya fue avisada', async () => {
    await expect(crear()).rejects.toThrow(/administración/)
  })

  // El corazón del asunto: el mensaje es lo único que vuelve al preventista.
  // Si lleva el nombre, la RLS deja de servir para nada.
  it('el mensaje no trae el nombre, la razón social ni el id del cliente ajeno', async () => {
    let mensaje: string | null = null
    try { await crear() } catch (e) { mensaje = (e as Error).message }
    // Sin esto el test pasa solo: si el alta NO falla no hay mensaje, y
    // "el mensaje vacío no contiene el nombre" es verdad y no prueba nada.
    expect(mensaje).not.toBeNull()
    expect(mensaje).not.toContain(CLIENTE_AJENO.nombre)
    expect(mensaje).not.toContain(CLIENTE_AJENO.razon_social)
    expect(mensaje).not.toContain(`#${CLIENTE_AJENO.id}`)
  })
})

describe('cuando el cliente SÍ es visible, se lo nombra', () => {
  it('el mensaje dice cuál es, porque el usuario ya lo puede ver', async () => {
    rpc.mockResolvedValue({
      data: veredicto({
        bloquea: true,
        motivo: 'direccion',
        cliente_visible: { id: CLIENTE_AJENO.id, nombre: CLIENTE_AJENO.nombre, activo: true },
      }),
      error: null,
    })
    await expect(crear()).rejects.toThrow(new RegExp(CLIENTE_AJENO.nombre))
  })

  it('si está inactivo, ofrece reactivarlo en vez de clonarlo', async () => {
    rpc.mockResolvedValue({
      data: veredicto({
        bloquea: true,
        motivo: 'direccion',
        cliente_visible: { id: CLIENTE_AJENO.id, nombre: CLIENTE_AJENO.nombre, activo: false },
      }),
      error: null,
    })
    await expect(crear()).rejects.toThrow(/Ver inactivos/)
  })
})

describe('aviso: se puede crear, pero sólo confirmando', () => {
  const avisoCerca = veredicto({
    avisa: true,
    motivo: 'distancia',
    distancia_m: 5.2,
    cliente_visible: { id: CLIENTE_AJENO.id, nombre: CLIENTE_AJENO.nombre, activo: true },
  })

  it('sin confirmar no crea nada y lo dice', async () => {
    rpc.mockResolvedValue({ data: avisoCerca, error: null })
    await expect(crear()).rejects.toThrow(/volvé a guardar y confirmá/)
    expect(insertSpy).not.toHaveBeenCalled()
  })

  it('el mensaje dice a cuántos metros está', async () => {
    rpc.mockResolvedValue({ data: avisoCerca, error: null })
    await expect(crear()).rejects.toThrow(/5,2 m/)
  })

  it('confirmado, crea el cliente', async () => {
    rpc.mockResolvedValue({ data: avisoCerca, error: null })
    await crear({ ...CLIENTE_NUEVO, duplicado_confirmado: true })
    expect(insertSpy).toHaveBeenCalled()
  })

  it('un BLOQUEO no se levanta confirmando', async () => {
    rpc.mockResolvedValue({
      data: veredicto({ bloquea: true, motivo: 'nombre_igual' }),
      error: null,
    })
    await expect(crear({ ...CLIENTE_NUEVO, duplicado_confirmado: true })).rejects.toThrow()
    expect(insertSpy).not.toHaveBeenCalled()
  })
})

describe('fail-closed: si no puede verificar, no crea', () => {
  it('no crea el cliente cuando la RPC falla', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'boom' } })
    await expect(crear()).rejects.toThrow()
    expect(insertSpy).not.toHaveBeenCalled()
  })

  it('lo dice, en vez de crear a ciegas', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'boom' } })
    await expect(crear()).rejects.toThrow(/No se pudo verificar/)
  })

  // Una RPC que contesta `null` sin error es tan ciega como una que tira.
  it('tampoco crea si la RPC contesta vacío sin error', async () => {
    rpc.mockResolvedValue({ data: null, error: null })
    await expect(crear()).rejects.toThrow(/No se pudo verificar/)
    expect(insertSpy).not.toHaveBeenCalled()
  })
})

describe('`duplicado_confirmado` no es una columna', () => {
  // `createCliente` nombra las columnas una por una, pero `updateCliente` arma
  // el payload por spread: si la marca no se descarta, viaja como columna y
  // PostgREST rechaza el UPDATE entero. Se rompería TODA edición de cliente.
  it('el insert del alta no lo manda', async () => {
    rpc.mockResolvedValue({ data: veredicto({ avisa: true, motivo: 'distancia', distancia_m: 5 }), error: null })
    await crear({ ...CLIENTE_NUEVO, duplicado_confirmado: true })
    expect(Object.keys(insertSpy.mock.calls[0][0][0])).not.toContain('duplicado_confirmado')
  })

  it('el update de la edición no lo manda', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })
    await result.current.mutateAsync({
      id: '77',
      data: { razon_social: 'Otro nombre', duplicado_confirmado: true },
    })
    expect(updateSpy).toHaveBeenCalled()
    expect(Object.keys(updateSpy.mock.calls[0][0] as object)).not.toContain('duplicado_confirmado')
  })
})
