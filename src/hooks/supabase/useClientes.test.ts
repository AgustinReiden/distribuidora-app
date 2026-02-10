import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { useClientes } from './useClientes'
import type { ClienteDB, ClienteFormInput } from '../../types'

// Mock the services module
vi.mock('../../services', () => ({
  clienteService: {
    getAll: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
    delete: vi.fn(),
    validate: vi.fn(),
    buscar: vi.fn(),
    getByZona: vi.fn(),
    getResumenCuenta: vi.fn(),
  }
}))

import { clienteService } from '../../services'

describe('useClientes', () => {
  const mockClientes: ClienteDB[] = [
    {
      id: '1',
      nombre_fantasia: 'Cliente B',
      razon_social: 'Cliente B SA',
      cuit: '20-12345678-9',
      direccion: 'Calle 123',
      telefono: '123456789',
      email: 'clienteb@example.com',
      zona: 'Zona 1',
      limite_credito: 50000,
      dias_credito: 30,
      activo: true,
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-01T00:00:00Z',
    },
    {
      id: '2',
      nombre_fantasia: 'Cliente A',
      razon_social: 'Cliente A SA',
      cuit: '20-98765432-1',
      direccion: 'Avenida 456',
      telefono: '987654321',
      email: 'clientea@example.com',
      zona: 'Zona 2',
      limite_credito: 100000,
      dias_credito: 45,
      activo: true,
      created_at: '2024-01-02T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    }
  ]

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('should load clientes on mount with loading state', async () => {
    vi.mocked(clienteService.getAll).mockResolvedValue(mockClientes)

    const { result } = renderHook(() => useClientes())

    expect(result.current.loading).toBe(true)
    expect(result.current.clientes).toEqual([])

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    expect(clienteService.getAll).toHaveBeenCalledTimes(1)
    expect(result.current.clientes).toHaveLength(2)
    // Data is returned as-is, not sorted on initial fetch
    expect(result.current.clientes[0].nombre_fantasia).toBe('Cliente B')
    expect(result.current.clientes[1].nombre_fantasia).toBe('Cliente A')
  })

  it('should handle empty response on initial fetch', async () => {
    vi.mocked(clienteService.getAll).mockResolvedValue([])

    const { result } = renderHook(() => useClientes())

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    expect(result.current.clientes).toEqual([])
    expect(clienteService.getAll).toHaveBeenCalledTimes(1)
  })

  it('should validate, create, and add cliente to state sorted', async () => {
    vi.mocked(clienteService.getAll).mockResolvedValue([mockClientes[0]])
    vi.mocked(clienteService.validate).mockReturnValue({ valid: true, errors: [] })
    
    const newCliente: ClienteDB = {
      id: '3',
      nombre_fantasia: 'Cliente C',
      razon_social: 'Cliente C SA',
      cuit: '20-11111111-1',
      direccion: 'Calle Nueva',
      telefono: '111111111',
      email: 'clientec@example.com',
      zona: 'Zona 1',
      limite_credito: 75000,
      dias_credito: 60,
      activo: true,
      created_at: '2024-01-03T00:00:00Z',
      updated_at: '2024-01-03T00:00:00Z',
    }

    vi.mocked(clienteService.create).mockResolvedValue(newCliente)

    const { result } = renderHook(() => useClientes())

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    const input: ClienteFormInput = {
      nombreFantasia: 'Cliente C',
      razonSocial: 'Cliente C SA',
      cuit: '20-11111111-1',
      direccion: 'Calle Nueva',
      telefono: '111111111',
      email: 'clientec@example.com',
      zona: 'Zona 1',
      limiteCredito: 75000,
      diasCredito: 60,
      activo: true,
    }

    await act(async () => {
      await result.current.agregarCliente(input)
    })

    expect(clienteService.validate).toHaveBeenCalledWith(expect.objectContaining({
      nombre_fantasia: 'Cliente C',
      direccion: 'Calle Nueva',
      telefono: '111111111',
      email: 'clientec@example.com',
    }))
    expect(clienteService.create).toHaveBeenCalledWith(expect.objectContaining({
      nombre_fantasia: 'Cliente C',
      razon_social: 'Cliente C SA',
      limite_credito: 75000,
      dias_credito: 60,
    }))
    expect(result.current.clientes).toHaveLength(2)
    // After adding, clientes should be sorted: Cliente B, Cliente C
    expect(result.current.clientes[0].nombre_fantasia).toBe('Cliente B')
    expect(result.current.clientes[1].nombre_fantasia).toBe('Cliente C')
  })

  it('should throw on validation failure when adding cliente', async () => {
    vi.mocked(clienteService.getAll).mockResolvedValue([])
    vi.mocked(clienteService.validate).mockReturnValue({
      valid: false,
      errors: ['Validation failed', 'Missing required fields']
    })

    const { result } = renderHook(() => useClientes())

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    const input: ClienteFormInput = {
      nombreFantasia: 'Invalid',
      razonSocial: '',
      cuit: '',
      direccion: '',
      telefono: '',
      email: '',
      zona: '',
      limiteCredito: 0,
      diasCredito: 0,
      activo: true,
    }

    await expect(async () => {
      await act(async () => {
        await result.current.agregarCliente(input)
      })
    }).rejects.toThrow('Validation failed, Missing required fields')

    expect(clienteService.create).not.toHaveBeenCalled()
  })

  it('should update cliente and reflect in state', async () => {
    vi.mocked(clienteService.getAll).mockResolvedValue([mockClientes[0]])

    const updatedCliente: ClienteDB = {
      ...mockClientes[0],
      nombre_fantasia: 'Cliente B Updated',
      limite_credito: 60000,
    }

    vi.mocked(clienteService.update).mockResolvedValue(updatedCliente)

    const { result } = renderHook(() => useClientes())

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    const input: ClienteFormInput = {
      nombreFantasia: 'Cliente B Updated',
      razonSocial: 'Cliente B SA',
      cuit: '20-12345678-9',
      direccion: 'Calle 123',
      telefono: '123456789',
      email: 'clienteb@example.com',
      zona: 'Zona 1',
      limiteCredito: 60000,
      diasCredito: 30,
      activo: true,
    }

    await act(async () => {
      await result.current.actualizarCliente('1', input)
    })

    expect(clienteService.update).toHaveBeenCalledWith('1', expect.objectContaining({
      nombre_fantasia: 'Cliente B Updated',
      limite_credito: 60000,
    }))
    expect(result.current.clientes[0].nombre_fantasia).toBe('Cliente B Updated')
    expect(result.current.clientes[0].limite_credito).toBe(60000)
  })

  it('should handle limiteCredito and diasCredito parsing in actualizarCliente', async () => {
    vi.mocked(clienteService.getAll).mockResolvedValue([mockClientes[0]])

    const updatedCliente: ClienteDB = {
      ...mockClientes[0],
      limite_credito: 75000.5,
      dias_credito: 45,
    }

    vi.mocked(clienteService.update).mockResolvedValue(updatedCliente)

    const { result } = renderHook(() => useClientes())

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    const input: ClienteFormInput = {
      nombreFantasia: 'Cliente B',
      razonSocial: 'Cliente B SA',
      cuit: '20-12345678-9',
      direccion: 'Calle 123',
      telefono: '123456789',
      email: 'clienteb@example.com',
      zona: 'Zona 1',
      limiteCredito: '75000.5' as any, // String that should be parsed
      diasCredito: '45' as any, // String that should be parsed
      activo: true,
    }

    await act(async () => {
      await result.current.actualizarCliente('1', input)
    })

    expect(clienteService.update).toHaveBeenCalledWith('1', expect.objectContaining({
      limite_credito: 75000.5,
      dias_credito: 45,
    }))
  })

  it('should remove cliente from state when deleted', async () => {
    vi.mocked(clienteService.getAll).mockResolvedValue(mockClientes)
    vi.mocked(clienteService.delete).mockResolvedValue()

    const { result } = renderHook(() => useClientes())

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    expect(result.current.clientes).toHaveLength(2)

    await act(async () => {
      await result.current.eliminarCliente('1')
    })

    expect(clienteService.delete).toHaveBeenCalledWith('1')
    expect(result.current.clientes).toHaveLength(1)
    expect(result.current.clientes[0].id).toBe('2')
  })

  it('should delegate buscarClientes to service', async () => {
    vi.mocked(clienteService.getAll).mockResolvedValue([])
    const searchResults = [mockClientes[0]]
    vi.mocked(clienteService.buscar).mockResolvedValue(searchResults)

    const { result } = renderHook(() => useClientes())

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    let resultado
    await act(async () => {
      resultado = await result.current.buscarClientes('Cliente B')
    })

    expect(clienteService.buscar).toHaveBeenCalledWith('Cliente B')
    expect(resultado).toEqual(searchResults)
  })

  it('should delegate getClientesPorZona to service', async () => {
    vi.mocked(clienteService.getAll).mockResolvedValue([])
    const zonaResults = [mockClientes[0]]
    vi.mocked(clienteService.getByZona).mockResolvedValue(zonaResults)

    const { result } = renderHook(() => useClientes())

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    let resultado
    await act(async () => {
      resultado = await result.current.getClientesPorZona('Zona 1')
    })

    expect(clienteService.getByZona).toHaveBeenCalledWith('Zona 1')
    expect(resultado).toEqual(zonaResults)
  })

  it('should delegate getResumenCuenta to service', async () => {
    vi.mocked(clienteService.getAll).mockResolvedValue([])
    const resumenMock = {
      clienteId: '1',
      saldoActual: 10000,
      limiteCredito: 50000,
      saldoDisponible: 40000,
      pedidosPendientes: 2,
    }
    vi.mocked(clienteService.getResumenCuenta).mockResolvedValue(resumenMock)

    const { result } = renderHook(() => useClientes())

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    let resultado
    await act(async () => {
      resultado = await result.current.getResumenCuenta('1')
    })

    expect(clienteService.getResumenCuenta).toHaveBeenCalledWith('1')
    expect(resultado).toEqual(resumenMock)
  })

  it('should refetch clientes', async () => {
    vi.mocked(clienteService.getAll).mockResolvedValue([mockClientes[0]])

    const { result } = renderHook(() => useClientes())

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    expect(clienteService.getAll).toHaveBeenCalledTimes(1)
    expect(result.current.clientes).toHaveLength(1)

    // Change mock to return different data
    vi.mocked(clienteService.getAll).mockResolvedValue(mockClientes)

    await act(async () => {
      await result.current.refetch()
    })

    expect(clienteService.getAll).toHaveBeenCalledTimes(2)
    expect(result.current.clientes).toHaveLength(2)
  })

  it('should transform camelCase input to snake_case for database', async () => {
    vi.mocked(clienteService.getAll).mockResolvedValue([])
    vi.mocked(clienteService.validate).mockReturnValue({ valid: true, errors: [] })
    
    const newCliente: ClienteDB = {
      id: '1',
      nombre_fantasia: 'Test Cliente',
      razon_social: 'Test SA',
      cuit: '20-12345678-9',
      direccion: 'Test Address',
      telefono: '123456',
      email: 'test@test.com',
      zona: 'Zona Test',
      limite_credito: 50000.75,
      dias_credito: 30,
      activo: true,
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-01T00:00:00Z',
    }

    vi.mocked(clienteService.create).mockResolvedValue(newCliente)

    const { result } = renderHook(() => useClientes())

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    const input: ClienteFormInput = {
      nombreFantasia: 'Test Cliente',
      razonSocial: 'Test SA',
      cuit: '20-12345678-9',
      direccion: 'Test Address',
      telefono: '123456',
      email: 'test@test.com',
      zona: 'Zona Test',
      limiteCredito: '50000.75',
      diasCredito: '30',
      activo: true,
    }

    await act(async () => {
      await result.current.agregarCliente(input)
    })

    expect(clienteService.validate).toHaveBeenCalledWith(expect.objectContaining({
      nombre_fantasia: 'Test Cliente',
      direccion: 'Test Address',
      telefono: '123456',
      email: 'test@test.com',
    }))

    expect(clienteService.create).toHaveBeenCalledWith(expect.objectContaining({
      nombre_fantasia: 'Test Cliente',
      razon_social: 'Test SA',
      limite_credito: 50000.75,
      dias_credito: 30,
    }))
  })
})
