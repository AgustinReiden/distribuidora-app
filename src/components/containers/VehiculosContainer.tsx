/**
 * VehiculosContainer
 *
 * Lista de la flota de la sucursal, alta y edición, y la ficha con el gasto,
 * las cargas de combustible y las lecturas de km. Sólo admin.
 */
import React, { Suspense, useCallback, useMemo, useState } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useGastosDelMesQuery,
  useGuardarVehiculoMutation,
  useRegistrarKmMutation,
  useVehiculoFichaQuery,
  useVehiculosQuery,
} from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import { useSucursal } from '../../contexts/SucursalContext'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'
import { lazyWithReload } from '../../utils/lazyWithReload'
import { cuotaDelMes, mesDe } from '../../utils/gastos'
import type { GuardarVehiculoInput } from '../../hooks/queries/useVehiculosQuery'
import type { Vehiculo } from '../../types/gastos'

const VistaVehiculos = lazyWithReload(() => import('../vistas/VistaVehiculos'))
const ModalVehiculo = lazyWithReload(() => import('../modals/ModalVehiculo'))
const ModalFichaVehiculo = lazyWithReload(() => import('../modals/ModalFichaVehiculo'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

/** El mes de hoy en Tucumán, no en UTC. */
const mesActual = (): string =>
  mesDe(new Date().toLocaleDateString('en-CA', { timeZone: 'America/Argentina/Tucuman' }))

/** La ficha pide sus datos recién cuando se abre: un componente propio cuida los hooks. */
function FichaVehiculo({ vehiculo, mes, onClose }: { vehiculo: Vehiculo; mes: string; onClose: () => void }) {
  const notify = useNotification()
  const { data, isLoading } = useVehiculoFichaQuery(vehiculo.id)
  const registrarKm = useRegistrarKmMutation()

  const handleRegistrarKm = useCallback(async (fecha: string, km: number) => {
    await registrarKm.mutateAsync({ vehiculoId: vehiculo.id, fecha, km })
    notify.success('Lectura de km registrada')
  }, [registrarKm, vehiculo.id, notify])

  return (
    <ModalFichaVehiculo
      vehiculo={vehiculo}
      gastos={data?.gastos ?? []}
      lecturas={data?.lecturas ?? []}
      loading={isLoading}
      mes={mes}
      onRegistrarKm={handleRegistrarKm}
      onClose={onClose}
    />
  )
}

export default function VehiculosContainer(): React.ReactElement {
  const notify = useNotification()
  const { currentSucursalId, currentSucursalNombre } = useSucursal()
  const mes = useMemo(() => mesActual(), [])

  const [modalAbierto, setModalAbierto] = useState(false)
  const [vehiculoEditando, setVehiculoEditando] = useState<Vehiculo | null>(null)
  const [fichaDe, setFichaDe] = useState<Vehiculo | null>(null)

  const { data: vehiculos = [], isLoading } = useVehiculosQuery({ incluirInactivos: true })
  const { data: gastosDelMes = [] } = useGastosDelMesQuery(mes)
  const guardarVehiculo = useGuardarVehiculoMutation()

  useResetOnSucursalChange(() => {
    setModalAbierto(false)
    setVehiculoEditando(null)
    setFichaDe(null)
  })

  const gastoDelMes = useMemo(() => {
    const porVehiculo: Record<number, number> = {}
    for (const g of gastosDelMes) {
      if (g.vehiculo_id == null) continue
      const cuota = cuotaDelMes(g, mes)
      if (cuota) porVehiculo[g.vehiculo_id] = Math.round(((porVehiculo[g.vehiculo_id] ?? 0) + cuota.monto) * 100) / 100
    }
    return porVehiculo
  }, [gastosDelMes, mes])

  const handleGuardar = useCallback(async (vehiculo: GuardarVehiculoInput) => {
    await guardarVehiculo.mutateAsync(vehiculo)
    notify.success(vehiculo.id ? 'Vehículo actualizado' : 'Vehículo creado')
  }, [guardarVehiculo, notify])

  const cerrarModal = useCallback(() => {
    setModalAbierto(false)
    setVehiculoEditando(null)
  }, [])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaVehiculos
          vehiculos={vehiculos}
          gastoDelMes={gastoDelMes}
          loading={isLoading}
          sucursalActual={{ id: currentSucursalId ?? 0, nombre: currentSucursalNombre ?? '' }}
          onNuevoVehiculo={() => { setVehiculoEditando(null); setModalAbierto(true) }}
          onEditarVehiculo={v => { setVehiculoEditando(v); setModalAbierto(true) }}
          onVerFicha={setFichaDe}
        />
      </Suspense>

      {modalAbierto && (
        <Suspense fallback={null}>
          <ModalVehiculo vehiculo={vehiculoEditando} onSave={handleGuardar} onClose={cerrarModal} />
        </Suspense>
      )}

      {fichaDe && (
        <Suspense fallback={null}>
          <FichaVehiculo vehiculo={fichaDe} mes={mes} onClose={() => setFichaDe(null)} />
        </Suspense>
      )}
    </>
  )
}
