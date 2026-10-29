/**
 * GastosContainer
 *
 * Carga los gastos del mes, los rubros, los vehículos y las sucursales activas, y
 * conecta la vista con los modales de alta/edición, anulación y rubros.
 */
import React, { Suspense, useCallback, useMemo, useState } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useGastosDelMesQuery,
  useGuardarGastoMutation,
  useAnularGastoMutation,
  useRubrosGastoQuery,
  useGuardarRubroGastoMutation,
  useVehiculosQuery,
  useSucursalesActivasQuery,
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useSucursal } from '../../contexts/SucursalContext'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'
import { lazyWithReload } from '../../utils/lazyWithReload'
import { getErrorMessage } from '../../utils/errorHandling'
import { exportarGastosDelMes } from '../../utils/exportGastos'
import { mesDe } from '../../utils/gastos'
import type { Gasto, GrupoGasto, GuardarGastoPayload, RubroGasto } from '../../types/gastos'

const VistaGastos = lazyWithReload(() => import('../vistas/VistaGastos'))
const ModalGasto = lazyWithReload(() => import('../modals/ModalGasto'))
const ModalAnularGasto = lazyWithReload(() => import('../modals/ModalAnularGasto'))
const ModalRubrosGasto = lazyWithReload(() => import('../modals/ModalRubrosGasto'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

/** El mes de hoy en Tucumán, no en UTC: a la noche el día UTC ya es el de mañana. */
const mesActual = (): string =>
  mesDe(new Date().toLocaleDateString('en-CA', { timeZone: 'America/Argentina/Tucuman' }))

export default function GastosContainer(): React.ReactElement {
  const { isAdmin, user } = useAuthData()
  const notify = useNotification()
  const { sucursales, currentSucursalId, currentSucursalNombre } = useSucursal()

  const [mes, setMes] = useState<string>(mesActual)
  const [modalGastoAbierto, setModalGastoAbierto] = useState(false)
  const [gastoEditando, setGastoEditando] = useState<Gasto | null>(null)
  const [gastoAnulando, setGastoAnulando] = useState<Gasto | null>(null)
  const [rubrosAbierto, setRubrosAbierto] = useState(false)

  const { data: gastos = [], isLoading } = useGastosDelMesQuery(mes)
  const { data: rubros = [] } = useRubrosGastoQuery()
  const { data: vehiculos = [] } = useVehiculosQuery()
  const { data: sucursalesActivas = [] } = useSucursalesActivasQuery()
  const guardarGasto = useGuardarGastoMutation()
  const anularGasto = useAnularGastoMutation()
  const guardarRubro = useGuardarRubroGastoMutation()

  useResetOnSucursalChange(() => {
    setModalGastoAbierto(false)
    setGastoEditando(null)
    setGastoAnulando(null)
    setRubrosAbierto(false)
  })

  const sucursalActual = useMemo(
    () => ({ id: currentSucursalId ?? 0, nombre: currentSucursalNombre ?? '' }),
    [currentSucursalId, currentSucursalNombre],
  )
  const sucursalesUsuario = useMemo(
    () => sucursales.map(s => ({ id: s.id, nombre: s.nombre })),
    [sucursales],
  )
  // Quién puede tocar un compartido ajeno: el que tiene todas las sucursales activas.
  const tieneTodasLasSucursales =
    sucursalesActivas.length > 0 && sucursalesActivas.every(a => sucursalesUsuario.some(s => s.id === a.id))
  const rubrosActivos = useMemo(() => rubros.filter(r => r.activo), [rubros])

  const handleNuevo = useCallback(() => {
    setGastoEditando(null)
    setModalGastoAbierto(true)
  }, [])

  const handleEditar = useCallback((g: Gasto) => {
    setGastoEditando(g)
    setModalGastoAbierto(true)
  }, [])

  const cerrarModalGasto = useCallback(() => {
    setModalGastoAbierto(false)
    setGastoEditando(null)
  }, [])

  const handleGuardar = useCallback(async (payload: GuardarGastoPayload) => {
    try {
      await guardarGasto.mutateAsync(payload)
    } catch (err) {
      notify.error(getErrorMessage(err))
      // El modal también muestra el mensaje y se queda abierto.
      throw err
    }
    notify.success(payload.id ? 'Gasto actualizado' : 'Gasto registrado')
  }, [guardarGasto, notify])

  const handleAnular = useCallback(async (motivo: string) => {
    if (!gastoAnulando) return
    try {
      await anularGasto.mutateAsync({ id: gastoAnulando.id, motivo })
    } catch (err) {
      notify.error(getErrorMessage(err))
      throw err
    }
    notify.success('Gasto anulado')
  }, [anularGasto, gastoAnulando, notify])

  const handleCrearRubro = useCallback(
    (nombre: string, grupo: GrupoGasto): Promise<RubroGasto> => guardarRubro.mutateAsync({ nombre, grupo }),
    [guardarRubro],
  )

  const handleExportar = useCallback(async () => {
    try {
      await exportarGastosDelMes(gastos, mes, { sucursales: sucursalesActivas })
    } catch (err) {
      notify.error(getErrorMessage(err))
    }
  }, [gastos, mes, sucursalesActivas, notify])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaGastos
          mes={mes}
          onCambiarMes={setMes}
          gastos={gastos}
          rubros={rubros}
          vehiculos={vehiculos}
          loading={isLoading}
          usuarioId={user?.id ?? ''}
          esAdmin={isAdmin}
          tieneTodasLasSucursales={tieneTodasLasSucursales}
          sucursalActual={sucursalActual}
          onNuevoGasto={handleNuevo}
          onEditarGasto={handleEditar}
          onAnularGasto={setGastoAnulando}
          onAbrirRubros={isAdmin ? () => setRubrosAbierto(true) : undefined}
          onExportar={handleExportar}
        />
      </Suspense>

      {modalGastoAbierto && (
        <Suspense fallback={null}>
          <ModalGasto
            gasto={gastoEditando}
            rubros={rubrosActivos}
            vehiculos={vehiculos}
            sucursalActual={sucursalActual}
            sucursalesUsuario={sucursalesUsuario}
            sucursalesActivas={sucursalesActivas}
            esAdmin={isAdmin}
            usuarioId={user?.id}
            tieneTodasLasSucursales={tieneTodasLasSucursales}
            onCrearRubro={isAdmin ? handleCrearRubro : undefined}
            onSave={handleGuardar}
            onClose={cerrarModalGasto}
          />
        </Suspense>
      )}

      {gastoAnulando && (
        <Suspense fallback={null}>
          <ModalAnularGasto
            gasto={gastoAnulando}
            onConfirm={handleAnular}
            onClose={() => setGastoAnulando(null)}
          />
        </Suspense>
      )}

      {rubrosAbierto && isAdmin && (
        <Suspense fallback={null}>
          <ModalRubrosGasto
            rubros={rubros}
            onGuardar={input => guardarRubro.mutateAsync(input)}
            onClose={() => setRubrosAbierto(false)}
          />
        </Suspense>
      )}
    </>
  )
}
