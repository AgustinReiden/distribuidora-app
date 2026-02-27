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
import type { ClienteDB } from '../../types'
import type { ClienteSaveData } from '../modals/ModalCliente'

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

  // Estado de modales
  const [modalClienteOpen, setModalClienteOpen] = useState(false)
  const [modalFichaOpen, setModalFichaOpen] = useState(false)
  const [clienteFichaId, setClienteFichaId] = useState<string | null>(null)

  // Ficha cliente hook - ModalFichaCliente lo usa internamente
  useFichaCliente(clienteFichaId)

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

  const handleVerFichaCliente = useCallback((cliente: ClienteDB) => {
    setClienteFichaId(cliente.id)
    setModalFichaOpen(true)
  }, [])

  const handleGuardarCliente = useCallback(async (data: ClienteSaveData) => {
    // Transform from camelCase (form) to snake_case (database)
    const dbData = {
      razon_social: data.razonSocial || data.nombreFantasia,
      nombre_fantasia: data.nombreFantasia,
      direccion: data.direccion,
      telefono: data.telefono || undefined,
      cuit: data.cuit || undefined,
      zona: data.zona || undefined,
      latitud: data.latitud,
      longitud: data.longitud,
      limite_credito: data.limiteCredito,
      dias_credito: data.diasCredito,
      contacto: data.contacto || undefined,
      horarios_atencion: data.horarios_atencion || undefined,
      rubro: data.rubro || undefined,
      notas: data.notas || undefined,
      ...(data.preventista_id ? { preventista_id: data.preventista_id } : {})
    }

    try {
      if (clienteEditando) {
        await actualizarCliente.mutateAsync({ id: clienteEditando.id, data: dbData })
        notify.success('Cliente actualizado')
      } else {
        await crearCliente.mutateAsync(dbData)
        notify.success('Cliente creado')
      }
      setModalClienteOpen(false)
      setClienteEditando(null)
    } catch (error) {
      notify.error((error as Error).message || 'Error al guardar cliente')
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
            guardando={crearCliente.isPending || actualizarCliente.isPending}
            isAdmin={isAdmin}
          />
        </Suspense>
      )}

      {/* Modal Ficha Cliente */}
      {modalFichaOpen && clienteFichaId && (
        <Suspense fallback={null}>
          <ModalFichaCliente
            cliente={clientes.find(c => c.id === clienteFichaId) || null}
            onClose={() => {
              setModalFichaOpen(false)
              setClienteFichaId(null)
            }}
          />
        </Suspense>
      )}
    </>
  )
}
