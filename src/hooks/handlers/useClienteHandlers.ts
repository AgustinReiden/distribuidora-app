/**
 * Handlers para operaciones con clientes
 */
import { useCallback } from 'react'
const generarReciboPago = async (...args: Parameters<typeof import('../../lib/pdfExport').generarReciboPago>) => {
  const mod = await import('../../lib/pdfExport')
  return mod.generarReciboPago(...args)
}
import type { User } from '@supabase/supabase-js'
import type {
  ClienteDB,
  ClienteFormInput,
  PagoFormInput,
  PagoDBWithUsuario,
  ResumenCuenta
} from '../../types'
import type { ModalControl, ConfirmModal, NotifyService } from './types'

// Re-exportar tipos compartidos para compatibilidad
export type { ModalControl, ConfirmModal, NotifyService } from './types'
export type { ConfirmModalConfig, NotifyOptions } from './types'

// =============================================================================
// TIPOS ESPECÍFICOS DE CLIENTE
// =============================================================================

export interface ClienteModales {
  cliente: ModalControl;
  fichaCliente: ModalControl;
  registrarPago: ModalControl;
  confirm: ConfirmModal;
}

// =============================================================================
// TIPOS PARA DATOS DE PAGO
// =============================================================================

export interface DatosPagoInput {
  clienteId: string;
  pedidoId?: string | null;
  monto: number | string;
  formaPago?: string;
  referencia?: string | null;
  notas?: string | null;
}

// =============================================================================
// PROPS DEL HOOK
// =============================================================================

export interface UseClienteHandlersProps {
  agregarCliente: (cliente: ClienteFormInput) => Promise<ClienteDB>;
  actualizarCliente: (id: string, cliente: Partial<ClienteFormInput>) => Promise<ClienteDB>;
  eliminarCliente: (id: string) => Promise<void>;
  registrarPago: (pago: PagoFormInput) => Promise<PagoDBWithUsuario>;
  obtenerResumenCuenta: (clienteId: string) => Promise<ResumenCuenta | null>;
  modales: ClienteModales;
  setGuardando: (guardando: boolean) => void;
  setClienteEditando: (cliente: ClienteDB | null) => void;
  setClienteFicha: (cliente: ClienteDB | null) => void;
  setClientePago: (cliente: ClienteDB | null) => void;
  setSaldoPendienteCliente: (saldo: number) => void;
  notify: NotifyService;
  user: User | null;
}

// =============================================================================
// RETURN TYPE DEL HOOK
// =============================================================================

export interface UseClienteHandlersReturn {
  handleGuardarCliente: (cliente: ClienteFormInput & { id?: string }) => Promise<void>;
  handleEliminarCliente: (id: string) => void;
  handleVerFichaCliente: (cliente: ClienteDB) => Promise<void>;
  handleAbrirRegistrarPago: (cliente: ClienteDB) => Promise<void>;
  handleRegistrarPago: (datosPago: DatosPagoInput) => Promise<PagoDBWithUsuario>;
  handleGenerarReciboPago: (pago: PagoDBWithUsuario, cliente: ClienteDB) => void;
}

export function useClienteHandlers({
  agregarCliente,
  actualizarCliente,
  eliminarCliente,
  registrarPago,
  obtenerResumenCuenta,
  modales,
  setGuardando,
  setClienteEditando,
  setClienteFicha,
  setClientePago,
  setSaldoPendienteCliente,
  notify,
  user
}: UseClienteHandlersProps): UseClienteHandlersReturn {
  const handleGuardarCliente = useCallback(async (cliente: ClienteFormInput & { id?: string }): Promise<void> => {
    setGuardando(true)
    try {
      if (cliente.id) await actualizarCliente(cliente.id, cliente)
      else await agregarCliente(cliente)
      modales.cliente.setOpen(false)
      setClienteEditando(null)
      notify.success(cliente.id ? 'Cliente actualizado correctamente' : 'Cliente creado correctamente')
    } catch (e) {
      const error = e as Error
      notify.error('Error: ' + error.message)
    }
    setGuardando(false)
  }, [agregarCliente, actualizarCliente, notify, modales.cliente, setClienteEditando, setGuardando])

  const handleEliminarCliente = useCallback((id: string): void => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Eliminar cliente',
      mensaje: '¿Eliminar este cliente?',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true)
        try {
          await eliminarCliente(id)
          notify.success('Cliente eliminado', { persist: true })
        } catch (e) {
          const error = e as Error
          notify.error(error.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [eliminarCliente, notify, modales.confirm, setGuardando])

  const handleVerFichaCliente = useCallback(async (cliente: ClienteDB): Promise<void> => {
    setClienteFicha(cliente)
    modales.fichaCliente.setOpen(true)
    const resumen = await obtenerResumenCuenta(cliente.id)
    if (resumen) {
      setSaldoPendienteCliente(resumen.saldo_actual || 0)
    }
  }, [obtenerResumenCuenta, setClienteFicha, modales.fichaCliente, setSaldoPendienteCliente])

  const handleAbrirRegistrarPago = useCallback(async (cliente: ClienteDB): Promise<void> => {
    setClientePago(cliente)
    const resumen = await obtenerResumenCuenta(cliente.id)
    if (resumen) {
      setSaldoPendienteCliente(resumen.saldo_actual || 0)
    }
    modales.registrarPago.setOpen(true)
    modales.fichaCliente.setOpen(false)
  }, [obtenerResumenCuenta, setClientePago, setSaldoPendienteCliente, modales.registrarPago, modales.fichaCliente])

  const handleRegistrarPago = useCallback(async (datosPago: DatosPagoInput): Promise<PagoDBWithUsuario> => {
    try {
      const pago = await registrarPago({
        ...datosPago,
        usuarioId: user?.id ?? ''
      })
      notify.success('Pago registrado correctamente')
      return pago
    } catch (e) {
      const error = e as Error
      notify.error('Error al registrar pago: ' + error.message)
      throw e
    }
  }, [registrarPago, user, notify])

  const handleGenerarReciboPago = useCallback((pago: PagoDBWithUsuario, cliente: ClienteDB): void => {
    try {
      generarReciboPago(pago, cliente)
      notify.success('Recibo generado correctamente')
    } catch (e) {
      const error = e as Error
      notify.error('Error al generar recibo: ' + error.message)
    }
  }, [notify])

  return {
    handleGuardarCliente,
    handleEliminarCliente,
    handleVerFichaCliente,
    handleAbrirRegistrarPago,
    handleRegistrarPago,
    handleGenerarReciboPago
  }
}
