/**
 * Handlers para operaciones con compras
 */
import { useCallback } from 'react'

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
}) {
  const handleNuevaCompra = useCallback(() => {
    modales.compra.setOpen(true)
  }, [modales.compra])

  const handleRegistrarCompra = useCallback(async (compraData) => {
    try {
      await registrarCompra({
        ...compraData,
        usuarioId: user?.id
      })
      notify.success('Compra registrada correctamente. Stock actualizado.')
      refetchProductos()
      refetchCompras()
    } catch (e) {
      notify.error('Error al registrar compra: ' + e.message)
      throw e
    }
  }, [registrarCompra, user, refetchProductos, refetchCompras, notify])

  const handleVerDetalleCompra = useCallback((compra) => {
    setCompraDetalle(compra)
    modales.detalleCompra.setOpen(true)
  }, [setCompraDetalle, modales.detalleCompra])

  const handleAnularCompra = useCallback((compraId) => {
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
          notify.error('Error al anular compra: ' + e.message)
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
