/**
 * Handlers para operaciones con productos y mermas
 */
import { useCallback } from 'react'
import type { User } from '@supabase/supabase-js'
import type {
  ProductoDB,
  ProductoFormInput,
  MermaFormInputExtended,
  MermaRegistroResult
} from '../../types'

// =============================================================================
// TIPOS PARA MODALES
// =============================================================================

export interface ModalControl {
  open: boolean;
  setOpen: (open: boolean) => void;
}

export interface ConfirmModalConfig {
  visible: boolean;
  titulo?: string;
  mensaje?: string;
  tipo?: 'success' | 'warning' | 'danger' | 'info';
  onConfirm?: () => Promise<void> | void;
}

export interface ConfirmModal {
  setConfig: (config: ConfirmModalConfig) => void;
}

export interface ProductoModales {
  producto: ModalControl;
  mermaStock: ModalControl;
  historialMermas: ModalControl;
  confirm: ConfirmModal;
}

// =============================================================================
// TIPOS PARA NOTIFICACIONES
// =============================================================================

export interface NotifyOptions {
  persist?: boolean;
}

export interface NotifyService {
  success: (message: string, options?: NotifyOptions) => void;
  error: (message: string, duration?: number) => void;
  warning: (message: string) => void;
  info: (message: string) => void;
}

// =============================================================================
// TIPOS PARA MERMA
// =============================================================================

export interface MermaDataInput {
  productoId: string;
  cantidad: number;
  motivo: string;
  observaciones?: string | null;
  stockAnterior: number;
  stockNuevo: number;
  usuarioId?: string | null;
}

export interface MermaOfflineData extends MermaDataInput {
  usuarioId?: string;
}

// =============================================================================
// PROPS DEL HOOK
// =============================================================================

export interface UseProductoHandlersProps {
  agregarProducto: (producto: ProductoFormInput) => Promise<ProductoDB>;
  actualizarProducto: (id: string, producto: Partial<ProductoFormInput>) => Promise<ProductoDB>;
  eliminarProducto: (id: string) => Promise<void>;
  registrarMerma: (merma: MermaFormInputExtended) => Promise<MermaRegistroResult>;
  modales: ProductoModales;
  setGuardando: (guardando: boolean) => void;
  setProductoEditando: (producto: ProductoDB | null) => void;
  setProductoMerma: (producto: ProductoDB | null) => void;
  refetchProductos: () => Promise<void>;
  refetchMermas: () => Promise<void>;
  notify: NotifyService;
  user: User | null;
  isOnline: boolean;
  guardarMermaOffline: (merma: MermaOfflineData) => void;
}

// =============================================================================
// RETURN TYPE DEL HOOK
// =============================================================================

export interface UseProductoHandlersReturn {
  handleGuardarProducto: (producto: ProductoFormInput & { id?: string }) => Promise<void>;
  handleEliminarProducto: (id: string) => void;
  handleAbrirMerma: (producto: ProductoDB) => void;
  handleRegistrarMerma: (mermaData: MermaDataInput) => Promise<void>;
  handleVerHistorialMermas: () => void;
}

export function useProductoHandlers({
  agregarProducto,
  actualizarProducto,
  eliminarProducto,
  registrarMerma,
  modales,
  setGuardando,
  setProductoEditando,
  setProductoMerma,
  refetchProductos,
  refetchMermas,
  notify,
  user,
  isOnline,
  guardarMermaOffline
}: UseProductoHandlersProps): UseProductoHandlersReturn {
  const handleGuardarProducto = useCallback(async (producto: ProductoFormInput & { id?: string }): Promise<void> => {
    setGuardando(true)
    try {
      if (producto.id) await actualizarProducto(producto.id, producto)
      else await agregarProducto(producto)
      modales.producto.setOpen(false)
      setProductoEditando(null)
      notify.success(producto.id ? 'Producto actualizado correctamente' : 'Producto creado correctamente')
    } catch (e) {
      const error = e as Error
      notify.error('Error: ' + error.message)
    }
    setGuardando(false)
  }, [agregarProducto, actualizarProducto, notify, modales.producto, setProductoEditando, setGuardando])

  const handleEliminarProducto = useCallback((id: string): void => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Eliminar producto',
      mensaje: '¿Eliminar este producto?',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true)
        try {
          await eliminarProducto(id)
          notify.success('Producto eliminado')
        } catch (e) {
          const error = e as Error
          notify.error(error.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [eliminarProducto, notify, modales.confirm, setGuardando])

  const handleAbrirMerma = useCallback((producto: ProductoDB): void => {
    setProductoMerma(producto)
    modales.mermaStock.setOpen(true)
  }, [setProductoMerma, modales.mermaStock])

  const handleRegistrarMerma = useCallback(async (mermaData: MermaDataInput): Promise<void> => {
    try {
      if (!isOnline) {
        // SECURITY FIX: Solo guardar para sincronización posterior
        // NO actualizamos stock directamente para evitar bypass de validación
        // El stock se actualizará cuando se sincronice via RPC con validación server-side
        guardarMermaOffline({
          ...mermaData,
          usuarioId: user?.id
        })
        notify.warning('Merma guardada localmente. El stock se actualizará cuando vuelva la conexión.')
        return
      }

      await registrarMerma({
        ...mermaData,
        usuarioId: user?.id
      })
      notify.success('Merma registrada correctamente')
      refetchProductos()
      refetchMermas()
    } catch (e) {
      const error = e as Error
      notify.error('Error al registrar merma: ' + error.message)
      throw e
    }
  }, [isOnline, guardarMermaOffline, registrarMerma, user, refetchProductos, refetchMermas, notify])

  const handleVerHistorialMermas = useCallback((): void => {
    modales.historialMermas.setOpen(true)
  }, [modales.historialMermas])

  return {
    handleGuardarProducto,
    handleEliminarProducto,
    handleAbrirMerma,
    handleRegistrarMerma,
    handleVerHistorialMermas
  }
}
