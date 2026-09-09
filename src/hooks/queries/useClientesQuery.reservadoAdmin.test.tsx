/**
 * Tests de "Solo administradores" (`reservado_admin`, mig 214) en la capa de
 * escritura.
 *
 * QUÉ NO PUEDEN PROBAR ESTOS TESTS
 * --------------------------------
 * La restricción de verdad es RLS, y la RLS no la ve `tsc`, ni eslint, ni
 * vitest: el `select` de PostgREST es un string y la policy vive en la base. La
 * visibilidad por rol se verificó contra producción, con un usuario de cada rol
 * (ver el cuerpo de la migración).
 *
 * QUÉ SÍ FIJAN
 * ------------
 * Lo que la app puede romper sola y en silencio:
 *
 * 1. El `insert` de `createCliente` es una **lista explícita** de columnas, no
 *    un spread. Una columna que no esté nombrada ahí se pierde sin error: el
 *    cliente se crea igual, pero sin la marca, y queda visible para todos los
 *    preventistas. Es exactamente lo contrario de lo que pidió el admin.
 *
 * 2. Los tres estados son excluyentes (sin asignar / asignado a X / reservado).
 *    Si el front manda `reservado_admin: true` junto con asignaciones, el
 *    trigger `trg_cliente_preventistas_no_reservado` rechaza el INSERT y el
 *    guardado falla entero.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const insertSpy = vi.fn()
const deleteSpy = vi.fn()
const updateSpy = vi.fn()
const from = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (...args: unknown[]) => from(...args),
    rpc: vi.fn(),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearClienteMutation, useActualizarClienteMutation } from './useClientesQuery'

const CLIENTE_CREADO = { id: '77', nombre_fantasia: 'Reservado SA', reservado_admin: true }

/**
 * `from(tabla)` devuelve un builder encadenable distinto según la tabla: el de
 * `clientes` termina en `.single()`, el de `cliente_preventistas` resuelve en
 * `.eq()` (delete) o en `.insert()`.
 */
function montarSupabase(): void {
  from.mockImplementation((tabla: string) => {
    if (tabla === 'clientes') {
      const builder: Record<string, unknown> = {}
      builder.insert = (filas: unknown) => {
        insertSpy(filas)
        return builder
      }
      builder.update = (payload: unknown) => {
        updateSpy(payload)
        return builder
      }
      builder.select = () => builder
      builder.eq = () => builder
      builder.gte = () => builder
      builder.lte = () => builder
      builder.limit = () => Promise.resolve({ data: [], error: null })
      builder.single = () => Promise.resolve({ data: CLIENTE_CREADO, error: null })
      return builder
    }
    // cliente_preventistas / cliente_descuentos_categoria
    const builder: Record<string, unknown> = {}
    builder.delete = () => builder
    builder.eq = (col: string, val: unknown) => {
      deleteSpy(col, val)
      return Promise.resolve({ error: null })
    }
    builder.insert = (filas: unknown) => {
      insertSpy(filas)
      return Promise.resolve({ error: null })
    }
    return builder
  })
}

function wrapper({ children }: { children: React.ReactNode }): React.ReactElement {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

describe('reservado_admin en la capa de escritura', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    montarSupabase()
  })

  it('createCliente manda reservado_admin en el insert (la lista de columnas es explícita)', async () => {
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })

    await result.current.mutateAsync({
      razon_social: 'Reservado SA',
      nombre_fantasia: 'Reservado SA',
      direccion: 'San Martín 100',
      reservado_admin: true,
      preventista_ids: [],
    })

    await waitFor(() => expect(insertSpy).toHaveBeenCalled())
    const fila = (insertSpy.mock.calls[0][0] as Array<Record<string, unknown>>)[0]
    expect(fila.reservado_admin).toBe(true)
  })

  it('sin la marca, el insert manda false y no null/undefined (la columna es NOT NULL)', async () => {
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })

    await result.current.mutateAsync({
      razon_social: 'Comun SA',
      nombre_fantasia: 'Comun SA',
      direccion: 'Belgrano 200',
    })

    await waitFor(() => expect(insertSpy).toHaveBeenCalled())
    const fila = (insertSpy.mock.calls[0][0] as Array<Record<string, unknown>>)[0]
    expect(fila.reservado_admin).toBe(false)
  })

  it('updateCliente propaga la marca en el patch', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    await result.current.mutateAsync({ id: '77', data: { reservado_admin: true, preventista_ids: [] } })

    await waitFor(() => expect(updateSpy).toHaveBeenCalled())
    expect(updateSpy.mock.calls[0][0]).toMatchObject({ reservado_admin: true })
  })

  it('un cliente reservado se guarda SIN asignaciones: borra las que había y no inserta ninguna', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })

    await result.current.mutateAsync({ id: '77', data: { reservado_admin: true, preventista_ids: [] } })

    await waitFor(() => expect(deleteSpy).toHaveBeenCalledWith('cliente_id', '77'))
    // El único insert posible sería el de cliente_preventistas: no tiene que existir.
    expect(insertSpy).not.toHaveBeenCalled()
  })
})
