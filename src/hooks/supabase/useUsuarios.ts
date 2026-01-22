import { useState, useEffect } from 'react'
import { supabase, notifyError } from './base'
import type { PerfilDB, UseUsuariosReturn } from '../../types'

export function useUsuarios(): UseUsuariosReturn {
  const [usuarios, setUsuarios] = useState<PerfilDB[]>([])
  const [transportistas, setTransportistas] = useState<PerfilDB[]>([])
  const [loading, setLoading] = useState<boolean>(true)

  const fetchUsuarios = async (): Promise<void> => {
    setLoading(true)
    try {
      const { data, error } = await supabase.from('perfiles').select('*').order('nombre')
      if (error) throw error
      const perfiles = (data || []) as PerfilDB[]
      setUsuarios(perfiles)
      setTransportistas(perfiles.filter((u: PerfilDB) => u.rol === 'transportista' && u.activo))
    } catch (error) {
      notifyError('Error al cargar usuarios: ' + (error as Error).message)
      setUsuarios([])
      setTransportistas([])
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { fetchUsuarios() }, [])

  const actualizarUsuario = async (id: string, datos: Partial<PerfilDB>): Promise<void> => {
    const updateData = {
      nombre: datos.nombre,
      rol: datos.rol,
      activo: datos.activo,
      zona: datos.rol === 'preventista' ? (datos.zona || null) : null
    }
    const { data, error } = await supabase.from('perfiles').update(updateData).eq('id', id).select().single()
    if (error) throw error

    const updatedPerfil = data as PerfilDB
    setUsuarios((prev: PerfilDB[]) => prev.map((u: PerfilDB) => u.id === id ? updatedPerfil : u))
    setTransportistas((prev: PerfilDB[]) => {
      const updated = prev.filter((t: PerfilDB) => t.id !== id)
      if (updatedPerfil.rol === 'transportista' && updatedPerfil.activo) {
        return [...updated, updatedPerfil].sort((a: PerfilDB, b: PerfilDB) => a.nombre.localeCompare(b.nombre))
      }
      return updated
    })
  }

  return { usuarios, transportistas, loading, actualizarUsuario, refetch: fetchUsuarios }
}
