/**
 * useClientes - Hook para gestión de clientes
 *
 * Refactorizado para usar clienteService.
 * El hook ahora solo maneja estado React y delega operaciones al servicio.
 */

import { useState, useEffect, useCallback } from 'react'
import { clienteService } from '../../services'

export function useClientes() {
  const [clientes, setClientes] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchClientes = useCallback(async () => {
    setLoading(true)
    try {
      const data = await clienteService.getAll()
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
  const transformarDatos = (cliente) => ({
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
    limite_credito: cliente.limiteCredito ? parseFloat(cliente.limiteCredito) : 0,
    dias_credito: cliente.diasCredito ? parseInt(cliente.diasCredito) : 30
  })

  const agregarCliente = useCallback(async (cliente) => {
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

    const data = await clienteService.create(transformarDatos(cliente))
    setClientes(prev =>
      [...prev, data].sort((a, b) =>
        a.nombre_fantasia.localeCompare(b.nombre_fantasia)
      )
    )
    return data
  }, [])

  const actualizarCliente = useCallback(async (id, cliente) => {
    const updateData = {
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
      updateData.limite_credito = parseFloat(cliente.limiteCredito) || 0
    }
    if (cliente.diasCredito !== undefined) {
      updateData.dias_credito = parseInt(cliente.diasCredito) || 30
    }

    const data = await clienteService.update(id, updateData)
    setClientes(prev => prev.map(c => c.id === id ? data : c))
    return data
  }, [])

  const eliminarCliente = useCallback(async (id) => {
    await clienteService.delete(id)
    setClientes(prev => prev.filter(c => c.id !== id))
  }, [])

  // Métodos adicionales delegados al servicio
  const buscarClientes = useCallback(async (termino) => {
    return clienteService.buscar(termino)
  }, [])

  const getClientesPorZona = useCallback(async (zona) => {
    return clienteService.getByZona(zona)
  }, [])

  const getResumenCuenta = useCallback(async (clienteId) => {
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
