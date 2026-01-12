import { useState, useEffect } from 'react'
import { supabase, notifyError } from './base'

export function useUsuarios() {
  const [usuarios, setUsuarios] = useState([])
  const [transportistas, setTransportistas] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchUsuarios = async () => {
    setLoading(true)
    try {
      const { data, error } = await supabase.from('perfiles').select('*').order('nombre')
      if (error) throw error
      setUsuarios(data || [])
      setTransportistas((data || []).filter(u => u.rol === 'transportista' && u.activo))
    } catch (error) {
      notifyError('Error al cargar usuarios: ' + error.message)
      setUsuarios([])
      setTransportistas([])
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { fetchUsuarios() }, [])

  const actualizarUsuario = async (id, datos) => {
    const updateData = {
      nombre: datos.nombre,
      rol: datos.rol,
      activo: datos.activo,
      zona: datos.rol === 'preventista' ? (datos.zona || null) : null
    }
    const { data, error } = await supabase.from('perfiles').update(updateData).eq('id', id).select().single()
    if (error) throw error

    setUsuarios(prev => prev.map(u => u.id === id ? data : u))
    setTransportistas(prev => {
      const updated = prev.filter(t => t.id !== id)
      if (data.rol === 'transportista' && data.activo) {
        return [...updated, data].sort((a, b) => a.nombre.localeCompare(b.nombre))
      }
      return updated
    })
    return data
  }

  return { usuarios, transportistas, loading, actualizarUsuario, refetch: fetchUsuarios }
}
