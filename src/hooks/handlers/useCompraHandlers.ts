/**
 * Handlers para operaciones con compras
 */
import { useCallback } from 'react'
import type { User } from '@supabase/supabase-js'
import type {
  CompraDBExtended,
  CompraFormInputExtended,
  RegistrarCompraResult
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

export interface CompraModales {
  compra: ModalControl;
  detalleCompra: ModalControl;
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
// TIPOS PARA DATOS DE COMPRA
// =============================================================================

export interface CompraDataInput extends Omit<CompraFormInputExtended, 'usuarioId'> {
  usuarioId?: string | null;
}

// =============================================================================
// PROPS DEL HOOK
// =============================================================================

export interface UseCompraHandlersProps {
  registrarCompra: (compraData: CompraFormInputExtended) => Promise<RegistrarCompraResult>;
  anularCompra: (compraId: string) => Promise<void>;
  modales: CompraModales;
  setGuardando: (guardando: boolean) => void;
  setCompraDetalle: (compra: CompraDBExtended | null) => void;
  refetchProductos: () => Promise<void>;
  refetchCompras: () => Promise<void>;
  notify: NotifyService;
  user: User | null;
}

// =============================================================================
// RETURN TYPE DEL HOOK
// =============================================================================

export interface UseCompraHandlersReturn {
  handleNuevaCompra: () => void;
  handleRegistrarCompra: (compraData: CompraDataInput) => Promise<void>;
  handleVerDetalleCompra: (compra: CompraDBExtended) => void;
  handleAnularCompra: (compraId: string) => void;
}

export function useCompraHandlers({
  registrarCompra,
  anularCompra,
  modales,
  setGuardando,
  setCompraDetalle,
  refetchProductos,
  refetchCompras,
  notify,
  user
}: UseCompraHandlersProps): UseCompraHandlersReturn {
  const handleNuevaCompra = useCallback((): void => {
    modales.compra.setOpen(true)
  }, [modales.compra])

  const handleRegistrarCompra = useCallback(async (compraData: CompraDataInput): Promise<void> => {
    try {
      await registrarCompra({
        ...compraData,
        usuarioId: user?.id
      })
      notify.success('Compra registrada correctamente. Stock actualizado.')
      refetchProductos()
      refetchCompras()
    } catch (e) {
      const error = e as Error
      notify.error('Error al registrar compra: ' + error.message)
      throw e
    }
  }, [registrarCompra, user, refetchProductos, refetchCompras, notify])

  const handleVerDetalleCompra = useCallback((compra: CompraDBExtended): void => {
    setCompraDetalle(compra)
    modales.detalleCompra.setOpen(true)
  }, [setCompraDetalle, modales.detalleCompra])

  const handleAnularCompra = useCallback((compraId: string): void => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Anular compra',
      mensaje: '¿Anular esta compra? El stock será revertido.',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true)
        try {
          await anularCompra(compraId)
          notify.success('Compra anulada y stock revertido')
          refetchProductos()
          refetchCompras()
          modales.detalleCompra.setOpen(false)
          setCompraDetalle(null)
        } catch (e) {
          const error = e as Error
          notify.error('Error al anular compra: ' + error.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [anularCompra, refetchProductos, refetchCompras, modales.confirm, modales.detalleCompra, setCompraDetalle, notify, setGuardando])

  return {
    handleNuevaCompra,
    handleRegistrarCompra,
    handleVerDetalleCompra,
    handleAnularCompra
  }
}
