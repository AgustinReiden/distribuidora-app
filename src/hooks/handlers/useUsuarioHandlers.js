/**
 * Handlers para operaciones con usuarios
 */
import { useCallback } from 'react'

export function useUsuarioHandlers({
  actualizarUsuario,
  modales,
  setGuardando,
  setUsuarioEditando,
  notify
}) {
  const handleGuardarUsuario = useCallback(async (usuario) => {
    setGuardando(true)
    try {
      await actualizarUsuario(usuario.id, usuario)
      modales.usuario.setOpen(false)
      setUsuarioEditando(null)
      notify.success('Usuario actualizado correctamente')
    } catch (e) {
      notify.error('Error: ' + e.message)
    }
    setGuardando(false)
  }, [actualizarUsuario, notify, modales.usuario, setUsuarioEditando, setGuardando])

  return {
    handleGuardarUsuario
  }
}
