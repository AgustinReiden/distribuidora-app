/**
 * Handlers para operaciones con proveedores
 */
import { useCallback } from 'react'

export function useProveedorHandlers({
  proveedores,
  agregarProveedor,
  actualizarProveedor,
  modales,
  setGuardando,
  setProveedorEditando,
  refetchProveedores,
  notify
}) {
  const handleNuevoProveedor = useCallback(() => {
    setProveedorEditando(null)
    modales.proveedor.setOpen(true)
  }, [setProveedorEditando, modales.proveedor])

  const handleEditarProveedor = useCallback((proveedor) => {
    setProveedorEditando(proveedor)
    modales.proveedor.setOpen(true)
  }, [setProveedorEditando, modales.proveedor])

  const handleGuardarProveedor = useCallback(async (proveedor) => {
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
      notify.error('Error: ' + e.message)
    } finally {
      setGuardando(false)
    }
  }, [actualizarProveedor, agregarProveedor, modales.proveedor, setProveedorEditando, refetchProveedores, notify, setGuardando])

  const handleToggleActivoProveedor = useCallback(async (proveedor) => {
    const nuevoEstado = proveedor.activo === false
    try {
      await actualizarProveedor(proveedor.id, { ...proveedor, activo: nuevoEstado })
      notify.success(nuevoEstado ? 'Proveedor activado' : 'Proveedor desactivado')
      refetchProveedores()
    } catch (e) {
      notify.error('Error: ' + e.message)
    }
  }, [actualizarProveedor, refetchProveedores, notify])

  const handleEliminarProveedor = useCallback((id) => {
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
          notify.error('Error: ' + e.message)
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
