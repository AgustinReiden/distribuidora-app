/**
 * VistaVehiculos — la flota de la sucursal (entrega 1 de gastos). Sólo admin:
 * da de alta, edita, da de baja y abre la ficha con los costos.
 */
import React from 'react'
import { Pencil, Plus, Truck } from 'lucide-react'
import PageHeader from '../layout/PageHeader'
import { Button } from '../ui/Button'
import Card from '../ui/Card'
import { Badge } from '../ui/Badge'
import { formatPrecio } from '../../utils/formatters'
import type { Vehiculo } from '../../types/gastos'

export interface VistaVehiculosProps {
  /** Activos e inactivos. */
  vehiculos: Vehiculo[]
  /** Lo que cada vehículo aporta al resultado del mes en curso, por id. */
  gastoDelMes: Record<number, number>
  loading: boolean
  sucursalActual: { id: number; nombre: string }
  onNuevoVehiculo: () => void
  onEditarVehiculo: (v: Vehiculo) => void
  onVerFicha: (v: Vehiculo) => void
}

export default function VistaVehiculos({
  vehiculos, gastoDelMes, loading, sucursalActual, onNuevoVehiculo, onEditarVehiculo, onVerFicha,
}: VistaVehiculosProps): React.ReactElement {
  const conteo = `${vehiculos.length} ${vehiculos.length === 1 ? 'VEHÍCULO' : 'VEHÍCULOS'}`

  return (
    <div className="space-y-6">
      <PageHeader
        titulo="Vehículos"
        crumbs={['ADMINISTRACIÓN', sucursalActual.nombre.toUpperCase(), conteo]}
        loading={loading}
        acciones={
          <Button type="button" variant="hero" size="md" onClick={onNuevoVehiculo}>
            <Plus className="w-4 h-4" aria-hidden="true" />
            Nuevo vehículo
          </Button>
        }
      />

      {loading ? (
        <p className="text-sm text-gray-500" role="status">Cargando vehículos…</p>
      ) : vehiculos.length === 0 ? (
        <Card variant="section">
          <p className="text-sm text-gray-500 dark:text-gray-400 text-center py-6">
            Todavía no hay vehículos cargados en {sucursalActual.nombre}.
          </p>
        </Card>
      ) : (
        <ul className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
          {vehiculos.map(v => (
            <Card as="li" variant="section" key={v.id} data-testid={`vehiculo-${v.id}`}>
              <div className="flex items-start justify-between gap-3">
                <div className="flex items-start gap-3 min-w-0">
                  <Truck className="w-5 h-5 mt-0.5 text-gray-400 shrink-0" aria-hidden="true" />
                  <div className="min-w-0">
                    <p className="font-mono font-semibold text-gray-800 dark:text-white tracking-wide">{v.patente}</p>
                    <p className="text-sm text-gray-600 dark:text-gray-300 truncate">{v.descripcion}</p>
                    {!v.activo && <Badge tone="neutral" className="mt-1">Inactivo</Badge>}
                  </div>
                </div>
                <Button
                  type="button" variant="ghost" size="sm" aria-label={`Editar vehículo ${v.patente}`}
                  onClick={() => onEditarVehiculo(v)}
                >
                  <Pencil className="w-4 h-4" aria-hidden="true" />
                </Button>
              </div>
              <div className="mt-3 flex items-end justify-between gap-3">
                <div>
                  <p className="text-xs text-gray-500 dark:text-gray-400">Gasto del mes</p>
                  <p className="text-lg font-bold text-gray-800 dark:text-white">{formatPrecio(gastoDelMes[v.id] ?? 0)}</p>
                </div>
                <Button type="button" variant="secondary" size="sm" onClick={() => onVerFicha(v)}>
                  Ver ficha
                </Button>
              </div>
            </Card>
          ))}
        </ul>
      )}
    </div>
  )
}
