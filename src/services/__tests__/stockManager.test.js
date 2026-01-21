/**
 * Tests para StockManager
 *
 * Verifica la lógica de negocio de gestión de stock
 */

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { stockManager } from '../business/stockManager'
import { productoService } from '../api/productoService'

// Mock de productoService
vi.mock('../api/productoService', () => ({
  productoService: {
    getById: vi.fn(),
    descontarStock: vi.fn(),
    restaurarStock: vi.fn(),
    actualizarStock: vi.fn()
  }
}))

// Mock de Supabase
vi.mock('../../hooks/supabase/base', () => ({
  supabase: {
    from: vi.fn(() => ({
      select: vi.fn().mockReturnThis(),
      insert: vi.fn().mockReturnThis(),
      eq: vi.fn().mockReturnThis(),
      gte: vi.fn().mockReturnThis(),
      lte: vi.fn().mockReturnThis(),
      single: vi.fn().mockReturnThis(),
      order: vi.fn().mockReturnThis()
    })),
    rpc: vi.fn()
  },
  notifyError: vi.fn()
}))

describe('StockManager', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe('verificarDisponibilidad', () => {
    it('debe retornar disponible=true si hay stock suficiente', async () => {
      productoService.getById
        .mockResolvedValueOnce({ id: 'prod-1', nombre: 'Producto 1', stock: 100 })
        .mockResolvedValueOnce({ id: 'prod-2', nombre: 'Producto 2', stock: 50 })

      const items = [
        { producto_id: 'prod-1', cantidad: 10 },
        { producto_id: 'prod-2', cantidad: 20 }
      ]

      const result = await stockManager.verificarDisponibilidad(items)

      expect(result.disponible).toBe(true)
      expect(result.faltantes).toHaveLength(0)
    })

    it('debe retornar disponible=false si no hay stock suficiente', async () => {
      productoService.getById
        .mockResolvedValueOnce({ id: 'prod-1', nombre: 'Producto 1', codigo: 'P001', stock: 5 })
        .mockResolvedValueOnce({ id: 'prod-2', nombre: 'Producto 2', codigo: 'P002', stock: 50 })

      const items = [
        { producto_id: 'prod-1', cantidad: 10 }, // Falta stock
        { producto_id: 'prod-2', cantidad: 20 }
      ]

      const result = await stockManager.verificarDisponibilidad(items)

      expect(result.disponible).toBe(false)
      expect(result.faltantes).toHaveLength(1)
      expect(result.faltantes[0]).toEqual({
        producto_id: 'prod-1',
        nombre: 'Producto 1',
        codigo: 'P001',
        solicitado: 10,
        disponible: 5
      })
    })

    it('debe marcar como faltante si el producto no existe', async () => {
      productoService.getById.mockResolvedValueOnce(null)

      const items = [{ producto_id: 'prod-inexistente', cantidad: 10 }]

      const result = await stockManager.verificarDisponibilidad(items)

      expect(result.disponible).toBe(false)
      expect(result.faltantes[0].nombre).toBe('Producto no encontrado')
    })
  })

  describe('reservarStock', () => {
    it('debe reservar stock exitosamente', async () => {
      productoService.getById.mockResolvedValue({ id: 'prod-1', nombre: 'Test', stock: 100 })
      productoService.descontarStock.mockResolvedValue(true)

      const items = [{ producto_id: 'prod-1', cantidad: 10 }]

      const result = await stockManager.reservarStock(items)

      expect(result.success).toBe(true)
      expect(productoService.descontarStock).toHaveBeenCalledWith(items)
    })

    it('debe fallar si no hay stock suficiente', async () => {
      productoService.getById.mockResolvedValue({ id: 'prod-1', nombre: 'Test', codigo: 'T1', stock: 5 })

      const items = [{ producto_id: 'prod-1', cantidad: 10 }]

      const result = await stockManager.reservarStock(items)

      expect(result.success).toBe(false)
      expect(result.error).toContain('Stock insuficiente')
      expect(productoService.descontarStock).not.toHaveBeenCalled()
    })

    it('debe omitir validación si se especifica', async () => {
      productoService.descontarStock.mockResolvedValue(true)

      const items = [{ producto_id: 'prod-1', cantidad: 10 }]

      const result = await stockManager.reservarStock(items, { validar: false })

      expect(result.success).toBe(true)
      expect(productoService.getById).not.toHaveBeenCalled()
    })
  })

  describe('liberarStock', () => {
    it('debe liberar stock exitosamente', async () => {
      productoService.restaurarStock.mockResolvedValue(true)

      const items = [{ producto_id: 'prod-1', cantidad: 10 }]

      const result = await stockManager.liberarStock(items)

      expect(result.success).toBe(true)
      expect(productoService.restaurarStock).toHaveBeenCalledWith(items)
    })

    it('debe manejar errores al liberar stock', async () => {
      productoService.restaurarStock.mockRejectedValue(new Error('DB Error'))

      const items = [{ producto_id: 'prod-1', cantidad: 10 }]

      const result = await stockManager.liberarStock(items)

      expect(result.success).toBe(false)
      expect(result.error).toBe('DB Error')
    })
  })

  describe('ajustarDiferencia', () => {
    beforeEach(() => {
      // Mock para verificarDisponibilidad
      productoService.getById.mockImplementation(id => {
        return Promise.resolve({ id, nombre: `Producto ${id}`, stock: 100 })
      })
      productoService.restaurarStock.mockResolvedValue(true)
      productoService.descontarStock.mockResolvedValue(true)
    })

    it('debe restaurar stock de items eliminados', async () => {
      const originales = [
        { producto_id: 'prod-1', cantidad: 10 },
        { producto_id: 'prod-2', cantidad: 5 }
      ]
      const nuevos = [
        { producto_id: 'prod-1', cantidad: 10 } // prod-2 eliminado
      ]

      const result = await stockManager.ajustarDiferencia(originales, nuevos)

      expect(result.success).toBe(true)
      expect(productoService.restaurarStock).toHaveBeenCalledWith([
        { producto_id: 'prod-2', cantidad: 5 }
      ])
    })

    it('debe descontar stock de items nuevos', async () => {
      const originales = [{ producto_id: 'prod-1', cantidad: 10 }]
      const nuevos = [
        { producto_id: 'prod-1', cantidad: 10 },
        { producto_id: 'prod-2', cantidad: 5 } // Nuevo
      ]

      const result = await stockManager.ajustarDiferencia(originales, nuevos)

      expect(result.success).toBe(true)
      expect(productoService.descontarStock).toHaveBeenCalled()
    })

    it('debe ajustar diferencias en cantidades', async () => {
      const originales = [{ producto_id: 'prod-1', cantidad: 10 }]
      const nuevos = [{ producto_id: 'prod-1', cantidad: 15 }] // Aumentó 5

      const result = await stockManager.ajustarDiferencia(originales, nuevos)

      expect(result.success).toBe(true)
      // Debe descontar la diferencia de 5
      expect(productoService.descontarStock).toHaveBeenCalledWith([
        { producto_id: 'prod-1', cantidad: 5 }
      ])
    })

    it('debe restaurar si se reduce cantidad', async () => {
      const originales = [{ producto_id: 'prod-1', cantidad: 15 }]
      const nuevos = [{ producto_id: 'prod-1', cantidad: 10 }] // Redujo 5

      const result = await stockManager.ajustarDiferencia(originales, nuevos)

      expect(result.success).toBe(true)
      // Debe restaurar la diferencia de 5
      expect(productoService.restaurarStock).toHaveBeenCalledWith([
        { producto_id: 'prod-1', cantidad: 5 }
      ])
    })
  })

  describe('setUmbralStockBajo', () => {
    it('debe actualizar el umbral de stock bajo', () => {
      stockManager.setUmbralStockBajo(20)
      expect(stockManager.umbralStockBajo).toBe(20)

      // Restaurar valor por defecto
      stockManager.setUmbralStockBajo(10)
    })
  })
})
