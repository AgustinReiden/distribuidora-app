/**
 * Handlers para operaciones con productos y mermas
 */
import { useCallback } from 'react'

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
}) {
  const handleGuardarProducto = useCallback(async (producto) => {
    setGuardando(true)
    try {
      if (producto.id) await actualizarProducto(producto.id, producto)
      else await agregarProducto(producto)
      modales.producto.setOpen(false)
      setProductoEditando(null)
      notify.success(producto.id ? 'Producto actualizado correctamente' : 'Producto creado correctamente')
    } catch (e) {
      notify.error('Error: ' + e.message)
    }
    setGuardando(false)
  }, [agregarProducto, actualizarProducto, notify, modales.producto, setProductoEditando, setGuardando])

  const handleEliminarProducto = useCallback((id) => {
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
          notify.error(e.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [eliminarProducto, notify, modales.confirm, setGuardando])

  const handleAbrirMerma = useCallback((producto) => {
    setProductoMerma(producto)
    modales.mermaStock.setOpen(true)
  }, [setProductoMerma, modales.mermaStock])

  const handleRegistrarMerma = useCallback(async (mermaData) => {
    try {
      if (!isOnline) {
        guardarMermaOffline({
          ...mermaData,
          usuarioId: user?.id
        })
        await actualizarProducto(mermaData.productoId, { stock: mermaData.stockNuevo })
        notify.warning('Merma guardada localmente. Se sincronizará cuando vuelva la conexión.')
        refetchProductos()
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
      notify.error('Error al registrar merma: ' + e.message)
      throw e
    }
  }, [isOnline, guardarMermaOffline, actualizarProducto, registrarMerma, user, refetchProductos, refetchMermas, notify])

  const handleVerHistorialMermas = useCallback(() => {
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
