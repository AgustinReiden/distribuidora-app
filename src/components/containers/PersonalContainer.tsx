/**
 * PersonalContainer
 *
 * Carga el personal de la sucursal y conecta la vista con los modales de alta/edición,
 * baja y cuenta del empleado. Sólo admin (la ruta lo guarda y las RPCs lo validan).
 */
import React, { Suspense, useCallback, useMemo, useState } from 'react'
import { Loader2 } from 'lucide-react'
import {
  usePersonalQuery,
  useUsuariosQuery,
  useClientesQuery,
  useVehiculosQuery,
  useSucursalesActivasQuery,
  useGuardarEmpleadoMutation,
  useDarDeBajaEmpleadoMutation,
  useReactivarEmpleadoMutation,
} from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import { useSucursal } from '../../contexts/SucursalContext'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'
import { lazyWithReload } from '../../utils/lazyWithReload'
import { getErrorMessage } from '../../utils/errorHandling'
import type { Empleado, GuardarEmpleadoPayload } from '../../types/personal'

const VistaPersonal = lazyWithReload(() => import('../vistas/VistaPersonal'))
const ModalEmpleado = lazyWithReload(() => import('../modals/ModalEmpleado'))
const ModalCuentaEmpleado = lazyWithReload(() => import('../modals/ModalCuentaEmpleado'))
const ModalBajaEmpleado = lazyWithReload(() => import('../modals/ModalBajaEmpleado'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

/** Hoy en Tucumán, no en UTC: a la noche el día UTC ya es el de mañana. */
const hoyArgentino = (): string =>
  new Date().toLocaleDateString('en-CA', { timeZone: 'America/Argentina/Tucuman' })

export default function PersonalContainer(): React.ReactElement {
  const notify = useNotification()
  const { currentSucursalId, currentSucursalNombre, sucursales } = useSucursal()
  const { user } = useAuthData()

  // Alta (`{ empleado: null }`), edición o ninguno.
  const [editando, setEditando] = useState<{ empleado: Empleado | null } | null>(null)
  const [bajaDe, setBajaDe] = useState<Empleado | null>(null)
  const [cuentaDe, setCuentaDe] = useState<number | null>(null)

  const { data: empleados = [], isLoading, error, refetch } = usePersonalQuery()
  const guardarEmpleado = useGuardarEmpleadoMutation()
  const darDeBaja = useDarDeBajaEmpleadoMutation()
  const reactivar = useReactivarEmpleadoMutation()

  const sucursalesUsuario = useMemo(
    () => sucursales.map(s => ({ id: s.id, nombre: s.nombre })),
    [sucursales],
  )
  const { data: usuariosApp = [] } = useUsuariosQuery()
  const { data: clientesApp = [] } = useClientesQuery({ includeInactivos: true })
  const { data: vehiculosApp = [] } = useVehiculosQuery()
  const { data: sucursalesActivas = [] } = useSucursalesActivasQuery()

  const sucursalActual = useMemo(
    () => ({ id: currentSucursalId ?? 0, nombre: currentSucursalNombre ?? '' }),
    [currentSucursalId, currentSucursalNombre],
  )
  // Quién elige la sucursal del empleado o "Las dos": el que tiene todas las sucursales activas
  // (la misma cuenta que `usePropsModalGasto`).
  const tieneTodasLasSucursales =
    sucursalesActivas.length > 0 && sucursalesActivas.every(a => sucursalesUsuario.some(s => s.id === a.id))
  const usuarios = useMemo(
    () => usuariosApp.filter(u => u.activo !== false).map(u => ({ id: u.id, nombre: u.nombre })),
    [usuariosApp],
  )
  // Los ids de cliente llegan como string en `ClienteDB`; el modal trabaja con number.
  const clientes = useMemo(
    () => clientesApp.map(c => ({ id: Number(c.id), nombre_fantasia: c.nombre_fantasia, activo: c.activo !== false })),
    [clientesApp],
  )
  const vehiculos = useMemo(
    () => vehiculosApp.map(v => ({ id: v.id, patente: v.patente, descripcion: v.descripcion })),
    [vehiculosApp],
  )
  // Lo que ya tiene otro empleado (activo o no: el vínculo es único) no se ofrece; el del que se edita sí.
  const idEditado = editando?.empleado?.id ?? null
  const ocupados = useMemo(() => {
    const usuariosOcupados = new Set<string>()
    const clientesOcupados = new Set<number>()
    for (const e of empleados) {
      if (e.id === idEditado) continue
      if (e.usuario) usuariosOcupados.add(e.usuario.id)
      if (e.cliente) clientesOcupados.add(e.cliente.id)
    }
    return { usuarios: usuariosOcupados, clientes: clientesOcupados }
  }, [empleados, idEditado])

  const nombreSucursal = useCallback(
    (id: number): string => sucursalesUsuario.find(s => s.id === id)?.nombre ?? `Sucursal ${id}`,
    [sucursalesUsuario],
  )

  useResetOnSucursalChange(() => {
    setEditando(null)
    setBajaDe(null)
    setCuentaDe(null)
  })

  const handleGuardar = useCallback(async (payload: GuardarEmpleadoPayload) => {
    try {
      await guardarEmpleado.mutateAsync(payload)
    } catch (err) {
      notify.error(getErrorMessage(err))
      // El modal también muestra el mensaje y se queda abierto.
      throw err
    }
    notify.success(payload.id ? 'Empleado actualizado' : 'Empleado dado de alta')
  }, [guardarEmpleado, notify])

  const handleReactivar = useCallback(async (e: Empleado) => {
    try {
      await reactivar.mutateAsync(e.id)
    } catch (err) {
      notify.error(getErrorMessage(err))
      return
    }
    notify.success(`${e.nombre} reactivado`)
  }, [reactivar, notify])

  const handleConfirmarBaja = useCallback(async (fecha: string) => {
    if (!bajaDe) return
    try {
      await darDeBaja.mutateAsync({ empleadoId: bajaDe.id, fecha })
    } catch (err) {
      notify.error(getErrorMessage(err))
      throw err
    }
    notify.success(`${bajaDe.nombre} dado de baja`)
    setBajaDe(null)
  }, [darDeBaja, bajaDe, notify])

  // Desde la cuenta se edita al empleado: una cosa a la vez.
  const handleEditarDesdeCuenta = useCallback((e: Empleado) => {
    setCuentaDe(null)
    setEditando({ empleado: e })
  }, [])

  const hoy = hoyArgentino()

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaPersonal
          empleados={empleados}
          loading={isLoading}
          error={error}
          onRetry={() => { void refetch() }}
          sucursalActual={sucursalActual}
          sucursales={sucursalesUsuario}
          onNuevo={() => setEditando({ empleado: null })}
          onEditar={e => setEditando({ empleado: e })}
          onDarDeBaja={setBajaDe}
          onReactivar={handleReactivar}
          onVerFicha={e => setCuentaDe(e.id)}
        />
      </Suspense>

      {editando && (
        <Suspense fallback={null}>
          <ModalEmpleado
            empleado={editando.empleado}
            sucursalActual={sucursalActual}
            sucursalesUsuario={sucursalesUsuario}
            tieneTodasLasSucursales={tieneTodasLasSucursales}
            usuarios={usuarios}
            clientes={clientes}
            vehiculos={vehiculos}
            ocupados={ocupados}
            usuarioPropioId={user?.id ?? null}
            hoy={hoy}
            onSave={handleGuardar}
            onClose={() => setEditando(null)}
          />
        </Suspense>
      )}

      {bajaDe && (
        <Suspense fallback={null}>
          <ModalBajaEmpleado
            empleado={bajaDe}
            hoy={hoy}
            onConfirmar={handleConfirmarBaja}
            onClose={() => setBajaDe(null)}
          />
        </Suspense>
      )}

      {cuentaDe !== null && (
        <Suspense fallback={null}>
          <ModalCuentaEmpleado
            empleadoId={cuentaDe}
            nombreSucursal={nombreSucursal}
            hoy={hoy}
            onEditar={handleEditarDesdeCuenta}
            onClose={() => setCuentaDe(null)}
          />
        </Suspense>
      )}
    </>
  )
}
