/**
 * Handlers para operaciones con proveedores
 */
import { useCallback } from 'react'
import type {
  ProveedorDBExtended,
  ProveedorFormInputExtended
} from '../../types'
import type { ModalControl, ConfirmModal, NotifyService } from './types'

// Re-exportar tipos compartidos para compatibilidad
export type { ModalControl, ConfirmModal, NotifyService } from './types'
export type { ConfirmModalConfig, NotifyOptions } from './types'

// =============================================================================
// TIPOS ESPECÍFICOS DE PROVEEDOR
// =============================================================================

export interface ProveedorModales {
  proveedor: ModalControl;
  confirm: ConfirmModal;
}

// =============================================================================
// PROPS DEL HOOK
// =============================================================================

export interface UseProveedorHandlersProps {
  proveedores: ProveedorDBExtended[];
  agregarProveedor: (proveedor: ProveedorFormInputExtended) => Promise<ProveedorDBExtended>;
  actualizarProveedor: (id: string, proveedor: ProveedorFormInputExtended) => Promise<ProveedorDBExtended>;
  modales: ProveedorModales;
  setGuardando: (guardando: boolean) => void;
  setProveedorEditando: (proveedor: ProveedorDBExtended | null) => void;
  refetchProveedores: () => Promise<void>;
  notify: NotifyService;
}

// =============================================================================
// RETURN TYPE DEL HOOK
// =============================================================================

export interface UseProveedorHandlersReturn {
  handleNuevoProveedor: () => void;
  handleEditarProveedor: (proveedor: ProveedorDBExtended) => void;
  handleGuardarProveedor: (proveedor: ProveedorFormInputExtended & { id?: string }) => Promise<void>;
  handleToggleActivoProveedor: (proveedor: ProveedorDBExtended) => Promise<void>;
  handleEliminarProveedor: (id: string) => void;
}

export function useProveedorHandlers({
  proveedores,
  agregarProveedor,
  actualizarProveedor,
  modales,
  setGuardando,
  setProveedorEditando,
  refetchProveedores,
  notify
}: UseProveedorHandlersProps): UseProveedorHandlersReturn {
  const handleNuevoProveedor = useCallback((): void => {
    setProveedorEditando(null)
    modales.proveedor.setOpen(true)
  }, [setProveedorEditando, modales.proveedor])

  const handleEditarProveedor = useCallback((proveedor: ProveedorDBExtended): void => {
    setProveedorEditando(proveedor)
    modales.proveedor.setOpen(true)
  }, [setProveedorEditando, modales.proveedor])

  const handleGuardarProveedor = useCallback(async (proveedor: ProveedorFormInputExtended & { id?: string }): Promise<void> => {
    setGuardando(true)
    try {
      if (proveedor.id) {
        await actualizarProveedor(proveedor.id, proveedor)
        notify.success('Proveedor actualizado correctamente')
      } else {
        await agregarProveedor(proveedor)
        notify.success('Proveedor creado correctamente')
      }
      modales.proveedor.setOpen(false)
      setProveedorEditando(null)
      refetchProveedores()
    } catch (e) {
      const error = e as Error
      notify.error('Error: ' + error.message)
    } finally {
      setGuardando(false)
    }
  }, [actualizarProveedor, agregarProveedor, modales.proveedor, setProveedorEditando, refetchProveedores, notify, setGuardando])

  const handleToggleActivoProveedor = useCallback(async (proveedor: ProveedorDBExtended): Promise<void> => {
    const nuevoEstado = proveedor.activo === false
    try {
      await actualizarProveedor(proveedor.id, { ...proveedor, activo: nuevoEstado })
      notify.success(nuevoEstado ? 'Proveedor activado' : 'Proveedor desactivado')
      refetchProveedores()
    } catch (e) {
      const error = e as Error
      notify.error('Error: ' + error.message)
    }
  }, [actualizarProveedor, refetchProveedores, notify])

  const handleEliminarProveedor = useCallback((id: string): void => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Eliminar proveedor',
      mensaje: '¿Eliminar este proveedor? Esta acción no se puede deshacer.',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true)
        try {
          const proveedor = proveedores.find(p => p.id === id)
          if (proveedor) {
            await actualizarProveedor(id, { ...proveedor, activo: false })
            notify.success('Proveedor eliminado')
            refetchProveedores()
          }
        } catch (e) {
          const error = e as Error
          notify.error('Error: ' + error.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [proveedores, actualizarProveedor, refetchProveedores, modales.confirm, notify, setGuardando])

  return {
    handleNuevoProveedor,
    handleEditarProveedor,
    handleGuardarProveedor,
    handleToggleActivoProveedor,
    handleEliminarProveedor
  }
}
