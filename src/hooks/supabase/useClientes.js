import { useState, useEffect } from 'react'
import { supabase, notifyError } from './base'

export function useClientes() {
  const [clientes, setClientes] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchClientes = async () => {
    setLoading(true)
    try {
      const { data, error } = await supabase.from('clientes').select('*').order('nombre_fantasia')
      if (error) throw error
      setClientes(data || [])
    } catch (error) {
      notifyError('Error al cargar clientes: ' + error.message)
      setClientes([])
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { fetchClientes() }, [])

  const agregarCliente = async (cliente) => {
    const { data, error } = await supabase.from('clientes').insert([{
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
    }]).select().single()
    if (error) throw error
    setClientes(prev => [...prev, data].sort((a, b) => a.nombre_fantasia.localeCompare(b.nombre_fantasia)))
    return data
  }

  const actualizarCliente = async (id, cliente) => {
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
    if (cliente.limiteCredito !== undefined) updateData.limite_credito = parseFloat(cliente.limiteCredito) || 0
    if (cliente.diasCredito !== undefined) updateData.dias_credito = parseInt(cliente.diasCredito) || 30

    const { data, error } = await supabase.from('clientes').update(updateData).eq('id', id).select().single()
    if (error) throw error
    setClientes(prev => prev.map(c => c.id === id ? data : c))
    return data
  }

  const eliminarCliente = async (id) => {
    const { error } = await supabase.from('clientes').delete().eq('id', id)
    if (error) throw error
    setClientes(prev => prev.filter(c => c.id !== id))
  }

  return { clientes, loading, agregarCliente, actualizarCliente, eliminarCliente, refetch: fetchClientes }
}
