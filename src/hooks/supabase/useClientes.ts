/**
 * useClientes - Hook para gestión de clientes
 *
 * Refactorizado para usar clienteService.
 * El hook ahora solo maneja estado React y delega operaciones al servicio.
 */

import { useState, useEffect, useCallback } from 'react'
import { clienteService } from '../../services'
import type { ClienteDB, ClienteFormInput, UseClientesReturn } from '../../types'

export function useClientes(): UseClientesReturn {
  const [clientes, setClientes] = useState<ClienteDB[]>([])
  const [loading, setLoading] = useState(true)

  const fetchClientes = useCallback(async () => {
    setLoading(true)
    try {
      const data = await clienteService.getAll() as unknown as ClienteDB[]
      setClientes(data)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    fetchClientes()
  }, [fetchClientes])

  /**
   * Transforma datos del formulario al formato de la base de datos
   */
  const transformarDatos = (cliente: ClienteFormInput) => ({
    cuit: cliente.cuit || null,
    razon_social: cliente.razonSocial,
    nombre_fantasia: cliente.nombreFantasia,
    direccion: cliente.direccion,
    latitud: cliente.latitud || null,
    longitud: cliente.longitud || null,
    telefono: cliente.telefono || null,
    contacto: cliente.contacto || null,
    zona: cliente.zona || null,
    horarios_atencion: cliente.horarios_atencion || null,
    rubro: cliente.rubro || null,
    notas: cliente.notas || null,
    limite_credito: cliente.limiteCredito ? parseFloat(String(cliente.limiteCredito)) : 0,
    dias_credito: cliente.diasCredito ? parseInt(String(cliente.diasCredito)) : 30
  })

  const agregarCliente = useCallback(async (cliente: ClienteFormInput): Promise<ClienteDB> => {
    // Validar datos
    const validation = clienteService.validate({
      nombre_fantasia: cliente.nombreFantasia,
      direccion: cliente.direccion,
      telefono: cliente.telefono,
      email: cliente.email
    })

    if (!validation.valid) {
      throw new Error(validation.errors.join(', '))
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const data = await clienteService.create(transformarDatos(cliente) as any) as unknown as ClienteDB
    setClientes(prev =>
      [...prev, data].sort((a, b) =>
        a.nombre_fantasia.localeCompare(b.nombre_fantasia)
      )
    )
    return data
  }, [])

  const actualizarCliente = useCallback(async (id: string, cliente: Partial<ClienteFormInput>): Promise<ClienteDB> => {
    const updateData: Record<string, unknown> = {
      cuit: cliente.cuit || null,
      razon_social: cliente.razonSocial,
      nombre_fantasia: cliente.nombreFantasia,
      direccion: cliente.direccion,
      latitud: cliente.latitud || null,
      longitud: cliente.longitud || null,
      telefono: cliente.telefono || null,
      contacto: cliente.contacto || null,
      zona: cliente.zona || null,
      horarios_atencion: cliente.horarios_atencion || null,
      rubro: cliente.rubro || null,
      notas: cliente.notas || null
    }

    if (cliente.limiteCredito !== undefined) {
      updateData.limite_credito = parseFloat(String(cliente.limiteCredito)) || 0
    }
    if (cliente.diasCredito !== undefined) {
      updateData.dias_credito = parseInt(String(cliente.diasCredito)) || 30
    }

    const data = await clienteService.update(id, updateData) as unknown as ClienteDB
    setClientes(prev => prev.map(c => c.id === id ? data : c))
    return data
  }, [])

  const eliminarCliente = useCallback(async (id: string): Promise<void> => {
    await clienteService.delete(id)
    setClientes(prev => prev.filter(c => c.id !== id))
  }, [])

  // Métodos adicionales delegados al servicio
  const buscarClientes = useCallback(async (termino: string): Promise<ClienteDB[]> => {
    return clienteService.buscar(termino) as unknown as Promise<ClienteDB[]>
  }, [])

  const getClientesPorZona = useCallback(async (zona: string): Promise<ClienteDB[]> => {
    return clienteService.getByZona(zona) as unknown as Promise<ClienteDB[]>
  }, [])

  const getResumenCuenta = useCallback(async (clienteId: string) => {
    return clienteService.getResumenCuenta(clienteId)
  }, [])

  return {
    clientes,
    loading,
    agregarCliente,
    actualizarCliente,
    eliminarCliente,
    buscarClientes,
    getClientesPorZona,
    getResumenCuenta,
    refetch: fetchClientes
  }
}
