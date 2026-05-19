/**
 * VistaTransferencias
 *
 * Lista de movimientos entre sucursales (salidas e ingresos) con detalle.
 * Paginada en server-side (50 filas por pagina) + filtro de fecha.
 */
import React from 'react'
import { ArrowRightLeft, Package, ArrowUpRight, ArrowDownLeft, ChevronLeft, ChevronRight, Calendar } from 'lucide-react'
import LoadingSpinner from '../layout/LoadingSpinner'
import { formatPrecio } from '../../utils/formatters'
import { TRANSFERENCIAS_PAGE_SIZE } from '../../hooks/queries/useTransferenciasQuery'
import type { TransferenciaDB } from '../../types'

interface VistaTransferenciasProps {
  transferencias: TransferenciaDB[]
  loading: boolean
  desde: string
  hasta: string
  pagina: number
  onCambiarDesde: (v: string) => void
  onCambiarHasta: (v: string) => void
  onCambiarPagina: (p: number) => void
  onNuevaSalida: () => void
  onNuevoIngreso: () => void
  onVerDetalle: (transferencia: TransferenciaDB) => void
}

function formatFecha(fecha: string): string {
  try {
    return new Date(fecha).toLocaleDateString('es-AR', {
      day: '2-digit',
      month: '2-digit',
      year: 'numeric',
    })
  } catch {
    return fecha
  }
}

export default function VistaTransferencias({
  transferencias,
  loading,
  desde,
  hasta,
  pagina,
  onCambiarDesde,
  onCambiarHasta,
  onCambiarPagina,
  onNuevaSalida,
  onNuevoIngreso,
  onVerDetalle,
}: VistaTransferenciasProps): React.ReactElement {
  // La paginacion es server-side por offset. Como la API no devuelve el total,
  // habilitamos "siguiente" mientras la pagina actual venga llena. Si vuelve
  // con menos de PAGE_SIZE elementos, asumimos que es la ultima.
  const puedeSiguiente = transferencias.length === TRANSFERENCIAS_PAGE_SIZE
  const puedeAnterior = pagina > 1
  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between flex-wrap gap-3">
        <div className="flex items-center gap-3">
          <ArrowRightLeft className="w-6 h-6 text-blue-600" />
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white">
            Movimiento entre Sucursales
          </h1>
        </div>
        <div className="flex gap-2">
          <button
            onClick={onNuevoIngreso}
            className="flex items-center gap-2 px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg font-medium transition-colors"
          >
            <ArrowDownLeft className="w-4 h-4" />
            Nuevo Ingreso
          </button>
          <button
            onClick={onNuevaSalida}
            className="flex items-center gap-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-medium transition-colors"
          >
            <ArrowUpRight className="w-4 h-4" />
            Nueva Salida
          </button>
        </div>
      </div>

      {/* Filtros de fecha */}
      <div className="flex flex-wrap items-end gap-3 bg-white dark:bg-gray-800 rounded-xl p-3 border dark:border-gray-700 shadow-sm">
        <div>
          <label className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1 flex items-center gap-1">
            <Calendar className="w-3 h-3" /> Desde
          </label>
          <input
            type="date"
            value={desde}
            onChange={e => onCambiarDesde(e.target.value)}
            className="px-3 py-1.5 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          />
        </div>
        <div>
          <label className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1 flex items-center gap-1">
            <Calendar className="w-3 h-3" /> Hasta
          </label>
          <input
            type="date"
            value={hasta}
            onChange={e => onCambiarHasta(e.target.value)}
            className="px-3 py-1.5 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          />
        </div>
        <p className="text-xs text-gray-500 dark:text-gray-400 ml-auto">
          Por defecto, ultimos 60 dias. Ampliar manualmente si necesitan historial.
        </p>
      </div>

      {/* Loading */}
      {loading && <LoadingSpinner text="Cargando movimientos..." />}

      {/* Empty state */}
      {!loading && transferencias.length === 0 && (
        <div className="flex flex-col items-center justify-center py-20 text-center">
          <div className="p-4 bg-gray-100 dark:bg-gray-700 rounded-full mb-4">
            <Package className="w-10 h-10 text-gray-400 dark:text-gray-500" />
          </div>
          <h3 className="text-lg font-medium text-gray-600 dark:text-gray-300 mb-1">
            No hay movimientos registrados
          </h3>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Registra una salida o ingreso de sucursal usando los botones de arriba.
          </p>
        </div>
      )}

      {/* Table */}
      {!loading && transferencias.length > 0 && (
        <div className="bg-white dark:bg-gray-800 rounded-xl shadow-sm border dark:border-gray-700 overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full">
              <thead>
                <tr className="bg-gray-50 dark:bg-gray-700/50 border-b dark:border-gray-700">
                  <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    Fecha
                  </th>
                  <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    Tipo
                  </th>
                  <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    Sucursal
                  </th>
                  <th className="text-right px-4 py-3 text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    Total Costo
                  </th>
                  <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider hidden md:table-cell">
                    Notas
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y dark:divide-gray-700">
                {transferencias.map(t => {
                  const esIngreso = t.tipo === 'ingreso'
                  return (
                    <tr
                      key={t.id}
                      onClick={() => onVerDetalle(t)}
                      className="hover:bg-gray-50 dark:hover:bg-gray-700/30 transition-colors cursor-pointer"
                    >
                      <td className="px-4 py-3 text-sm text-gray-800 dark:text-gray-200 whitespace-nowrap">
                        {formatFecha(t.fecha)}
                      </td>
                      <td className="px-4 py-3">
                        <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${
                          esIngreso
                            ? 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
                            : 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400'
                        }`}>
                          {esIngreso
                            ? <><ArrowDownLeft className="w-3 h-3" /> Ingreso</>
                            : <><ArrowUpRight className="w-3 h-3" /> Salida</>
                          }
                        </span>
                      </td>
                      <td className="px-4 py-3 text-sm font-medium text-gray-800 dark:text-white">
                        {t.sucursal?.nombre || 'Sin sucursal'}
                      </td>
                      <td className="px-4 py-3 text-sm font-medium text-gray-800 dark:text-white text-right whitespace-nowrap">
                        {formatPrecio(t.total_costo)}
                      </td>
                      <td className="px-4 py-3 text-sm text-gray-500 dark:text-gray-400 hidden md:table-cell max-w-xs truncate">
                        {t.notas || '-'}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>

          {/* Paginador */}
          <div className="flex items-center justify-between px-4 py-3 border-t dark:border-gray-700 text-sm">
            <p className="text-gray-500 dark:text-gray-400">
              Pagina {pagina}{' · '}{transferencias.length} mov.
            </p>
            <div className="flex gap-2">
              <button
                onClick={() => onCambiarPagina(pagina - 1)}
                disabled={!puedeAnterior}
                className="flex items-center gap-1 px-3 py-1.5 border rounded-lg dark:border-gray-600 disabled:opacity-40 disabled:cursor-not-allowed hover:bg-gray-50 dark:hover:bg-gray-700"
              >
                <ChevronLeft className="w-4 h-4" /> Anterior
              </button>
              <button
                onClick={() => onCambiarPagina(pagina + 1)}
                disabled={!puedeSiguiente}
                className="flex items-center gap-1 px-3 py-1.5 border rounded-lg dark:border-gray-600 disabled:opacity-40 disabled:cursor-not-allowed hover:bg-gray-50 dark:hover:bg-gray-700"
              >
                Siguiente <ChevronRight className="w-4 h-4" />
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
