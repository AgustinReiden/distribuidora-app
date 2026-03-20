import React, { lazy, Suspense, useCallback, useEffect, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { useActualizarUsuarioMutation, useUsuariosQuery } from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import type { PerfilDB } from '../../types'
import type { UsuarioFormData } from '../modals/ModalUsuario'

const VistaUsuarios = lazy(() => import('../vistas/VistaUsuarios'))
const ModalUsuario = lazy(() => import('../modals/ModalUsuario'))

function LoadingState(): React.ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function UsuariosContainer(): React.ReactElement {
  const notify = useNotification()
  const { data: usuarios = [], isLoading, error } = useUsuariosQuery()
  const actualizarUsuario = useActualizarUsuarioMutation()

  const [usuarioEditando, setUsuarioEditando] = useState<PerfilDB | null>(null)
  const [modalUsuarioOpen, setModalUsuarioOpen] = useState(false)

  useEffect(() => {
    if (error) {
      notify.error((error as Error).message || 'Error al cargar usuarios')
    }
  }, [error, notify])

  const handleEditarUsuario = useCallback((usuario: PerfilDB) => {
    setUsuarioEditando(usuario)
    setModalUsuarioOpen(true)
  }, [])

  const handleGuardarUsuario = useCallback(async (usuario: UsuarioFormData) => {
    if (!usuario.id) {
      throw new Error('No se pudo identificar el usuario a actualizar')
    }

    try {
      await actualizarUsuario.mutateAsync({
        id: usuario.id,
        data: {
          nombre: usuario.nombre,
          rol: usuario.rol,
          activo: usuario.activo,
          zona: usuario.rol === 'preventista' ? usuario.zona || null : null
        }
      })
      notify.success('Usuario actualizado')
      setModalUsuarioOpen(false)
      setUsuarioEditando(null)
    } catch (err) {
      notify.error((err as Error).message || 'Error al guardar usuario')
      throw err
    }
  }, [actualizarUsuario, notify])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaUsuarios
          usuarios={usuarios}
          loading={isLoading}
          onEditarUsuario={handleEditarUsuario}
        />
      </Suspense>

      {modalUsuarioOpen && usuarioEditando && (
        <Suspense fallback={null}>
          <ModalUsuario
            usuario={usuarioEditando}
            onSave={handleGuardarUsuario}
            onClose={() => {
              setModalUsuarioOpen(false)
              setUsuarioEditando(null)
            }}
            guardando={actualizarUsuario.isPending}
          />
        </Suspense>
      )}
    </>
  )
}
