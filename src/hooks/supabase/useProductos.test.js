/**
 * Tests para useProductos hook
 *
 * Cobertura:
 * - Estado inicial y carga
 * - CRUD de productos
 * - Validación y gestión de stock
 * - Actualización masiva de precios
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

  describe('agregarProducto', () => {
    it('agrega producto correctamente', async () => {
      const nuevoProducto = {
        nombre: 'Producto Nuevo',
        precio: 200,
        stock: 50
      }

      const productoCreado = { id: 'prod-nuevo', ...nuevoProducto, stock_minimo: 10 }

      const insertChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [], error: null }),
        insert: vi.fn().mockReturnThis(),
        single: vi.fn().mockResolvedValue({ data: productoCreado, error: null })
      }

      supabase.from.mockReturnValue(insertChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      let created
      await act(async () => {
        created = await result.current.agregarProducto(nuevoProducto)
      })

      expect(created.id).toBe('prod-nuevo')
      expect(result.current.productos).toContainEqual(productoCreado)
    })

    it('lanza error si insert falla', async () => {
      const insertChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [], error: null }),
        insert: vi.fn().mockReturnThis(),
        single: vi.fn().mockResolvedValue({ data: null, error: { message: 'Duplicate key' } })
      }

      supabase.from.mockReturnValue(insertChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      await expect(
        act(async () => {
          await result.current.agregarProducto({ nombre: 'Test', precio: 100, stock: 10 })
        })
      ).rejects.toThrow()
    })
  })

  describe('actualizarProducto', () => {
    it('actualiza producto correctamente', async () => {
      const productoActualizado = { ...mockProducto1, precio: 200 }

      const updateChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [mockProducto1], error: null }),
        update: vi.fn().mockReturnThis(),
        eq: vi.fn().mockReturnThis(),
        single: vi.fn().mockResolvedValue({ data: productoActualizado, error: null })
      }

      supabase.from.mockReturnValue(updateChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      let updated
      await act(async () => {
        updated = await result.current.actualizarProducto('prod-1', { ...mockProducto1, precio: 200 })
      })

      expect(updated.precio).toBe(200)
      expect(result.current.productos.find(p => p.id === 'prod-1')?.precio).toBe(200)
    })
  })

  describe('eliminarProducto', () => {
    it('elimina producto correctamente', async () => {
      const deleteChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [mockProducto1, mockProducto2], error: null }),
        delete: vi.fn().mockReturnThis(),
        eq: vi.fn().mockResolvedValue({ error: null })
      }

      supabase.from.mockReturnValue(deleteChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      expect(result.current.productos).toHaveLength(2)

      await act(async () => {
        await result.current.eliminarProducto('prod-1')
      })

      expect(result.current.productos).toHaveLength(1)
      expect(result.current.productos.find(p => p.id === 'prod-1')).toBeUndefined()
    })
  })

  describe('validarStock', () => {
    it('valida stock suficiente correctamente', async () => {
      const productosChain = createMockChain([mockProducto1, mockProducto2])
      supabase.from.mockReturnValue(productosChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      const items = [
        { productoId: 'prod-1', cantidad: 10 },
        { productoId: 'prod-2', cantidad: 5 }
      ]

      const validacion = result.current.validarStock(items)

      expect(validacion.valido).toBe(true)
      expect(validacion.errores).toHaveLength(0)
    })

    it('detecta stock insuficiente', async () => {
      const productosChain = createMockChain([mockProducto1, mockProducto3])
      supabase.from.mockReturnValue(productosChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      const items = [
        { productoId: 'prod-1', cantidad: 10 },
        { productoId: 'prod-3', cantidad: 10 } // stock es 5
      ]

      const validacion = result.current.validarStock(items)

      expect(validacion.valido).toBe(false)
      expect(validacion.errores).toHaveLength(1)
      expect(validacion.errores[0].mensaje).toContain('stock insuficiente')
    })

    it('detecta producto no encontrado', async () => {
      const productosChain = createMockChain([mockProducto1])
      supabase.from.mockReturnValue(productosChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      const items = [
        { productoId: 'prod-inexistente', cantidad: 10 }
      ]

      const validacion = result.current.validarStock(items)

      expect(validacion.valido).toBe(false)
      expect(validacion.errores[0].mensaje).toBe('Producto no encontrado')
    })
  })

  describe('descontarStock', () => {
    it('descuenta stock con RPC exitoso', async () => {
      supabase.rpc.mockResolvedValue({
        data: { success: true },
        error: null
      })

      const productosChain = createMockChain([mockProducto1])
      supabase.from.mockReturnValue(productosChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      const stockInicial = result.current.productos[0].stock

      await act(async () => {
        await result.current.descontarStock([{ productoId: 'prod-1', cantidad: 10 }])
      })

      expect(result.current.productos[0].stock).toBe(stockInicial - 10)
      expect(supabase.rpc).toHaveBeenCalledWith('descontar_stock_atomico', expect.any(Object))
    })

    it('lanza error cuando RPC falla con errores', async () => {
      supabase.rpc.mockResolvedValue({
        data: { success: false, errores: ['Stock insuficiente para prod-1'] },
        error: null
      })

      const productosChain = createMockChain([mockProducto1])
      supabase.from.mockReturnValue(productosChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      await expect(
        act(async () => {
          await result.current.descontarStock([{ productoId: 'prod-1', cantidad: 1000 }])
        })
      ).rejects.toThrow('Stock insuficiente')
    })
  })

  describe('restaurarStock', () => {
    it('restaura stock con RPC exitoso', async () => {
      supabase.rpc.mockResolvedValue({
        data: { success: true },
        error: null
      })

      const productosChain = createMockChain([mockProducto1])
      supabase.from.mockReturnValue(productosChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      const stockInicial = result.current.productos[0].stock

      await act(async () => {
        await result.current.restaurarStock([{ productoId: 'prod-1', cantidad: 5 }])
      })

      expect(result.current.productos[0].stock).toBe(stockInicial + 5)
      expect(supabase.rpc).toHaveBeenCalledWith('restaurar_stock_atomico', expect.any(Object))
    })
  })

  describe('actualizarPreciosMasivo', () => {
    it('actualiza precios masivamente con RPC exitoso', async () => {
      supabase.rpc.mockResolvedValue({
        data: { success: true, actualizados: 2, errores: [] },
        error: null
      })

      const productosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockImplementation(() => {
          return Promise.resolve({ data: [mockProducto1, mockProducto2], error: null })
        })
      }
      supabase.from.mockReturnValue(productosChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      const productosData = [
        { productoId: 'prod-1', precioNeto: 130, impInternos: 5, precioFinal: 160 },
        { productoId: 'prod-2', precioNeto: 420, impInternos: 20, precioFinal: 520 }
      ]

      let resultado
      await act(async () => {
        resultado = await result.current.actualizarPreciosMasivo(productosData)
      })

      expect(resultado.success).toBe(true)
      expect(resultado.actualizados).toBe(2)
      expect(supabase.rpc).toHaveBeenCalledWith('actualizar_precios_masivo', expect.any(Object))
    })

    it('usa fallback cuando RPC falla', async () => {
      // RPC falla
      supabase.rpc.mockResolvedValue({
        data: null,
        error: { message: 'Function does not exist' }
      })

      const productosChain = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockImplementation(() => {
          return Promise.resolve({ data: [mockProducto1], error: null })
        }),
        update: vi.fn().mockReturnThis(),
        eq: vi.fn().mockResolvedValue({ error: null })
      }
      supabase.from.mockReturnValue(productosChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      const productosData = [
        { productoId: 'prod-1', precioNeto: 130, impInternos: 5, precioFinal: 160 }
      ]

      let resultado
      await act(async () => {
        resultado = await result.current.actualizarPreciosMasivo(productosData)
      })

      expect(resultado.success).toBe(true)
      expect(productosChain.update).toHaveBeenCalled()
    })

    it('lanza error si no hay productos válidos', async () => {
      const productosChain = createMockChain([mockProducto1])
      supabase.from.mockReturnValue(productosChain)

      const { result } = renderHook(() => useProductos())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      // Productos sin ID válido
      const productosData = [
        { productoId: null, precioFinal: 100 },
        { productoId: undefined, precioFinal: 200 }
      ]

      await expect(
        act(async () => {
          await result.current.actualizarPreciosMasivo(productosData)
        })
      ).rejects.toThrow('No hay productos válidos para actualizar')
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
})
