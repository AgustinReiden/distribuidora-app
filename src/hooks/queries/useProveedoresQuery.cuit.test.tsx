/**
 * 1557-b10 (decisión del dueño, #1557): el CUIT de un proveedor es único por
 * sucursal, comparado sin guiones. El chequeo del alta sólo comparaba limpio si
 * lo tipeado traía guiones: «30712345678» contra uno guardado como
 * «30-71234567-8» no coincidía, y la búsqueda alternativa miraba sólo 100 filas.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

type Fila = { id: number; nombre: string; cuit: string | null; sucursal_id: number }

let proveedores: Fila[] = []
const insertados: unknown[] = []
/** Si está, `insert`/`update` contestan con este error (el rechazo del índice único del server). */
let errorDeEscritura: { code: string; message: string; details?: string } | null = null

/** Un PostgREST de juguete: sólo lo que usa el alta (eq, ilike, not, limit, maybeSingle, insert). */
function builder() {
  let filas = [...proveedores]
  let insertando: unknown[] | null = null
  const b: Record<string, unknown> = {}
  b.select = () => b
  b.eq = (col: string, valor: unknown) => { filas = filas.filter(f => (f as Record<string, unknown>)[col] === valor); return b }
  b.ilike = (col: string, patron: string) => {
    const re = new RegExp('^' + patron.split('%').map(t => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$', 'i')
    filas = filas.filter(f => re.test(String((f as Record<string, unknown>)[col] ?? '')))
    return b
  }
  b.not = (col: string, _op: string, valor: unknown) => { filas = filas.filter(f => (f as Record<string, unknown>)[col] !== valor); return b }
  b.limit = (n: number) => { filas = filas.slice(0, n); return b }
  b.maybeSingle = () => Promise.resolve({ data: filas[0] ?? null, error: null })
  b.insert = (rows: unknown[]) => { insertando = rows; insertados.push(...rows); return b }
  b.update = () => { insertando = []; return b }
  b.single = () => errorDeEscritura
    ? Promise.resolve({ data: null, error: errorDeEscritura })
    : Promise.resolve({ data: insertando ? { id: 99, ...(insertando[0] as object) } : filas[0] ?? null, error: null })
  b.then = (resolve: (v: unknown) => unknown) => Promise.resolve({ data: filas, error: null }).then(resolve)
  return b
}

vi.mock('../supabase/base', () => ({
  supabase: { from: () => builder(), rpc: vi.fn() },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearProveedorMutation, useActualizarProveedorMutation } from './useProveedoresQuery'

function crear(cuit: string) {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  const { result } = renderHook(() => useCrearProveedorMutation(), { wrapper })
  return result.current.mutateAsync({ nombre: 'Distribuidora Nueva', cuit } as never)
}

describe('alta de proveedor: el CUIT duplicado se compara siempre limpio', () => {
  beforeEach(() => {
    insertados.length = 0
    errorDeEscritura = null
    proveedores = [
      { id: 1, nombre: 'Con guiones SA', cuit: '30-71234567-8', sucursal_id: 1 },
      { id: 2, nombre: 'Sin guiones SRL', cuit: '27123456780', sucursal_id: 1 },
      { id: 3, nombre: 'De otra sucursal', cuit: '20-11111111-2', sucursal_id: 2 },
    ]
  })

  it('tipeado sin guiones contra uno guardado con guiones', async () => {
    await expect(crear('30712345678')).rejects.toThrow(/Ya existe un proveedor con CUIT.*Con guiones SA/)
    expect(insertados).toHaveLength(0)
  })

  it('tipeado con guiones contra uno guardado sin guiones', async () => {
    await expect(crear('27-12345678-0')).rejects.toThrow(/Sin guiones SRL/)
    expect(insertados).toHaveLength(0)
  })

  it('con puntos o espacios en lugar de guiones', async () => {
    await expect(crear('30 71234567 8')).rejects.toThrow(/Con guiones SA/)
    await expect(crear('30.71234567.8')).rejects.toThrow(/Con guiones SA/)
  })

  it('el mismo CUIT en otra sucursal no es duplicado: es único por sucursal', async () => {
    await crear('20111111112')
    await crear('20-11111111-2')
    expect(insertados).toHaveLength(2)
  })

  it('un CUIT que nadie tiene se da de alta', async () => {
    await crear('30-99999999-1')
    expect(insertados).toHaveLength(1)
  })
})

describe('el índice único del server se traduce al mismo aviso (23505)', () => {
  const INDICE = {
    code: '23505',
    message: 'duplicate key value violates unique constraint "proveedores_cuit_unico_por_sucursal"',
    details: 'Key (sucursal_id, cuit_limpio)=(1, 30712345678) already exists.',
  }

  function editar(cuit: string) {
    const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    )
    const { result } = renderHook(() => useActualizarProveedorMutation(), { wrapper })
    return result.current.mutateAsync({ id: '2', data: { nombre: 'Sin guiones SRL', cuit } as never })
  }

  beforeEach(() => {
    insertados.length = 0
    proveedores = []
    errorDeEscritura = INDICE
  })

  it('al editar un proveedor y ponerle el CUIT de otro', async () => {
    const error = await editar('30-71234567-8').catch(e => e)
    expect(error).toBeInstanceOf(Error)
    expect(error.message).toMatch(/Ya existe un proveedor con CUIT "30-71234567-8"/)
    expect(error.message).not.toMatch(/23505|duplicate key|proveedores_cuit_unico/)
    // 409: el reintento global de las mutations no lo repite.
    expect(error.status).toBe(409)
  })

  it('al dar de alta, si una carrera se saltea la verificación previa', async () => {
    const error = await crear('30712345678').catch(e => e)
    expect(error.message).toMatch(/Ya existe un proveedor con CUIT "30712345678"/)
    expect(error.message).not.toMatch(/23505|duplicate key/)
  })

  it('un 23505 de otro índice no se disfraza de CUIT repetido', async () => {
    errorDeEscritura = { code: '23505', message: 'duplicate key value violates unique constraint "proveedores_nombre_key"' }
    const error = await editar('30-71234567-8').catch(e => e)
    expect(error.message).not.toMatch(/CUIT/)
  })
})
