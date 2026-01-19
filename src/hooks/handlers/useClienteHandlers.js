/**
 * Handlers para operaciones con clientes
 */
import { useCallback } from 'react'
import { generarReciboPago } from '../../lib/pdfExport'

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
}) {
  const handleGuardarCliente = useCallback(async (cliente) => {
    setGuardando(true)
    try {
      if (cliente.id) await actualizarCliente(cliente.id, cliente)
      else await agregarCliente(cliente)
      modales.cliente.setOpen(false)
      setClienteEditando(null)
      notify.success(cliente.id ? 'Cliente actualizado correctamente' : 'Cliente creado correctamente')
    } catch (e) {
      notify.error('Error: ' + e.message)
    }
    setGuardando(false)
  }, [agregarCliente, actualizarCliente, notify, modales.cliente, setClienteEditando, setGuardando])

  const handleEliminarCliente = useCallback((id) => {
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
          notify.error(e.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [eliminarCliente, notify, modales.confirm, setGuardando])

  const handleVerFichaCliente = useCallback(async (cliente) => {
    setClienteFicha(cliente)
    modales.fichaCliente.setOpen(true)
    const resumen = await obtenerResumenCuenta(cliente.id)
    if (resumen) {
      setSaldoPendienteCliente(resumen.saldo_actual || 0)
    }
  }, [obtenerResumenCuenta, setClienteFicha, modales.fichaCliente, setSaldoPendienteCliente])

  const handleAbrirRegistrarPago = useCallback(async (cliente) => {
    setClientePago(cliente)
    const resumen = await obtenerResumenCuenta(cliente.id)
    if (resumen) {
      setSaldoPendienteCliente(resumen.saldo_actual || 0)
    }
    modales.registrarPago.setOpen(true)
    modales.fichaCliente.setOpen(false)
  }, [obtenerResumenCuenta, setClientePago, setSaldoPendienteCliente, modales.registrarPago, modales.fichaCliente])

  const handleRegistrarPago = useCallback(async (datosPago) => {
    try {
      const pago = await registrarPago({
        ...datosPago,
        usuarioId: user.id
      })
      notify.success('Pago registrado correctamente')
      return pago
    } catch (e) {
      notify.error('Error al registrar pago: ' + e.message)
      throw e
    }
  }, [registrarPago, user, notify])

  const handleGenerarReciboPago = useCallback((pago, cliente) => {
    try {
      generarReciboPago(pago, cliente)
      notify.success('Recibo generado correctamente')
    } catch (e) {
      notify.error('Error al generar recibo: ' + e.message)
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
