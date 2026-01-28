/**
 * Handlers para operaciones con usuarios
 */
import { useCallback } from 'react'
import type { PerfilDB, ModalState } from '../../types/hooks'
import type { NotifyService } from './types'

// Re-exportar tipos compartidos para compatibilidad
export type { NotifyService } from './types'

// Alias para compatibilidad
export type NotifyApi = NotifyService

/** Modales interface for usuario handlers */
export interface ModalesUsuario {
  usuario: ModalState;
}

/** Parameters for useUsuarioHandlers */
export interface UseUsuarioHandlersParams {
  actualizarUsuario: (id: string, datos: Partial<PerfilDB>) => Promise<void>;
  modales: ModalesUsuario;
  setGuardando: (guardando: boolean) => void;
  setUsuarioEditando: (usuario: PerfilDB | null) => void;
  notify: NotifyApi;
}

/** Return type for useUsuarioHandlers */
export interface UseUsuarioHandlersReturn {
  handleGuardarUsuario: (usuario: PerfilDB) => Promise<void>;
}

export function useUsuarioHandlers({
  actualizarUsuario,
  modales,
  setGuardando,
  setUsuarioEditando,
  notify
}: UseUsuarioHandlersParams): UseUsuarioHandlersReturn {
  const handleGuardarUsuario = useCallback(async (usuario: PerfilDB): Promise<void> => {
    setGuardando(true)
    try {
      await actualizarUsuario(usuario.id, usuario)
      modales.usuario.setOpen(false)
      setUsuarioEditando(null)
      notify.success('Usuario actualizado correctamente')
    } catch (e: unknown) {
      const errorMessage = e instanceof Error ? e.message : 'Error desconocido'
      notify.error('Error: ' + errorMessage)
    }
    setGuardando(false)
  }, [actualizarUsuario, notify, modales.usuario, setUsuarioEditando, setGuardando])

  return {
    handleGuardarUsuario
  }
}
