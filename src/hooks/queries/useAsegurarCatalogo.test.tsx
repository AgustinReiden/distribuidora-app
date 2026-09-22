/**
 * "+ Nueva categoría" y "+ Nueva marca": crean la fila de verdad, y reusan la
 * que ya existe en vez de crear una gemela.
 *
 * EL HUECO
 * --------
 * El "+ Nueva categoría" de la ficha escribía el nombre sólo en
 * `productos.categoria`. Nadie creaba la fila en `categorias`, así que el
 * trigger de la mig 146 dejaba `categoria_id` en NULL: el producto se veía con
 * su categoría en la lista y para las comisiones, las metas y las asignaciones
 * masivas no tenía ninguna. En prod había 25 productos así al 22/09/2026, en
 * ocho nombres (FRAU, MANITO, NACHOS...). La marca ni siquiera tenía el botón.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const crearCategoria = vi.fn()
const crearMarca = vi.fn()

const CATEGORIAS = [
  { id: 'c-1', nombre: 'AZÚCAR', activa: true },
  { id: 'c-2', nombre: 'VIEJA', activa: false },
]
const MARCAS = [
  { id: 'm-1', nombre: 'MANAOS', activa: true },
  { id: 'm-2', nombre: 'DESCONTINUADA', activa: false },
]

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

vi.mock('./useCategoriasQuery', () => ({
  categoriasKeys: { lists: (s: number | null) => ['categorias', s, 'list'] },
  useCategoriasQuery: () => ({ data: CATEGORIAS }),
  useCrearCategoriaMutation: () => ({ mutateAsync: crearCategoria, isPending: false }),
}))

vi.mock('./useMarcasQuery', () => ({
  marcasKeys: { lists: (s: number | null) => ['marcas', s, 'list'] },
  useMarcasQuery: () => ({ data: MARCAS }),
  useCrearMarcaMutation: () => ({ mutateAsync: crearMarca, isPending: false }),
}))

import { useAsegurarCatalogo } from './useAsegurarCatalogo'

function montar() {
  const queryClient = new QueryClient()
  const invalidar = vi.spyOn(queryClient, 'invalidateQueries')
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  )
  const { result } = renderHook(() => useAsegurarCatalogo(), { wrapper })
  return { asegurar: result.current.asegurar, invalidar }
}

describe('useAsegurarCatalogo', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('sin nada tipeado no toca nada', async () => {
    const { asegurar } = montar()

    expect(await asegurar({ categoria_nueva: '   ', marca_nueva: undefined })).toEqual({})
    expect(crearCategoria).not.toHaveBeenCalled()
    expect(crearMarca).not.toHaveBeenCalled()
  })

  it('una categoría que ya existe se reusa aunque se escriba distinto', async () => {
    const { asegurar } = montar()

    // Devuelve el nombre de la fila y no lo tipeado: el trigger compara el
    // texto, y con el de la fila encuentra el id.
    expect(await asegurar({ categoria_nueva: 'azucar' })).toEqual({ categoria: 'AZÚCAR' })
    expect(crearCategoria).not.toHaveBeenCalled()
  })

  it('la categoría que falta se crea, en mayúsculas como el resto', async () => {
    crearCategoria.mockResolvedValue({ id: 'c-9', nombre: 'LIMPIEZA', activa: true })
    const { asegurar } = montar()

    expect(await asegurar({ categoria_nueva: '  limpieza ' })).toEqual({ categoria: 'LIMPIEZA' })
    expect(crearCategoria).toHaveBeenCalledWith('LIMPIEZA')
  })

  it('una marca que ya existe devuelve su id, sin crear otra', async () => {
    const { asegurar } = montar()

    expect(await asegurar({ marca_nueva: 'Manaos' })).toEqual({ marca_id: 'm-1' })
    expect(crearMarca).not.toHaveBeenCalled()
  })

  it('la marca que falta se crea y devuelve el id nuevo', async () => {
    crearMarca.mockResolvedValue({ id: 'm-9', nombre: 'FRAU', activa: true })
    const { asegurar } = montar()

    expect(await asegurar({ categoria_nueva: 'azucar', marca_nueva: 'frau' }))
      .toEqual({ categoria: 'AZÚCAR', marca_id: 'm-9' })
    expect(crearMarca).toHaveBeenCalledWith('FRAU')
  })

  it('una desactivada no se reactiva sola: frena con un mensaje que dice dónde', async () => {
    const { asegurar } = montar()

    await expect(asegurar({ categoria_nueva: 'vieja' }))
      .rejects.toThrow('La categoría "VIEJA" ya existe pero está desactivada. Reactivala desde Productos → Categorías, o elegí otra.')
    await expect(asegurar({ marca_nueva: 'descontinuada' }))
      .rejects.toThrow('La marca "DESCONTINUADA" ya existe pero está desactivada. Reactivala desde Productos → Marcas, o elegí otra.')
    expect(crearCategoria).not.toHaveBeenCalled()
    expect(crearMarca).not.toHaveBeenCalled()
  })

  it('si el alta choca, refresca la lista para que el reintento la encuentre', async () => {
    // Otra sesión la creó después de que se cargó la lista: el insert choca
    // contra el UNIQUE.
    crearMarca.mockRejectedValue(new Error('Ya existe una marca llamada "FRAU"'))
    const { asegurar, invalidar } = montar()

    await expect(asegurar({ marca_nueva: 'frau' })).rejects.toThrow('Ya existe una marca llamada "FRAU"')
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['marcas', 1, 'list'] })
  })
})
