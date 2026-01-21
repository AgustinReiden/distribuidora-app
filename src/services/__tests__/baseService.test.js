/**
 * Tests para BaseService
 *
 * Verifica las operaciones CRUD genéricas y manejo de errores
 */

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { BaseService } from '../api/baseService'

// Mock de Supabase
vi.mock('../../hooks/supabase/base', () => ({
  supabase: {
    from: vi.fn(() => ({
      select: vi.fn().mockReturnThis(),
      insert: vi.fn().mockReturnThis(),
      update: vi.fn().mockReturnThis(),
      delete: vi.fn().mockReturnThis(),
      eq: vi.fn().mockReturnThis(),
      order: vi.fn().mockReturnThis(),
      single: vi.fn().mockReturnThis(),
      gte: vi.fn().mockReturnThis(),
      lte: vi.fn().mockReturnThis()
    })),
    rpc: vi.fn()
  },
  notifyError: vi.fn()
}))

import { supabase, notifyError } from '../../hooks/supabase/base'

describe('BaseService', () => {
  let service

  beforeEach(() => {
    vi.clearAllMocks()
    service = new BaseService('test_table', {
      orderBy: 'name',
      ascending: true
    })
  })

  describe('constructor', () => {
    it('debe inicializar con valores por defecto', () => {
      const defaultService = new BaseService('items')
      expect(defaultService.table).toBe('items')
      expect(defaultService.orderBy).toBe('id')
      expect(defaultService.ascending).toBe(true)
      expect(defaultService.selectQuery).toBe('*')
    })

    it('debe aceptar opciones personalizadas', () => {
      expect(service.table).toBe('test_table')
      expect(service.orderBy).toBe('name')
      expect(service.ascending).toBe(true)
    })
  })

  describe('getAll', () => {
    it('debe obtener todos los registros ordenados', async () => {
      const mockData = [{ id: 1, name: 'Item 1' }, { id: 2, name: 'Item 2' }]

      const mockQuery = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: mockData, error: null })
      }
      supabase.from.mockReturnValue(mockQuery)

      const result = await service.getAll()

      expect(supabase.from).toHaveBeenCalledWith('test_table')
      expect(mockQuery.select).toHaveBeenCalledWith('*')
      expect(mockQuery.order).toHaveBeenCalledWith('name', { ascending: true })
      expect(result).toEqual(mockData)
    })

    it('debe aplicar filtros', async () => {
      const mockQuery = {
        select: vi.fn().mockReturnThis(),
        eq: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: [], error: null })
      }
      supabase.from.mockReturnValue(mockQuery)

      await service.getAll({ filters: { status: 'active' } })

      expect(mockQuery.eq).toHaveBeenCalledWith('status', 'active')
    })

    it('debe manejar errores y retornar array vacío', async () => {
      const mockQuery = {
        select: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: null, error: new Error('DB Error') })
      }
      supabase.from.mockReturnValue(mockQuery)

      const result = await service.getAll()

      expect(result).toEqual([])
      expect(notifyError).toHaveBeenCalled()
    })
  })

  describe('getById', () => {
    it('debe obtener un registro por ID', async () => {
      const mockItem = { id: 1, name: 'Item 1' }

      const mockQuery = {
        select: vi.fn().mockReturnThis(),
        eq: vi.fn().mockReturnThis(),
        single: vi.fn().mockResolvedValue({ data: mockItem, error: null })
      }
      supabase.from.mockReturnValue(mockQuery)

      const result = await service.getById(1)

      expect(mockQuery.eq).toHaveBeenCalledWith('id', 1)
      expect(result).toEqual(mockItem)
    })

    it('debe retornar null si no encuentra el registro', async () => {
      const mockQuery = {
        select: vi.fn().mockReturnThis(),
        eq: vi.fn().mockReturnThis(),
        single: vi.fn().mockResolvedValue({ data: null, error: new Error('Not found') })
      }
      supabase.from.mockReturnValue(mockQuery)

      const result = await service.getById(999)

      expect(result).toBeNull()
    })
  })

  describe('create', () => {
    it('debe crear un registro y retornarlo', async () => {
      const newItem = { name: 'New Item' }
      const createdItem = { id: 1, ...newItem }

      const mockQuery = {
        insert: vi.fn().mockReturnThis(),
        select: vi.fn().mockReturnThis(),
        single: vi.fn().mockResolvedValue({ data: createdItem, error: null })
      }
      supabase.from.mockReturnValue(mockQuery)

      const result = await service.create(newItem)

      expect(mockQuery.insert).toHaveBeenCalledWith([newItem])
      expect(result).toEqual(createdItem)
    })

    it('debe lanzar error si falla la creación', async () => {
      const mockQuery = {
        insert: vi.fn().mockReturnThis(),
        select: vi.fn().mockReturnThis(),
        single: vi.fn().mockResolvedValue({ data: null, error: new Error('Constraint error') })
      }
      supabase.from.mockReturnValue(mockQuery)

      await expect(service.create({ name: 'Test' })).rejects.toThrow()
    })
  })

  describe('update', () => {
    it('debe actualizar un registro', async () => {
      const updateData = { name: 'Updated Name' }
      const updatedItem = { id: 1, ...updateData }

      const mockQuery = {
        update: vi.fn().mockReturnThis(),
        eq: vi.fn().mockReturnThis(),
        select: vi.fn().mockReturnThis(),
        single: vi.fn().mockResolvedValue({ data: updatedItem, error: null })
      }
      supabase.from.mockReturnValue(mockQuery)

      const result = await service.update(1, updateData)

      expect(mockQuery.update).toHaveBeenCalledWith(updateData)
      expect(mockQuery.eq).toHaveBeenCalledWith('id', 1)
      expect(result).toEqual(updatedItem)
    })
  })

  describe('delete', () => {
    it('debe eliminar un registro', async () => {
      const mockQuery = {
        delete: vi.fn().mockReturnThis(),
        eq: vi.fn().mockResolvedValue({ error: null })
      }
      supabase.from.mockReturnValue(mockQuery)

      const result = await service.delete(1)

      expect(mockQuery.delete).toHaveBeenCalled()
      expect(mockQuery.eq).toHaveBeenCalledWith('id', 1)
      expect(result).toBe(true)
    })
  })

  describe('rpc', () => {
    it('debe ejecutar función RPC exitosamente', async () => {
      const mockResult = { success: true }
      supabase.rpc.mockResolvedValue({ data: mockResult, error: null })

      const result = await service.rpc('test_function', { param: 'value' })

      expect(supabase.rpc).toHaveBeenCalledWith('test_function', { param: 'value' })
      expect(result).toEqual(mockResult)
    })

    it('debe usar fallback si RPC falla', async () => {
      supabase.rpc.mockResolvedValue({ data: null, error: new Error('RPC Error') })
      const fallback = vi.fn().mockResolvedValue('fallback result')

      const result = await service.rpc('test_function', {}, fallback)

      expect(fallback).toHaveBeenCalled()
      expect(result).toBe('fallback result')
    })

    it('debe lanzar error si RPC falla sin fallback', async () => {
      supabase.rpc.mockResolvedValue({ data: null, error: new Error('RPC Error') })

      await expect(service.rpc('test_function', {})).rejects.toThrow()
    })
  })

  describe('count', () => {
    it('debe contar registros', async () => {
      const mockQuery = {
        select: vi.fn().mockResolvedValue({ count: 5, error: null })
      }
      supabase.from.mockReturnValue(mockQuery)

      const result = await service.count()

      expect(mockQuery.select).toHaveBeenCalledWith('*', { count: 'exact', head: true })
      expect(result).toBe(5)
    })
  })

  describe('exists', () => {
    it('debe retornar true si existe el registro', async () => {
      const mockQuery = {
        select: vi.fn().mockReturnThis(),
        eq: vi.fn().mockResolvedValue({ count: 1, error: null })
      }
      supabase.from.mockReturnValue(mockQuery)

      const result = await service.exists({ id: 1 })

      expect(result).toBe(true)
    })

    it('debe retornar false si no existe el registro', async () => {
      const mockQuery = {
        select: vi.fn().mockReturnThis(),
        eq: vi.fn().mockResolvedValue({ count: 0, error: null })
      }
      supabase.from.mockReturnValue(mockQuery)

      const result = await service.exists({ id: 999 })

      expect(result).toBe(false)
    })
  })
})
