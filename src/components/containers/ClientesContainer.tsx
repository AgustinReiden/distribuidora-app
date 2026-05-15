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
  useEliminarClienteMutation,
  useZonasEstandarizadasQuery
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useFichaCliente } from '../../hooks/supabase/useFichaCliente'
import { usePagos } from '../../hooks/supabase'
import { useQueryClient } from '@tanstack/react-query'
import { puedeRegistrarPagoCliente } from '../../lib/permisos'
import type { ClienteDB } from '../../types'
import type { ClienteSaveData } from '../modals/ModalCliente'

// Lazy load de componentes
const VistaClientes = lazy(() => import('../vistas/VistaClientes'))
const ModalCliente = lazy(() => import('../modals/ModalCliente'))
const ModalFichaCliente = lazy(() => import('../modals/ModalFichaCliente'))
const ModalConfirmacion = lazy(() => import('../modals/ModalConfirmacion'))
const ModalZonas = lazy(() => import('../modals/ModalZonas'))
const ModalRegistrarPago = lazy(() => import('../modals/ModalRegistrarPago'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

interface ConfirmConfig {
  visible: boolean
  tipo?: 'danger' | 'warning' | 'success'
  titulo?: string
  mensaje?: string
  onConfirm?: () => void
}

export default function ClientesContainer(): React.ReactElement {
  const { user, perfil, isAdmin, isPreventista, isEncargado } = useAuthData()
  const notify = useNotification()
  const queryClient = useQueryClient()
  const { registrarPago, registrarPagoFIFO, obtenerResumenCuenta } = usePagos()
  const rol = perfil?.rol
  const puedePago = puedeRegistrarPagoCliente(rol)

  // Queries
  const { data: clientes = [], isLoading } = useClientesQuery()
  // includeInactive: true para no perder el texto cuando una zona se desactiva
  // entre ediciones del cliente — el espejo legacy debe seguir resolviendo
  // aunque la zona ya no esté disponible en el selector activo.
  const { data: zonas = [] } = useZonasEstandarizadasQuery({ includeInactive: true })

  // Mutations
  const crearCliente = useCrearClienteMutation()
  const actualizarCliente = useActualizarClienteMutation()
  const eliminarCliente = useEliminarClienteMutation()

  // Estado de modales
  const [modalClienteOpen, setModalClienteOpen] = useState(false)
  const [modalFichaOpen, setModalFichaOpen] = useState(false)
  const [modalZonasOpen, setModalZonasOpen] = useState(false)
  const [clienteFichaId, setClienteFichaId] = useState<string | null>(null)
  const [clientePago, setClientePago] = useState<ClienteDB | null>(null)
  const [saldoPendientePago, setSaldoPendientePago] = useState<number>(0)

  // Ficha cliente hook - ModalFichaCliente lo usa internamente
  useFichaCliente(clienteFichaId)

  // Estado de edición
  const [clienteEditando, setClienteEditando] = useState<ClienteDB | null>(null)

  // Confirm modal state
  const [confirmConfig, setConfirmConfig] = useState<ConfirmConfig>({ visible: false })

  // Handlers
  const handleNuevoCliente = useCallback(() => {
    setClienteEditando(null)
    setModalClienteOpen(true)
  }, [])

  const handleEditarCliente = useCallback((cliente: ClienteDB) => {
    setClienteEditando(cliente)
    setModalClienteOpen(true)
  }, [])

  const handleEliminarCliente = useCallback((clienteId: string) => {
    const cliente = clientes.find(c => c.id === clienteId)
    if (!cliente) return
    setConfirmConfig({
      visible: true, tipo: 'danger', titulo: 'Eliminar cliente',
      mensaje: `¿Eliminar "${cliente.nombre_fantasia || cliente.razon_social}"?`,
      onConfirm: async () => {
        setConfirmConfig({ visible: false })
        try {
          await eliminarCliente.mutateAsync(clienteId)
          notify.success('Cliente eliminado')
        } catch {
          notify.error('Error al eliminar cliente')
        }
      },
    })
  }, [clientes, eliminarCliente, notify])

  const handleVerFichaCliente = useCallback((cliente: ClienteDB) => {
    setClienteFichaId(cliente.id)
    setModalFichaOpen(true)
  }, [])

  const handleAbrirRegistrarPago = useCallback(async (cliente: ClienteDB) => {
    if (!puedePago) return
    setClientePago(cliente)
    const resumen = await obtenerResumenCuenta(cliente.id)
    setSaldoPendientePago(resumen?.saldo_actual ?? 0)
    setModalFichaOpen(false)
  }, [puedePago, obtenerResumenCuenta])

  const handleConfirmarPagoSimple = useCallback(async (datosPago: {
    clienteId: string
    pedidoId: string | null
    monto: number
    formaPago: string
    referencia: string
    notas: string
    fecha: string
  }) => {
    const pago = await registrarPago({
      clienteId: datosPago.clienteId,
      pedidoId: datosPago.pedidoId,
      monto: datosPago.monto,
      formaPago: datosPago.formaPago,
      referencia: datosPago.referencia,
      notas: datosPago.notas,
      fecha: datosPago.fecha,
      usuarioId: user?.id ?? ''
    })
    queryClient.invalidateQueries({ queryKey: ['pedidos'] })
    queryClient.invalidateQueries({ queryKey: ['ficha-cliente'] })
    notify.success('Pago registrado correctamente')
    return pago
  }, [registrarPago, user?.id, queryClient, notify])

  const handleConfirmarPagoFIFO = useCallback(async (input: {
    clienteId: string
    monto: number
    formaPago: string
    fecha?: string
    referencia?: string
    notas?: string
  }) => {
    const result = await registrarPagoFIFO(input)
    queryClient.invalidateQueries({ queryKey: ['pedidos'] })
    queryClient.invalidateQueries({ queryKey: ['ficha-cliente'] })
    queryClient.invalidateQueries({ queryKey: ['clientes'] })
    if (result.sobrante > 0) {
      notify.success(`Pago registrado. $${result.sobrante.toLocaleString('es-AR')} quedó como saldo a favor.`)
    } else {
      notify.success('Pago registrado y aplicado a pedidos pendientes')
    }
    return result
  }, [registrarPagoFIFO, queryClient, notify])

  const handleGestionarZonas = useCallback(() => {
    setModalZonasOpen(true)
  }, [])

  const handleGuardarCliente = useCallback(async (data: ClienteSaveData) => {
    // Transform from camelCase (form) to snake_case (database)
    // preventista_ids (N-a-N) es la fuente de verdad; preventista_id (legado)
    // se espeja con el primer asignado para no romper lecturas en otros modulos
    // hasta que se elimine la columna en una migracion futura.
    const isCreating = !clienteEditando
    // Solo admin puede editar las asignaciones desde la UI. Un preventista
    // editando un cliente NO debe tocar la tabla N-a-N (RLS lo rechazaria y
    // ademas no vio el selector). La unica excepcion: al crear, el preventista
    // se auto-asigna para que el cliente quede visible solo para el y admins.
    const willTouchAssignments =
      isAdmin || (isCreating && isPreventista && !isAdmin && !!user?.id)

    let ids: string[] | undefined
    if (willTouchAssignments) {
      const baseIds = data.preventista_ids || []
      ids = isCreating && isPreventista && !isAdmin && user?.id
        ? Array.from(new Set([...baseIds, user.id]))
        : baseIds
    }

    // Dual-write zona text + zona_id durante el deprecation window:
    // muchos read paths legacy (PDFs, reportes, bot Telegram) leen cliente.zona
    // como string. Cuando se borre clientes.zona del schema, eliminar este lookup.
    const zonaSeleccionada = data.zona_id
      ? zonas.find(z => String(z.id) === String(data.zona_id))
      : null

    const dbData = {
      razon_social: data.razonSocial || data.nombreFantasia,
      nombre_fantasia: data.nombreFantasia,
      direccion: data.direccion,
      telefono: data.telefono || undefined,
      cuit: data.cuit || undefined,
      // zona (texto) deprecada — se espeja desde zona_id resolviendo contra el
      // cache de zonas (incluye inactivas) para que PDFs/reportes/bot vean el
      // nombre correcto. Sin esto, clientes nuevos mostraban "Sin zona".
      zona: zonaSeleccionada?.nombre ?? null,
      // La coerción '' → null para zona_id vive en useClientesQuery (createCliente y
      // updateCliente). Acá solo pasamos el valor del form sin transform.
      zona_id: data.zona_id,
      latitud: data.latitud,
      longitud: data.longitud,
      limite_credito: data.limiteCredito,
      dias_credito: data.diasCredito,
      descuento_porcentaje: data.descuentoPorcentaje,
      contacto: data.contacto || undefined,
      horarios_atencion: data.horarios_atencion || undefined,
      rubro: data.rubro || undefined,
      notas: data.notas || undefined,
      ...(ids !== undefined ? { preventista_id: ids[0] ?? null, preventista_ids: ids } : {})
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
  }, [clienteEditando, actualizarCliente, crearCliente, notify, isAdmin, isPreventista, user, zonas])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaClientes
          clientes={clientes}
          loading={isLoading}
          isAdmin={isAdmin}
          isPreventista={isPreventista}
          isEncargado={isEncargado}
          onNuevoCliente={handleNuevoCliente}
          onEditarCliente={handleEditarCliente}
          onEliminarCliente={handleEliminarCliente}
          onVerFichaCliente={handleVerFichaCliente}
          onGestionarZonas={isAdmin ? handleGestionarZonas : undefined}
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
            onRegistrarPago={puedePago ? handleAbrirRegistrarPago : undefined}
          />
        </Suspense>
      )}

      {/* Modal Registrar Pago — flujo desde ficha de cliente con imputacion FIFO */}
      {clientePago && (
        <Suspense fallback={null}>
          <ModalRegistrarPago
            cliente={clientePago}
            saldoPendiente={saldoPendientePago}
            pedidos={[]}
            onClose={() => setClientePago(null)}
            onConfirmar={handleConfirmarPagoSimple as any}
            onConfirmarFIFO={handleConfirmarPagoFIFO}
          />
        </Suspense>
      )}

      {/* Modal Zonas (admin) */}
      {modalZonasOpen && (
        <Suspense fallback={null}>
          <ModalZonas onClose={() => setModalZonasOpen(false)} />
        </Suspense>
      )}

      {/* Modal Confirmación */}
      {confirmConfig.visible && (
        <Suspense fallback={null}>
          <ModalConfirmacion
            config={{
              visible: true,
              tipo: confirmConfig.tipo || 'warning',
              titulo: confirmConfig.titulo || '',
              mensaje: confirmConfig.mensaje || '',
              onConfirm: confirmConfig.onConfirm || (() => {}),
            }}
            onClose={() => setConfirmConfig({ visible: false })}
          />
        </Suspense>
      )}
    </>
  )
}
