import React, { Suspense, useCallback, useEffect, useMemo, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { useActualizarUsuarioMutation, useUsuariosQuery } from '../../hooks/queries'
import { useEmailsDeUsuariosQuery } from '../../hooks/queries/emailsDeUsuarios'
import { useNotification } from '../../contexts/NotificationContext'
import { useAuth } from '../../hooks/supabase/useAuth'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'
import type { PerfilDB } from '../../types'
import type { UsuarioFormData } from '../modals/ModalUsuario'
import { lazyWithReload } from '../../utils/lazyWithReload'

const VistaUsuarios = lazyWithReload(() => import('../vistas/VistaUsuarios'))
const ModalUsuario = lazyWithReload(() => import('../modals/ModalUsuario'))

function LoadingState(): React.ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function UsuariosContainer(): React.ReactElement {
  const notify = useNotification()
  const miId = useAuth().user?.id
  const { data: usuariosSinEmail = [], isLoading, error } = useUsuariosQuery()
  // Los emails van aparte, por la RPC de D53 (1601-b5): si fallan, la lista sale igual y lo
  // dice con su «Reintentar»; editar un usuario no los necesita.
  const emails = useEmailsDeUsuariosQuery(usuariosSinEmail.map(u => u.id))
  const usuarios = useMemo(
    () => usuariosSinEmail.map(u => (emails.data?.has(u.id) ? { ...u, email: emails.data.get(u.id) } : u)),
    [usuariosSinEmail, emails.data],
  )
  const actualizarUsuario = useActualizarUsuarioMutation()

  const [usuarioEditando, setUsuarioEditando] = useState<PerfilDB | null>(null)
  const [modalUsuarioOpen, setModalUsuarioOpen] = useState(false)

  // Cerrar modal al cambiar de sucursal.
  useResetOnSucursalChange(() => {
    setModalUsuarioOpen(false)
    setUsuarioEditando(null)
  })

  useEffect(() => {
    if (error) {
      notify.error((error as Error).message || 'Error al cargar usuarios')
    }
  }, [error, notify])

  const handleEditarUsuario = useCallback((usuario: PerfilDB) => {
    // C4b v3 (D1): nadie edita su propio usuario; el server lo rechaza (guardar_usuario). Se avisa
    // antes de abrir el formulario, no después de tipear.
    if (miId && usuario.id === miId) {
      notify.warning('No podés editar tu propio usuario: lo edita otro administrador.')
      return
    }
    setUsuarioEditando(usuario)
    setModalUsuarioOpen(true)
  }, [miId, notify])

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
          zona: usuario.rol === 'preventista' ? usuario.zona || null : null,
          // C4b v2: los roles extra en el mismo guardado (si el modal los tenía cargados).
          ...(usuario.rolesExtra !== undefined ? { rolesExtra: usuario.rolesExtra } : {}),
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
          errorEmails={emails.isError}
          onReintentarEmails={() => { void emails.refetch() }}
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
