/**
 * Tests para ProductoService
 *
 * Verifica operaciones específicas de productos: stock, búsqueda,
 * precios masivos, más vendidos y validación.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest'

// Mock de logger (must be before importing the service)
vi.mock('../../utils/logger', () => ({
  logger: {
    error: vi.fn(),
    warn: vi.fn(),
    info: vi.fn(),
    debug: vi.fn()
  }
}))

// Mock de Supabase
vi.mock('../../hooks/supabase/base', () => ({
  supabase: {
    from: vi.fn(() => ({
      select: vi.fn().mockReturnThis(),
      insert: vi.fn().mockReturnThis(),
      update: vi.fn().mockReturnThis(),
      delete: vi.fn().mockReturnThis(),
      eq: vi.fn().mockReturnThis(),
      lt: vi.fn().mockReturnThis(),
      gte: vi.fn().mockReturnThis(),
      lte: vi.fn().mockReturnThis(),
      or: vi.fn().mockReturnThis(),
      order: vi.fn().mockReturnThis(),
      single: vi.fn().mockReturnThis()
    })),
    rpc: vi.fn()
  },
  notifyError: vi.fn()
}))

import { supabase, notifyError } from '../../hooks/supabase/base'
import { productoService } from '../api/productoService'
import type { StockItem, PrecioUpdate } from '../api/productoService'

// Helper to create a chainable mock query with a terminal resolution
function createMockQuery(overrides: Record<string, unknown> = {}) {
  const query: Record<string, ReturnType<typeof vi.fn>> = {
    select: vi.fn().mockReturnThis(),
    insert: vi.fn().mockReturnThis(),
    update: vi.fn().mockReturnThis(),
    delete: vi.fn().mockReturnThis(),
    eq: vi.fn().mockReturnThis(),
    lt: vi.fn().mockReturnThis(),
    gte: vi.fn().mockReturnThis(),
    lte: vi.fn().mockReturnThis(),
    or: vi.fn().mockReturnThis(),
    order: vi.fn().mockReturnThis(),
    single: vi.fn().mockReturnThis(),
    ...overrides
  }
  return query
}

describe('ProductoService', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  // ===========================================================================
  // getStockBajo
  // ===========================================================================
  describe('getStockBajo', () => {
    it('debe obtener productos con stock menor al umbral por defecto', async () => {
      const mockProductos = [
        { id: '1', nombre: 'Prod A', stock: 2 },
        { id: '2', nombre: 'Prod B', stock: 5 }
      ]

      const mockQuery = createMockQuery({
        order: vi.fn().mockResolvedValue({ data: mockProductos, error: null })
      })
      vi.mocked(supabase.from).mockReturnValue(mockQuery as any)

      const result = await productoService.getStockBajo()

      expect(supabase.from).toHaveBeenCalledWith('productos')
      expect(mockQuery.select).toHaveBeenCalledWith('*')
      expect(mockQuery.lt).toHaveBeenCalledWith('stock', 10)
      expect(mockQuery.order).toHaveBeenCalledWith('stock', { ascending: true })
      expect(result).toEqual(mockProductos)
    })

    it('debe aceptar un umbral personalizado', async () => {
      const mockQuery = createMockQuery({
        order: vi.fn().mockResolvedValue({ data: [], error: null })
      })
      vi.mocked(supabase.from).mockReturnValue(mockQuery as any)

      await productoService.getStockBajo(25)

      expect(mockQuery.lt).toHaveBeenCalledWith('stock', 25)
    })
  })

  // ===========================================================================
  // getByCategoria
  // ===========================================================================
  describe('getByCategoria', () => {
    it('debe obtener productos filtrados por categoría', async () => {
      const mockProductos = [
        { id: '1', nombre: 'Coca Cola', categoria: 'bebidas' }
      ]

      const mockQuery = createMockQuery({
        order: vi.fn().mockResolvedValue({ data: mockProductos, error: null })
      })
      vi.mocked(supabase.from).mockReturnValue(mockQuery as any)

      const result = await productoService.getByCategoria('bebidas')

      expect(supabase.from).toHaveBeenCalledWith('productos')
      expect(mockQuery.eq).toHaveBeenCalledWith('categoria', 'bebidas')
      expect(result).toEqual(mockProductos)
    })
  })

  // ===========================================================================
  // buscar
  // ===========================================================================
  describe('buscar', () => {
    it('debe buscar productos por nombre o código con ilike', async () => {
      const mockProductos = [
        { id: '1', nombre: 'Coca Cola 500ml', codigo: 'CC500' }
      ]

      const mockQuery = createMockQuery({
        order: vi.fn().mockResolvedValue({ data: mockProductos, error: null })
      })
      vi.mocked(supabase.from).mockReturnValue(mockQuery as any)

      const result = await productoService.buscar('coca')

      expect(supabase.from).toHaveBeenCalledWith('productos')
      expect(mockQuery.select).toHaveBeenCalledWith('*')
      expect(mockQuery.or).toHaveBeenCalledWith(
        'nombre.ilike.%coca%,codigo.ilike.%coca%'
      )
      expect(mockQuery.order).toHaveBeenCalledWith('nombre')
      expect(result).toEqual(mockProductos)
    })
  })

  // ===========================================================================
  // actualizarStock
  // ===========================================================================
  describe('actualizarStock', () => {
    it('debe sumar stock correctamente', async () => {
      const productoExistente = { id: 'p1', nombre: 'Prod', stock: 20 }
      const productoActualizado = { ...productoExistente, stock: 30 }

      // First call: getById (select.eq.single)
      const getByIdQuery = createMockQuery({
        single: vi.fn().mockResolvedValue({ data: productoExistente, error: null })
      })

      // Second call: update (update.eq.select.single)
      const updateQuery = createMockQuery({
        single: vi.fn().mockResolvedValue({ data: productoActualizado, error: null })
      })

      vi.mocked(supabase.from)
        .mockReturnValueOnce(getByIdQuery as any)
        .mockReturnValueOnce(updateQuery as any)

      const result = await productoService.actualizarStock('p1', 10)

      expect(updateQuery.update).toHaveBeenCalledWith({ stock: 30 })
      expect(result).toEqual(productoActualizado)
    })

    it('debe lanzar error si el producto no existe', async () => {
      const mockQuery = createMockQuery({
        single: vi.fn().mockResolvedValue({ data: null, error: new Error('Not found') })
      })
      vi.mocked(supabase.from).mockReturnValue(mockQuery as any)

      await expect(productoService.actualizarStock('inexistente', 5))
        .rejects.toThrow('Producto no encontrado')
    })

    it('debe lanzar error si el stock resultante es negativo', async () => {
      const productoExistente = { id: 'p1', nombre: 'Prod', stock: 3 }

      const mockQuery = createMockQuery({
        single: vi.fn().mockResolvedValue({ data: productoExistente, error: null })
      })
      vi.mocked(supabase.from).mockReturnValue(mockQuery as any)

      await expect(productoService.actualizarStock('p1', -10))
        .rejects.toThrow('Stock insuficiente')
    })
  })

  // ===========================================================================
  // descontarStock
  // ===========================================================================
  describe('descontarStock', () => {
    it('debe llamar RPC descontar_stock_atomico con items serializados', async () => {
      const items: StockItem[] = [
        { producto_id: 'p1', cantidad: 5 },
        { producto_id: 'p2', cantidad: 3 }
      ]

      vi.mocked(supabase.rpc).mockResolvedValue({ data: true, error: null } as any)

      const result = await productoService.descontarStock(items)

      expect(supabase.rpc).toHaveBeenCalledWith('descontar_stock_atomico', {
        items: JSON.stringify(items)
      })
      expect(result).toBe(true)
    })

    it('debe lanzar error si la RPC falla', async () => {
      vi.mocked(supabase.rpc).mockResolvedValue({
        data: null,
        error: { message: 'Stock insuficiente', code: 'P0001', details: null, hint: null }
      } as any)

      await expect(productoService.descontarStock([{ producto_id: 'p1', cantidad: 999 }]))
        .rejects.toThrow('Error en operación descontar_stock_atomico')
    })
  })

  // ===========================================================================
  // restaurarStock
  // ===========================================================================
  describe('restaurarStock', () => {
    it('debe llamar RPC restaurar_stock_atomico con items serializados', async () => {
      const items: StockItem[] = [{ producto_id: 'p1', cantidad: 2 }]

      vi.mocked(supabase.rpc).mockResolvedValue({ data: true, error: null } as any)

      const result = await productoService.restaurarStock(items)

      expect(supabase.rpc).toHaveBeenCalledWith('restaurar_stock_atomico', {
        items: JSON.stringify(items)
      })
      expect(result).toBe(true)
    })
  })

  // ===========================================================================
  // actualizarPreciosMasivo
  // ===========================================================================
  describe('actualizarPreciosMasivo', () => {
    it('debe usar RPC cuando está disponible', async () => {
      const precios: PrecioUpdate[] = [
        { codigo: 'CC500', precio_final: 1500 },
        { codigo: 'FA330', precio_final: 800 }
      ]
      const mockResult = { actualizados: 2, errores: [] }

      vi.mocked(supabase.rpc).mockResolvedValue({ data: mockResult, error: null } as any)

      const result = await productoService.actualizarPreciosMasivo(precios)

      expect(supabase.rpc).toHaveBeenCalledWith('actualizar_precios_masivo', {
        precios: JSON.stringify(precios)
      })
      expect(result).toEqual(mockResult)
    })

    it('debe hacer fallback uno por uno cuando la RPC falla', async () => {
      const precios: PrecioUpdate[] = [
        { codigo: 'CC500', precio_neto: 1200, precio_final: 1500 }
      ]

      // RPC fails
      vi.mocked(supabase.rpc).mockResolvedValue({
        data: null,
        error: { message: 'function not found', code: '42883', details: null, hint: null }
      } as any)

      // Fallback: find by codigo (select.eq.single), then update
      const findQuery = createMockQuery({
        single: vi.fn().mockResolvedValue({ data: { id: 'p1' }, error: null })
      })
      const updateQuery = createMockQuery({
        single: vi.fn().mockResolvedValue({
          data: { id: 'p1', codigo: 'CC500', precio_final: 1500 },
          error: null
        })
      })

      vi.mocked(supabase.from)
        .mockReturnValueOnce(findQuery as any)
        .mockReturnValueOnce(updateQuery as any)

      const result = await productoService.actualizarPreciosMasivo(precios)

      expect(result.actualizados).toBe(1)
      expect(result.errores).toHaveLength(0)
    })

    it('debe registrar errores en el fallback cuando un producto no se encuentra', async () => {
      const precios: PrecioUpdate[] = [
        { codigo: 'NOEXISTE', precio_final: 999 }
      ]

      // RPC fails
      vi.mocked(supabase.rpc).mockResolvedValue({
        data: null,
        error: { message: 'function not found', code: '42883', details: null, hint: null }
      } as any)

      // Fallback: product not found
      const findQuery = createMockQuery({
        single: vi.fn().mockResolvedValue({ data: null, error: null })
      })
      vi.mocked(supabase.from).mockReturnValue(findQuery as any)

      const result = await productoService.actualizarPreciosMasivo(precios)

      expect(result.actualizados).toBe(0)
      expect(result.errores).toContain('Producto NOEXISTE no encontrado')
    })
  })

  // ===========================================================================
  // getMasVendidos
  // ===========================================================================
  describe('getMasVendidos', () => {
    it('debe obtener productos más vendidos agrupados y ordenados', async () => {
      const mockData = [
        { producto_id: 'p1', productos: { id: 'p1', nombre: 'Coca Cola', codigo: 'CC', precio_final: 1500 }, cantidad: 10 },
        { producto_id: 'p1', productos: { id: 'p1', nombre: 'Coca Cola', codigo: 'CC', precio_final: 1500 }, cantidad: 5 },
        { producto_id: 'p2', productos: { id: 'p2', nombre: 'Fanta', codigo: 'FA', precio_final: 800 }, cantidad: 8 }
      ]

      const mockQuery = createMockQuery()
      // The terminal method in getMasVendidos is the query itself (no .order at end),
      // so we make select resolve the chain via the final await
      mockQuery.select = vi.fn().mockReturnValue({
        gte: vi.fn().mockReturnThis(),
        lte: vi.fn().mockReturnThis(),
        then: (resolve: (val: any) => void) => resolve({ data: mockData, error: null })
      })
      vi.mocked(supabase.from).mockReturnValue(mockQuery as any)

      const result = await productoService.getMasVendidos(10)

      expect(supabase.from).toHaveBeenCalledWith('pedido_items')
      // Coca Cola: 10 + 5 = 15, Fanta: 8 -- sorted desc
      expect(result).toHaveLength(2)
      expect(result[0].cantidad_vendida).toBe(15)
      expect(result[0].nombre).toBe('Coca Cola')
      expect(result[1].cantidad_vendida).toBe(8)
    })

    it('debe aplicar filtros de fecha cuando se proporcionan', async () => {
      const desde = new Date('2025-01-01')
      const hasta = new Date('2025-12-31')

      const gteFilter = vi.fn().mockReturnThis()
      const lteFilter = vi.fn().mockReturnValue({
        then: (resolve: (val: any) => void) => resolve({ data: [], error: null })
      })

      const mockQuery = createMockQuery()
      mockQuery.select = vi.fn().mockReturnValue({
        gte: gteFilter,
        lte: lteFilter
      })
      vi.mocked(supabase.from).mockReturnValue(mockQuery as any)

      await productoService.getMasVendidos(5, desde, hasta)

      expect(gteFilter).toHaveBeenCalledWith('created_at', desde.toISOString())
      expect(lteFilter).toHaveBeenCalledWith('created_at', hasta.toISOString())
    })

    it('debe retornar array vacío si hay error en la query', async () => {
      const mockQuery = createMockQuery()
      mockQuery.select = vi.fn().mockReturnValue({
        then: (resolve: (val: any) => void) => resolve({ data: null, error: new Error('DB Error') })
      })
      vi.mocked(supabase.from).mockReturnValue(mockQuery as any)

      const result = await productoService.getMasVendidos()

      expect(result).toEqual([])
      expect(notifyError).toHaveBeenCalled()
    })

    it('debe respetar el límite indicado', async () => {
      // Generate 5 different products
      const mockData = Array.from({ length: 5 }, (_, i) => ({
        producto_id: `p${i}`,
        productos: { id: `p${i}`, nombre: `Prod ${i}`, codigo: `P${i}`, precio_final: 100 },
        cantidad: 10 - i
      }))

      const mockQuery = createMockQuery()
      mockQuery.select = vi.fn().mockReturnValue({
        then: (resolve: (val: any) => void) => resolve({ data: mockData, error: null })
      })
      vi.mocked(supabase.from).mockReturnValue(mockQuery as any)

      const result = await productoService.getMasVendidos(3)

      expect(result).toHaveLength(3)
    })
  })

  // ===========================================================================
  // validate
  // ===========================================================================
  describe('validate', () => {
    it('debe validar producto con datos correctos', () => {
      const producto = {
        nombre: 'Coca Cola 500ml',
        codigo: 'CC500',
        precio_final: 1500,
        stock: 50
      }

      const result = productoService.validate(producto)

      expect(result.valid).toBe(true)
      expect(result.errors).toHaveLength(0)
    })

    it('debe rechazar producto sin nombre', () => {
      const producto = {
        nombre: '',
        codigo: 'CC500',
        precio_final: 1500,
        stock: 10
      }

      const result = productoService.validate(producto)

      expect(result.valid).toBe(false)
      expect(result.errors).toContain('El nombre es requerido')
    })

    it('debe rechazar producto sin código', () => {
      const producto = {
        nombre: 'Coca Cola',
        codigo: '   ',
        precio_final: 1500,
        stock: 10
      }

      const result = productoService.validate(producto)

      expect(result.valid).toBe(false)
      expect(result.errors).toContain('El código es requerido')
    })

    it('debe rechazar precio negativo', () => {
      const producto = {
        nombre: 'Coca Cola',
        codigo: 'CC500',
        precio_final: -100,
        stock: 10
      }

      const result = productoService.validate(producto)

      expect(result.valid).toBe(false)
      expect(result.errors).toContain('El precio no puede ser negativo')
    })

    it('debe rechazar stock negativo', () => {
      const producto = {
        nombre: 'Coca Cola',
        codigo: 'CC500',
        precio_final: 1500,
        stock: -5
      }

      const result = productoService.validate(producto)

      expect(result.valid).toBe(false)
      expect(result.errors).toContain('El stock no puede ser negativo')
    })

    it('debe acumular múltiples errores de validación', () => {
      const producto = {
        nombre: '',
        codigo: '',
        precio_final: -1,
        stock: -1
      }

      const result = productoService.validate(producto)

      expect(result.valid).toBe(false)
      expect(result.errors).toHaveLength(4)
      expect(result.errors).toContain('El nombre es requerido')
      expect(result.errors).toContain('El código es requerido')
      expect(result.errors).toContain('El precio no puede ser negativo')
      expect(result.errors).toContain('El stock no puede ser negativo')
    })

    it('debe aceptar precio cero como válido', () => {
      const producto = {
        nombre: 'Muestra gratis',
        codigo: 'GRATIS',
        precio_final: 0,
        stock: 1
      }

      const result = productoService.validate(producto)

      expect(result.valid).toBe(true)
    })
  })
})
