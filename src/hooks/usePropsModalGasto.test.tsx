import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'

const estado = {
  isAdmin: false,
  sucursales: [{ id: 1, nombre: 'Tucumán' }] as Array<{ id: number; nombre: string }>,
  activas: [{ id: 1, nombre: 'Tucumán' }, { id: 2, nombre: 'Taco Pozo' }] as Array<{ id: number; nombre: string }>,
  rubros: [] as Array<{ id: number; nombre: string; activo: boolean }>,
}
const mutateAsync = vi.fn()

vi.mock('./queries', () => ({
  useRubrosGastoQuery: () => ({ data: estado.rubros }),
  useVehiculosQuery: () => ({ data: [] }),
  useSucursalesActivasQuery: () => ({ data: estado.activas }),
  useGuardarRubroGastoMutation: () => ({ mutateAsync }),
}))
vi.mock('../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: estado.isAdmin, user: { id: 'u-1' } }),
}))
vi.mock('../contexts/SucursalContext', () => ({
  useSucursal: () => ({
    sucursales: estado.sucursales,
    currentSucursalId: 1,
    currentSucursalNombre: 'Tucumán',
  }),
}))

import { usePropsModalGasto } from './usePropsModalGasto'

describe('usePropsModalGasto', () => {
  beforeEach(() => {
    estado.isAdmin = false
    estado.sucursales = [{ id: 1, nombre: 'Tucumán' }]
    estado.rubros = []
    mutateAsync.mockReset()
  })

  it('un encargado no puede crear rubros', () => {
    const { result } = renderHook(() => usePropsModalGasto())
    expect(result.current.onCrearRubro).toBeUndefined()
    expect(result.current.esAdmin).toBe(false)
    expect(result.current.usuarioId).toBe('u-1')
  })

  it('un admin crea rubros con el grupo elegido', async () => {
    estado.isAdmin = true
    mutateAsync.mockResolvedValue({ id: 9 })
    const { result } = renderHook(() => usePropsModalGasto())
    await result.current.onCrearRubro!('Peajes', 'vehiculos')
    expect(mutateAsync).toHaveBeenCalledWith({ nombre: 'Peajes', grupo: 'vehiculos' })
  })

  it('con todas las sucursales activas, tieneTodasLasSucursales es true', () => {
    estado.sucursales = [{ id: 1, nombre: 'Tucumán' }, { id: 2, nombre: 'Taco Pozo' }]
    const { result } = renderHook(() => usePropsModalGasto())
    expect(result.current.tieneTodasLasSucursales).toBe(true)
  })

  it('con una sola de dos, es false', () => {
    const { result } = renderHook(() => usePropsModalGasto())
    expect(result.current.tieneTodasLasSucursales).toBe(false)
    expect(result.current.sucursalActual).toEqual({ id: 1, nombre: 'Tucumán' })
  })

  it('los rubros inactivos no vienen', () => {
    estado.rubros = [
      { id: 1, nombre: 'Combustible', activo: true },
      { id: 2, nombre: 'Viejo', activo: false },
    ]
    const { result } = renderHook(() => usePropsModalGasto())
    expect(result.current.rubros.map(r => r.id)).toEqual([1])
  })
})
