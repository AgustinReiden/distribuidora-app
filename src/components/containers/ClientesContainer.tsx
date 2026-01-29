/**
 * ClientesContainer
 *
 * Container que carga clientes bajo demanda usando TanStack Query.
 * Maneja estado de modales y operaciones CRUD.
 */
import React, { lazy, Suspense, useState, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useClientesQuery,
  useCrearClienteMutation,
  useActualizarClienteMutation,
  useEliminarClienteMutation
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useFichaCliente } from '../../hooks/supabase/useFichaCliente'
import type { ClienteDB, ClienteFormInput } from '../../types'

// Lazy load de componentes
const VistaClientes = lazy(() => import('../vistas/VistaClientes'))
const ModalCliente = lazy(() => import('../modals/ModalCliente'))
const ModalFichaCliente = lazy(() => import('../modals/ModalFichaCliente'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function ClientesContainer(): React.ReactElement {
  const { isAdmin, isPreventista } = useAuthData()
  const notify = useNotification()

  // Queries
  const { data: clientes = [], isLoading } = useClientesQuery()

  // Mutations
  const crearCliente = useCrearClienteMutation()
  const actualizarCliente = useActualizarClienteMutation()
  const eliminarCliente = useEliminarClienteMutation()

  // Ficha cliente
  const { fichaCliente, loading: loadingFicha, cargarFicha, limpiarFicha } = useFichaCliente()

  // Estado de modales
  const [modalClienteOpen, setModalClienteOpen] = useState(false)
  const [modalFichaOpen, setModalFichaOpen] = useState(false)

  // Estado de edición
  const [clienteEditando, setClienteEditando] = useState<ClienteDB | null>(null)

  // Handlers
  const handleNuevoCliente = useCallback(() => {
    setClienteEditando(null)
    setModalClienteOpen(true)
  }, [])

  const handleEditarCliente = useCallback((cliente: ClienteDB) => {
    setClienteEditando(cliente)
    setModalClienteOpen(true)
  }, [])

  const handleEliminarCliente = useCallback(async (clienteId: string) => {
    const cliente = clientes.find(c => c.id === clienteId)
    if (!cliente) return
    if (!window.confirm(`¿Eliminar "${cliente.nombre_fantasia || cliente.razon_social}"?`)) return
    try {
      await eliminarCliente.mutateAsync(clienteId)
      notify.success('Cliente eliminado')
    } catch {
      notify.error('Error al eliminar cliente')
    }
  }, [clientes, eliminarCliente, notify])

  const handleVerFichaCliente = useCallback(async (cliente: ClienteDB) => {
    await cargarFicha(cliente.id)
    setModalFichaOpen(true)
  }, [cargarFicha])

  const handleGuardarCliente = useCallback(async (data: ClienteFormInput) => {
    try {
      if (clienteEditando) {
        await actualizarCliente.mutateAsync({ id: clienteEditando.id, data })
        notify.success('Cliente actualizado')
      } else {
        await crearCliente.mutateAsync(data)
        notify.success('Cliente creado')
      }
      setModalClienteOpen(false)
      setClienteEditando(null)
    } catch (error) {
      notify.error('Error al guardar cliente')
      throw error
    }
  }, [clienteEditando, actualizarCliente, crearCliente, notify])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaClientes
          clientes={clientes}
          loading={isLoading}
          isAdmin={isAdmin}
          isPreventista={isPreventista}
          onNuevoCliente={handleNuevoCliente}
          onEditarCliente={handleEditarCliente}
          onEliminarCliente={handleEliminarCliente}
          onVerFichaCliente={handleVerFichaCliente}
        />
      </Suspense>

      {/* Modal Cliente */}
      {modalClienteOpen && (
        <Suspense fallback={null}>
          <ModalCliente
            cliente={clienteEditando}
            onSave={handleGuardarCliente}
            onClose={() => {
              setModalClienteOpen(false)
              setClienteEditando(null)
            }}
          />
        </Suspense>
      )}

      {/* Modal Ficha Cliente */}
      {modalFichaOpen && fichaCliente && (
        <Suspense fallback={null}>
          <ModalFichaCliente
            ficha={fichaCliente}
            loading={loadingFicha}
            onClose={() => {
              setModalFichaOpen(false)
              limpiarFicha()
            }}
          />
        </Suspense>
      )}
    </>
  )
}
