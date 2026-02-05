import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'
import { useClientes } from './useClientes'

// Mock del servicio de clientes
vi.mock('../../services', () => ({
  clienteService: {
    getAll: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
    delete: vi.fn(),
    buscar: vi.fn(),
    getByZona: vi.fn(),
    getResumenCuenta: vi.fn(),
    validate: vi.fn()
  }
}))

import { clienteService } from '../../services'

const mockCliente = {
  id: '1',
  nombre_fantasia: 'Test Cliente',
  razon_social: 'Test SRL',
  direccion: 'Test 123',
  telefono: '1234567890',
  cuit: '20-12345678-9',
  zona: 'Norte',
  limite_credito: 10000,
  dias_credito: 30,
  activo: true,
  created_at: new Date().toISOString(),
  updated_at: new Date().toISOString()
}

describe('useClientes', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(clienteService.getAll).mockResolvedValue([mockCliente])
    vi.mocked(clienteService.validate).mockReturnValue({ valid: true, errors: [] })
  })

  describe('initial load', () => {
    it('should load clientes on mount', async () => {
      const { result } = renderHook(() => useClientes())

      expect(result.current.loading).toBe(true)

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      expect(result.current.clientes).toEqual([mockCliente])
      expect(clienteService.getAll).toHaveBeenCalledTimes(1)
    })

    it('should handle empty clientes list', async () => {
      vi.mocked(clienteService.getAll).mockResolvedValue([])

      const { result } = renderHook(() => useClientes())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      expect(result.current.clientes).toEqual([])
    })
  })

  describe('agregarCliente', () => {
    it('should add a new cliente', async () => {
      const newCliente = { ...mockCliente, id: '2', nombre_fantasia: 'Nuevo Cliente' }
      vi.mocked(clienteService.create).mockResolvedValue(newCliente)

      const { result } = renderHook(() => useClientes())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      await act(async () => {
        await result.current.agregarCliente({
          nombreFantasia: 'Nuevo Cliente',
          razonSocial: 'Nuevo SRL',
          direccion: 'Nueva 456',
          telefono: '9876543210'
        })
      })

      expect(clienteService.create).toHaveBeenCalled()
      expect(result.current.clientes).toHaveLength(2)
    })

    it('should throw error on validation failure', async () => {
      vi.mocked(clienteService.validate).mockReturnValue({
        valid: false,
        errors: ['Nombre es requerido']
      })

      const { result } = renderHook(() => useClientes())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      await expect(
        act(async () => {
          await result.current.agregarCliente({
            nombreFantasia: '',
            razonSocial: '',
            direccion: '',
            telefono: ''
          })
        })
      ).rejects.toThrow('Nombre es requerido')
    })
  })

  describe('actualizarCliente', () => {
    it('should update an existing cliente', async () => {
      const updatedCliente = { ...mockCliente, nombre_fantasia: 'Cliente Actualizado' }
      vi.mocked(clienteService.update).mockResolvedValue(updatedCliente)

      const { result } = renderHook(() => useClientes())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      await act(async () => {
        await result.current.actualizarCliente('1', {
          nombreFantasia: 'Cliente Actualizado'
        })
      })

      expect(clienteService.update).toHaveBeenCalledWith('1', expect.objectContaining({
        nombre_fantasia: 'Cliente Actualizado'
      }))
      expect(result.current.clientes[0].nombre_fantasia).toBe('Cliente Actualizado')
    })
  })

  describe('eliminarCliente', () => {
    it('should delete a cliente', async () => {
      vi.mocked(clienteService.delete).mockResolvedValue(undefined)

      const { result } = renderHook(() => useClientes())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      expect(result.current.clientes).toHaveLength(1)

      await act(async () => {
        await result.current.eliminarCliente('1')
      })

      expect(clienteService.delete).toHaveBeenCalledWith('1')
      expect(result.current.clientes).toHaveLength(0)
    })
  })

  describe('buscarClientes', () => {
    it('should search clientes by term', async () => {
      const searchResults = [mockCliente]
      vi.mocked(clienteService.buscar).mockResolvedValue(searchResults)

      const { result } = renderHook(() => useClientes())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      let results
      await act(async () => {
        results = await result.current.buscarClientes('Test')
      })

      expect(clienteService.buscar).toHaveBeenCalledWith('Test')
      expect(results).toEqual(searchResults)
    })
  })

  describe('getClientesPorZona', () => {
    it('should get clientes by zona', async () => {
      const zonaClientes = [mockCliente]
      vi.mocked(clienteService.getByZona).mockResolvedValue(zonaClientes)

      const { result } = renderHook(() => useClientes())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      let results
      await act(async () => {
        results = await result.current.getClientesPorZona('Norte')
      })

      expect(clienteService.getByZona).toHaveBeenCalledWith('Norte')
      expect(results).toEqual(zonaClientes)
    })
  })

  describe('getResumenCuenta', () => {
    it('should get account summary for a cliente', async () => {
      const resumen = { saldo: 5000, pedidosPendientes: 2 }
      vi.mocked(clienteService.getResumenCuenta).mockResolvedValue(resumen)

      const { result } = renderHook(() => useClientes())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      let summary
      await act(async () => {
        summary = await result.current.getResumenCuenta('1')
      })

      expect(clienteService.getResumenCuenta).toHaveBeenCalledWith('1')
      expect(summary).toEqual(resumen)
    })
  })

  describe('refetch', () => {
    it('should refetch clientes', async () => {
      const { result } = renderHook(() => useClientes())

      await waitFor(() => {
        expect(result.current.loading).toBe(false)
      })

      expect(clienteService.getAll).toHaveBeenCalledTimes(1)

      await act(async () => {
        await result.current.refetch()
      })

      expect(clienteService.getAll).toHaveBeenCalledTimes(2)
    })
  })
})
