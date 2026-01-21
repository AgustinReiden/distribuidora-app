/**
 * Tests para ClienteService
 *
 * Verifica operaciones específicas de clientes
 */

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { clienteService } from '../api/clienteService'

// Mock de Supabase
vi.mock('../../hooks/supabase/base', () => ({
  supabase: {
    from: vi.fn(() => ({
      select: vi.fn().mockReturnThis(),
      insert: vi.fn().mockReturnThis(),
      update: vi.fn().mockReturnThis(),
      delete: vi.fn().mockReturnThis(),
      eq: vi.fn().mockReturnThis(),
      or: vi.fn().mockReturnThis(),
      gte: vi.fn().mockReturnThis(),
      in: vi.fn().mockReturnThis(),
      order: vi.fn().mockReturnThis(),
      single: vi.fn().mockReturnThis()
    })),
    rpc: vi.fn()
  },
  notifyError: vi.fn()
}))

import { supabase } from '../../hooks/supabase/base'

describe('ClienteService', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe('validate', () => {
    it('debe validar cliente con datos correctos', () => {
      const cliente = {
        nombre_fantasia: 'Mi Tienda',
        direccion: 'Calle 123',
        telefono: '1234567890',
        email: 'test@test.com'
      }

      const result = clienteService.validate(cliente)

      expect(result.valid).toBe(true)
      expect(result.errors).toHaveLength(0)
    })

    it('debe rechazar cliente sin nombre', () => {
      const cliente = {
        nombre_fantasia: '',
        direccion: 'Calle 123'
      }

      const result = clienteService.validate(cliente)

      expect(result.valid).toBe(false)
      expect(result.errors).toContain('El nombre de fantasía es requerido')
    })

    it('debe rechazar cliente sin dirección', () => {
      const cliente = {
        nombre_fantasia: 'Mi Tienda',
        direccion: ''
      }

      const result = clienteService.validate(cliente)

      expect(result.valid).toBe(false)
      expect(result.errors).toContain('La dirección es requerida')
    })

    it('debe rechazar teléfono con formato inválido', () => {
      const cliente = {
        nombre_fantasia: 'Mi Tienda',
        direccion: 'Calle 123',
        telefono: 'abc-invalid'
      }

      const result = clienteService.validate(cliente)

      expect(result.valid).toBe(false)
      expect(result.errors).toContain('El teléfono tiene un formato inválido')
    })

    it('debe rechazar email con formato inválido', () => {
      const cliente = {
        nombre_fantasia: 'Mi Tienda',
        direccion: 'Calle 123',
        email: 'invalid-email'
      }

      const result = clienteService.validate(cliente)

      expect(result.valid).toBe(false)
      expect(result.errors).toContain('El email tiene un formato inválido')
    })

    it('debe aceptar teléfono con formato válido', () => {
      const telefonosValidos = [
        '1234567890',
        '+54 11 1234-5678',
        '(011) 4567-8901',
        '11-2345-6789'
      ]

      telefonosValidos.forEach(telefono => {
        const result = clienteService.validate({
          nombre_fantasia: 'Test',
          direccion: 'Test',
          telefono
        })
        expect(result.valid).toBe(true)
      })
    })
  })

  describe('buscar', () => {
    it('debe buscar clientes por término', async () => {
      const mockClientes = [
        { id: 1, nombre_fantasia: 'Supermercado ABC' },
        { id: 2, nombre_fantasia: 'Kiosco ABC' }
      ]

      const mockQuery = {
        select: vi.fn().mockReturnThis(),
        or: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: mockClientes, error: null })
      }
      supabase.from.mockReturnValue(mockQuery)

      const result = await clienteService.buscar('ABC')

      expect(supabase.from).toHaveBeenCalledWith('clientes')
      expect(mockQuery.or).toHaveBeenCalledWith(
        'nombre_fantasia.ilike.%ABC%,razon_social.ilike.%ABC%'
      )
      expect(result).toEqual(mockClientes)
    })
  })

  describe('getByZona', () => {
    it('debe obtener clientes por zona', async () => {
      const mockClientes = [
        { id: 1, nombre_fantasia: 'Cliente 1', zona: 'Norte' }
      ]

      const mockQuery = {
        select: vi.fn().mockReturnThis(),
        eq: vi.fn().mockReturnThis(),
        order: vi.fn().mockResolvedValue({ data: mockClientes, error: null })
      }
      supabase.from.mockReturnValue(mockQuery)

      const result = await clienteService.getByZona('Norte')

      expect(result).toEqual(mockClientes)
    })
  })

  describe('getResumenCuenta', () => {
    it('debe obtener resumen de cuenta con RPC', async () => {
      const mockResumen = {
        total_pedidos: 10000,
        total_pagos: 8000,
        saldo: 2000
      }

      supabase.rpc.mockResolvedValue({ data: mockResumen, error: null })

      const result = await clienteService.getResumenCuenta('cliente-123')

      expect(supabase.rpc).toHaveBeenCalledWith(
        'obtener_resumen_cuenta_cliente',
        { p_cliente_id: 'cliente-123' }
      )
      expect(result).toEqual(mockResumen)
    })

    it('debe usar fallback si RPC falla', async () => {
      // Mock RPC falla
      supabase.rpc.mockResolvedValue({ data: null, error: new Error('RPC Error') })

      // Mock para fallback - pedidos
      const mockPedidos = {
        select: vi.fn().mockReturnThis(),
        eq: vi.fn().mockReturnThis(),
        in: vi.fn().mockResolvedValue({
          data: [
            { total: 5000, estado: 'entregado' },
            { total: 3000, estado: 'pendiente' }
          ],
          error: null
        })
      }

      // Mock para fallback - pagos
      const mockPagos = {
        select: vi.fn().mockReturnThis(),
        eq: vi.fn().mockResolvedValue({
          data: [{ monto: 4000 }],
          error: null
        })
      }

      supabase.from
        .mockReturnValueOnce(mockPedidos)
        .mockReturnValueOnce(mockPagos)

      const result = await clienteService.getResumenCuenta('cliente-123')

      expect(result).toEqual({
        total_pedidos: 8000,
        total_pagos: 4000,
        saldo: 4000
      })
    })
  })
})
