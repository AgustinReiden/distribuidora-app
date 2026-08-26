/**
 * ClientesContainer
 *
 * Container que carga clientes bajo demanda usando TanStack Query.
 * Maneja estado de modales y operaciones CRUD.
 */
import React, { Suspense, useState, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useClientesQuery,
  useClienteQuery,
  useCrearClienteMutation,
  useActualizarClienteMutation,
  useEliminarClienteMutation,
  contarReferenciasDeCliente,
  buscarClientePorRazonSocial,
  useZonasEstandarizadasQuery,
  useProductosQuery,
  useCrearPedidoCambioEnRutaMutation,
  type RegistrarCambioInput,
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useFichaCliente } from '../../hooks/supabase/useFichaCliente'
import { usePagos } from '../../hooks/supabase'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'
import { useQueryClient } from '@tanstack/react-query'
import { puedeRegistrarPagoCliente, puedeDesactivarCliente, puedeEliminarCliente } from '../../lib/permisos'
import type { ClienteDB } from '../../types'
import type { ClienteSaveData } from '../modals/ModalCliente'
import { lazyWithReload } from '../../utils/lazyWithReload'
import { formatCurrency } from '../../utils/formatters'

// Lazy load de componentes
const VistaClientes = lazyWithReload(() => import('../vistas/VistaClientes'))
const ModalCliente = lazyWithReload(() => import('../modals/ModalCliente'))
const ModalFichaCliente = lazyWithReload(() => import('../modals/ModalFichaCliente'))
const ModalConfirmacion = lazyWithReload(() => import('../modals/ModalConfirmacion'))
const ModalZonas = lazyWithReload(() => import('../modals/ModalZonas'))
const ModalRegistrarPago = lazyWithReload(() => import('../modals/ModalRegistrarPago'))
const ModalDeudoresMora = lazyWithReload(() => import('../modals/ModalDeudoresMora'))
const ModalCambioProducto = lazyWithReload(() => import('../modals/ModalCambioProducto'))

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
  const { registrarPago, registrarPagoFIFO, registrarPagoCombinadoFIFO, obtenerResumenCuenta } = usePagos()
  const rol = perfil?.rol
  const puedePago = puedeRegistrarPagoCliente(rol)
  // Preventista editando un cliente existente: solo puede tocar datos de
  // contacto/atención (razón social, dirección, teléfono, contacto, rubro,
  // horarios, notas). El resto lo gestiona admin/encargado.
  const edicionRestringida = isPreventista && !isAdmin && !isEncargado

  // "Ver inactivos": el panel es el unico lugar desde donde se reactiva un
  // cliente dado de baja, asi que tiene que poder mostrarlos a pedido.
  const [verInactivos, setVerInactivos] = useState(false)

  // Queries
  const { data: clientes = [], isLoading } = useClientesQuery({ includeInactivos: verInactivos })
  // includeInactive: true para no perder el texto cuando una zona se desactiva
  // entre ediciones del cliente — el espejo legacy debe seguir resolviendo
  // aunque la zona ya no esté disponible en el selector activo.
  const { data: zonas = [] } = useZonasEstandarizadasQuery({ includeInactive: true })
  const { data: productos = [] } = useProductosQuery()
  const puedeCambio = isAdmin || isEncargado

  // Mutations
  const crearCliente = useCrearClienteMutation()
  const actualizarCliente = useActualizarClienteMutation()
  const eliminarCliente = useEliminarClienteMutation()
  const crearCambioEnRutaMut = useCrearPedidoCambioEnRutaMutation()

  // Estado de modales
  const [modalClienteOpen, setModalClienteOpen] = useState(false)
  const [modalFichaOpen, setModalFichaOpen] = useState(false)
  const [modalZonasOpen, setModalZonasOpen] = useState(false)
  const [modalDeudoresOpen, setModalDeudoresOpen] = useState(false)
  const [clienteFichaId, setClienteFichaId] = useState<string | null>(null)
  const [clientePago, setClientePago] = useState<ClienteDB | null>(null)
  const [saldoPendientePago, setSaldoPendientePago] = useState<number>(0)
  // Cambio/devolución como parada, desde la ficha del cliente.
  const [cambioCliente, setCambioCliente] = useState<ClienteDB | null>(null)

  // Ficha cliente hook - ModalFichaCliente lo usa internamente
  useFichaCliente(clienteFichaId)

  // Se resuelve por ID contra la base y no buscando en `clientes`: con
  // "Ver inactivos" apagado esa lista no trae los desactivados, y la ficha se
  // abre igual desde el panel de deudores, donde un inactivo con saldo sigue
  // figurando.
  const { data: clienteFicha } = useClienteQuery(clienteFichaId ?? '')

  // Estado de edición
  const [clienteEditando, setClienteEditando] = useState<ClienteDB | null>(null)

  // Confirm modal state
  const [confirmConfig, setConfirmConfig] = useState<ConfirmConfig>({ visible: false })

  // Cerrar todos los modales al cambiar de sucursal: useFichaCliente y
  // usePagos usan useState local (no son TanStack Queries), por lo que la
  // invalidacion global de SucursalContext no los limpia.
  useResetOnSucursalChange(() => {
    setModalClienteOpen(false)
    setModalFichaOpen(false)
    setModalZonasOpen(false)
    setModalDeudoresOpen(false)
    setCambioCliente(null)
    setClienteFichaId(null)
    setClientePago(null)
    setClienteEditando(null)
    setConfirmConfig({ visible: false })
  })

  // Handlers
  const handleNuevoCliente = useCallback(() => {
    setClienteEditando(null)
    setModalClienteOpen(true)
  }, [])

  const handleEditarCliente = useCallback((cliente: ClienteDB) => {
    setClienteEditando(cliente)
    setModalClienteOpen(true)
  }, [])

  // Borrar un cliente con pedidos NO es una operacion inocente: hasta la mig 200
  // la FK era ON DELETE SET NULL y los pedidos quedaban sin dueno en silencio.
  // Asi se perdieron 9 pedidos por $200.070 (mig 199), en cuatro borrados que
  // eran una deduplicacion legitima: lo que faltaba era que la app dijera que se
  // estaba llevando puesto. Ahora se cuenta primero y se ofrece desactivar.
  const handleEliminarCliente = useCallback(async (clienteId: string) => {
    const cliente = clientes.find(c => c.id === clienteId)
    if (!cliente) return
    const nombre = cliente.nombre_fantasia || cliente.razon_social

    let referencias: Awaited<ReturnType<typeof contarReferenciasDeCliente>>
    try {
      referencias = await contarReferenciasDeCliente(clienteId)
    } catch {
      // Sin poder contar no se pregunta: preguntar sin saber es lo que causo el problema.
      notify.error('No se pudo verificar si el cliente tiene movimientos. No se eliminó nada.')
      return
    }

    if (!referencias.bloqueanBorrado) {
      if (!puedeEliminarCliente(rol)) {
        notify.error('Solo un administrador puede eliminar clientes.')
        return
      }
      setConfirmConfig({
        visible: true, tipo: 'danger', titulo: 'Eliminar cliente',
        mensaje: `¿Eliminar "${nombre}"? No tiene pedidos ni movimientos asociados.`,
        onConfirm: async () => {
          setConfirmConfig({ visible: false })
          try {
            await eliminarCliente.mutateAsync(clienteId)
            notify.success('Cliente eliminado')
          } catch (err) {
            // deleteCliente ya traduce el 23503 a un mensaje que dice que lo traba.
            notify.error(err instanceof Error ? err.message : 'Error al eliminar cliente')
          }
        },
      })
      return
    }

    if (!puedeDesactivarCliente(rol)) {
      notify.error('No tenés permiso para desactivar clientes.')
      return
    }

    // Con movimientos la base rechaza el DELETE (FKs RESTRICT, migs 200/024/089).
    // Se explica por que y se ofrece la accion que si corresponde: desactivarlo.
    const detalle: string[] = []
    if (referencias.pedidos.cantidad > 0) {
      detalle.push(
        `${referencias.pedidos.cantidad} ${referencias.pedidos.cantidad === 1 ? 'pedido' : 'pedidos'} ` +
        `por ${formatCurrency(referencias.pedidos.total)}`
      )
    }
    if (referencias.cambiosProductos > 0) {
      detalle.push(`${referencias.cambiosProductos} ${referencias.cambiosProductos === 1 ? 'cambio' : 'cambios'} de producto`)
    }
    if (referencias.recorridoCambios > 0) {
      detalle.push(`${referencias.recorridoCambios} ${referencias.recorridoCambios === 1 ? 'parada' : 'paradas'} de cambio`)
    }

    setConfirmConfig({
      visible: true, tipo: 'warning', titulo: 'El cliente tiene historial',
      mensaje:
        `"${nombre}" tiene ${detalle.join(' y ')}. ` +
        'No se puede eliminar sin perder eso del historial y de la cuenta corriente. ' +
        'Al confirmar se DESACTIVA: deja de aparecer en el panel y en los pedidos, ' +
        'pero sus datos siguen intactos y visibles en los reportes.',
      onConfirm: async () => {
        setConfirmConfig({ visible: false })
        try {
          await actualizarCliente.mutateAsync({ id: clienteId, data: { activo: false } })
          notify.success(`"${nombre}" quedó desactivado`)
        } catch {
          notify.error('Error al desactivar el cliente')
        }
      },
    })
  }, [clientes, eliminarCliente, actualizarCliente, notify, rol])

  // Reactivar: la contracara de desactivar. Sin esto la baja logica seria un
  // viaje de ida y el unico camino de vuelta seria crear un cliente nuevo, que
  // es exactamente lo que parte el historial en dos.
  const handleReactivarCliente = useCallback(async (clienteId: string) => {
    const cliente = clientes.find(c => c.id === clienteId)
    if (!cliente) return
    const nombre = cliente.nombre_fantasia || cliente.razon_social
    if (!puedeDesactivarCliente(rol)) {
      notify.error('No tenés permiso para reactivar clientes.')
      return
    }
    try {
      await actualizarCliente.mutateAsync({ id: clienteId, data: { activo: true } })
      notify.success(`"${nombre}" volvió a estar activo`)
    } catch {
      notify.error('Error al reactivar el cliente')
    }
  }, [clientes, actualizarCliente, notify, rol])

  const handleGuardarCambioEnRuta = useCallback(async (data: RegistrarCambioInput) => {
    try {
      await crearCambioEnRutaMut.mutateAsync(data)
      notify.success('Cambio/devolución agregado como parada del recorrido')
      setCambioCliente(null)
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo crear la parada de cambio')
      throw err
    }
  }, [crearCambioEnRutaMut, notify])

  const handleVerFichaCliente = useCallback((cliente: ClienteDB) => {
    setClienteFichaId(cliente.id)
    setModalFichaOpen(true)
  }, [])

  // Abre la ficha desde el panel de deudores (la RPC devuelve cliente_id numérico).
  const handleVerFichaDesdeDeudores = useCallback((clienteId: number) => {
    setModalDeudoresOpen(false)
    setClienteFichaId(String(clienteId))
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
    clientRequestId?: string
  }) => {
    const pago = await registrarPago({
      clienteId: datosPago.clienteId,
      pedidoId: datosPago.pedidoId,
      monto: datosPago.monto,
      formaPago: datosPago.formaPago,
      referencia: datosPago.referencia,
      notas: datosPago.notas,
      fecha: datosPago.fecha,
      usuarioId: user?.id ?? '',
      clientRequestId: datosPago.clientRequestId,
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
    clientRequestId?: string
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

  const handleConfirmarPagoCombinadoFIFO = useCallback(async (input: {
    clienteId: string
    metodos: { monto: number; formaPago: string }[]
    fecha?: string
    referencia?: string
    notas?: string
    clientRequestId?: string
  }) => {
    const result = await registrarPagoCombinadoFIFO(input)
    queryClient.invalidateQueries({ queryKey: ['pedidos'] })
    queryClient.invalidateQueries({ queryKey: ['ficha-cliente'] })
    queryClient.invalidateQueries({ queryKey: ['clientes'] })
    if (result.sobrante > 0) {
      notify.success(`Pago registrado. $${result.sobrante.toLocaleString('es-AR')} quedó como saldo a favor.`)
    } else {
      notify.success('Pago registrado y aplicado a pedidos pendientes')
    }
    return result
  }, [registrarPagoCombinadoFIFO, queryClient, notify])

  const handleGestionarZonas = useCallback(() => {
    setModalZonasOpen(true)
  }, [])

  const handleGuardarCliente = useCallback(async (data: ClienteSaveData) => {
    // Bloqueo de nombre duplicado dentro de la sucursal (ignora mayúsculas y
    // espacios extremos). Solo aplica a altas o cuando el nombre cambió, para no
    // romper la edición de clientes homónimos ya existentes (se los respeta).
    // `clientes` ya viene scopeado a la sucursal activa por useClientesQuery.
    const nombreNuevo = (data.razonSocial || data.nombreFantasia || '').trim()
    const nombreNuevoNorm = nombreNuevo.toLowerCase()
    const nombreOriginalNorm = (clienteEditando?.razon_social || '').trim().toLowerCase()
    if (nombreNuevoNorm && nombreNuevoNorm !== nombreOriginalNorm) {
      // Se consulta la BASE, no el array `clientes`: por defecto ese array no
      // trae inactivos, asi que mirarlo dejaba crear un clon exacto del cliente
      // recien desactivado -- la forma mas facil de partirle el historial al
      // medio, y justo el movimiento que origino los 9 pedidos huerfanos.
      // Cuando el que choca esta inactivo, el mensaje ofrece reactivarlo.
      let choque: Awaited<ReturnType<typeof buscarClientePorRazonSocial>> = null
      try {
        choque = await buscarClientePorRazonSocial(nombreNuevo, clienteEditando?.id)
      } catch {
        notify.error('No se pudo verificar si el nombre ya existe. No se guardó nada.')
        return
      }
      if (choque) {
        notify.error(
          choque.activo === false
            ? `Ya existe "${nombreNuevo}" en esta sucursal, pero está inactivo. ` +
              `Activá "Ver inactivos" y reactivalo, así conserva su historial.`
            : `Ya existe un cliente con el nombre "${nombreNuevo}" en esta sucursal.`
        )
        return
      }
    }

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

    // Preventista editando: patch acotado a los campos que puede tocar.
    // CUIT, nombre fantasía, zona, crédito, descuentos y asignaciones quedan
    // fuera para que no se sobrescriban desde esta UI.
    if (!isCreating && edicionRestringida) {
      const patchRestringido = {
        razon_social: data.razonSocial || data.nombreFantasia,
        direccion: data.direccion,
        aclaracion_direccion: data.aclaracionDireccion?.trim() || null,
        latitud: data.latitud,
        longitud: data.longitud,
        place_id: data.place_id ?? null,
        telefono: data.telefono || undefined,
        contacto: data.contacto || undefined,
        horarios_atencion: data.horarios_atencion || undefined,
        // dias_atencion faltaba en el patch: el selector de días de ModalCliente
        // se editaba pero nunca se persistía (el bitmask lo usa el ruteo).
        dias_atencion: data.dias_atencion ?? null,
        sin_horario_fijo: data.sin_horario_fijo,
        horario_entrega: data.horario_entrega || undefined,
        rubro: data.rubro || undefined,
        notas: data.notas || undefined,
      }
      try {
        await actualizarCliente.mutateAsync({ id: clienteEditando!.id, data: patchRestringido })
        notify.success('Cliente actualizado')
        setModalClienteOpen(false)
        setClienteEditando(null)
      } catch (error) {
        notify.error((error as Error).message || 'Error al guardar cliente')
        throw error
      }
      return
    }

    const dbData = {
      razon_social: data.razonSocial || data.nombreFantasia,
      nombre_fantasia: data.nombreFantasia,
      direccion: data.direccion,
      aclaracion_direccion: data.aclaracionDireccion?.trim() || null,
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
      place_id: data.place_id ?? null,
      limite_credito: data.limiteCredito,
      dias_credito: data.diasCredito,
      descuento_porcentaje: data.descuentoPorcentaje,
      contacto: data.contacto || undefined,
      horarios_atencion: data.horarios_atencion || undefined,
      dias_atencion: data.dias_atencion ?? null,
      sin_horario_fijo: data.sin_horario_fijo,
      horario_entrega: data.horario_entrega || undefined,
      rubro: data.rubro || undefined,
      notas: data.notas || undefined,
      ...(ids !== undefined ? { preventista_id: ids[0] ?? null, preventista_ids: ids } : {}),
      // Descuentos por categoría: solo admin puede escribirlos (RLS de
      // cliente_descuentos_categoria exige es_admin()). Para no-admin omitimos
      // la clave para que replaceCategoriaDiscounts ni se ejecute.
      ...(isAdmin ? {
        // FC/ZZ por defecto de pedidos (mig 116): solo admin lo edita (el guard
        // trigger de clientes lo bloquea para preventistas de todas formas).
        tipo_factura_default: data.tipoFacturaDefault ?? 'ZZ',
        descuentos_categoria: data.descuentosPorCategoria
          .filter(d => d.categoria && d.categoria.trim() !== '')
          .map(d => ({ categoria: d.categoria.trim(), descuento_porcentaje: d.porcentaje })),
      } : {})
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
  }, [clienteEditando, actualizarCliente, crearCliente, notify, isAdmin, isPreventista, edicionRestringida, user, zonas])

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
          onReactivarCliente={handleReactivarCliente}
          verInactivos={verInactivos}
          onVerInactivosChange={setVerInactivos}
          puedeDesactivar={puedeDesactivarCliente(rol)}
          onVerFichaCliente={handleVerFichaCliente}
          onGestionarZonas={isAdmin ? handleGestionarZonas : undefined}
          onVerDeudores={(isAdmin || isEncargado) ? () => setModalDeudoresOpen(true) : undefined}
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
            edicionRestringida={edicionRestringida && !!clienteEditando}
          />
        </Suspense>
      )}

      {/* Modal Deudores en mora */}
      {modalDeudoresOpen && (
        <Suspense fallback={null}>
          <ModalDeudoresMora
            onClose={() => setModalDeudoresOpen(false)}
            onVerFicha={handleVerFichaDesdeDeudores}
          />
        </Suspense>
      )}

      {/* Modal Ficha Cliente */}
      {modalFichaOpen && clienteFichaId && (
        <Suspense fallback={null}>
          <ModalFichaCliente
            cliente={clienteFicha ?? clientes.find(c => c.id === clienteFichaId) ?? null}
            onClose={() => {
              setModalFichaOpen(false)
              setClienteFichaId(null)
            }}
            onRegistrarPago={puedePago ? handleAbrirRegistrarPago : undefined}
            onCambioEnRuta={puedeCambio ? (cliente) => setCambioCliente(cliente) : undefined}
          />
        </Suspense>
      )}

      {/* Modal Cambio/Devolución como parada (cliente fijo desde su ficha) */}
      {cambioCliente && (
        <Suspense fallback={null}>
          <ModalCambioProducto
            clientes={clientes}
            productos={productos}
            modo="enRuta"
            clienteFijo={cambioCliente}
            onSave={async (data) => { await handleGuardarCambioEnRuta(data as RegistrarCambioInput) }}
            onClose={() => setCambioCliente(null)}
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
            onConfirmarCombinadoFIFO={handleConfirmarPagoCombinadoFIFO}
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
