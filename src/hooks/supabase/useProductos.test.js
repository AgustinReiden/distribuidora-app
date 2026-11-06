/**
 * Tests para useProductos hook
 *
 * Cobertura:
 * - Estado inicial y carga
 * - Refetch
 * - No expone escrituras (#1475)
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'

// Mock de base.js con factory inline
vi.mock('./base', () => {
  const mockNotifyError = vi.fn()
  return {
    supabase: {
      from: vi.fn(),
      rpc: vi.fn()
    },
    notifyError: mockNotifyError
  }
})

import { useProductos } from './useProductos'
import { supabase, notifyError } from './base'

// Datos de prueba
const mockProducto1 = {
  id: 'prod-1',
  nombre: 'Agua Mineral 500ml',
  codigo: 'AM500',
  precio: 150,
  stock: 100,
  stock_minimo: 20,
  categoria: 'Bebidas',
  costo_sin_iva: 80,
  costo_con_iva: 96.8,
  impuestos_internos: 5,
  precio_sin_iva: 124
}

const mockProducto2 = {
  id: 'prod-2',
  nombre: 'Cerveza 1L',
  codigo: 'CERV1L',
  precio: 500,
  stock: 50,
  stock_minimo: 10,
  categoria: 'Bebidas',
  costo_sin_iva: 300,
  costo_con_iva: 363,
  impuestos_internos: 20,
  precio_sin_iva: 413
}

const mockProducto3 = {
  id: 'prod-3',
  nombre: 'Gaseosa 2L',
  codigo: 'GAS2L',
  precio: 350,
  stock: 5, // Stock bajo
  stock_minimo: 15,
  categoria: 'Bebidas'
}

// Helper para crear mock chain de supabase
const createMockChain = (data, error = null) => ({
  select: vi.fn().mockReturnThis(),
  insert: vi.fn().mockReturnThis(),
  update: vi.fn().mockReturnThis(),
  delete: vi.fn().mockReturnThis(),
  eq: vi.fn().mockReturnThis(),
  order: vi.fn().mockResolvedValue({ data, error }),
  single: vi.fn().mockResolvedValue({ data: data?.[0] || data, error })
})

describe('useProductos', () => {
  beforeEach(() => {
    vi.clearAllMocks()

    // Mock por defecto: fetch vacío
    const emptyChain = createMockChain([])
    supabase.from.mockReturnValue(emptyChain)
  })

  describe('Estado inicial', () => {
    it('inicia con loading true y productos vacíos', async () => {
      const { result } = renderHook(() => useProductos())

      expect(result.current.loading).toBe(true)
      expect(result.current.productos).toEqual([])
    })
  })

  describe('fetchProductos', () => {
    it('carga productos correctamente', async () => {
      const productosChain = createMockChain([mockProducto1, mockProducto2])
      supabase.from.mockReturnValue(productosChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      expect(result.current.productos).toHaveLength(2)
      expect(result.current.productos[0].nombre).toBe('Agua Mineral 500ml')
    })

    it('maneja errores de fetch', async () => {
      const errorChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockRejectedValue(new Error('Error de conexión'))
      }
      supabase.from.mockReturnValue(errorChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      expect(result.current.productos).toEqual([])
      expect(notifyError).toHaveBeenCalledWith(expect.stringContaining('Error al cargar productos'))
    })
  })

  describe('refetch', () => {
    it('permite refrescar productos manualmente', async () => {
      let callCount = 0
      const productosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockImplementation(() => {
          callCount++
          if (callCount === 1) {
            return Promise.resolve({ data: [mockProducto1], error: null })
          }
          return Promise.resolve({ data: [mockProducto1, mockProducto2, mockProducto3], error: null })
        })
      }

      supabase.from.mockReturnValue(productosChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      expect(result.current.productos).toHaveLength(1)

      await act(async () => {
        await result.current.refetch()
      })

      await waitFor(() => {
        expect(result.current.productos).toHaveLength(3)
      })
    })
  })

  it('sólo lee: no expone escrituras (#1475)', async () => {
    const { result } = renderHook(() => useProductos())
    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })
    expect(Object.keys(result.current).sort()).toEqual(['loading', 'productos', 'refetch'])
  })
})
