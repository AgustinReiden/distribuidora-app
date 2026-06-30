import React from 'react'
import { X, Loader2 } from 'lucide-react'
import { moneyC } from './formato'
import { useAlertaDetalleQuery } from '../../../hooks/queries'

/** Muestra la lista concreta detrás de una alerta (clientes que deben, inactivos, etc.). */
export default function ModalAlertaDetalle({
  titulo,
  codigo,
  sucursalId,
  onClose,
}: {
  titulo: string
  codigo: string
  sucursalId: number | null
  onClose: () => void
}): React.ReactElement {
  const { data, isLoading, error } = useAlertaDetalleQuery(sucursalId, codigo)
  const items = data ?? []

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-md max-h-[80vh] flex flex-col" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700">
          <h3 className="text-base font-bold text-gray-900 dark:text-white">
            {titulo}{!isLoading && <span className="ml-2 text-sm font-normal text-gray-400">{items.length}</span>}
          </h3>
          <button onClick={onClose} className="text-gray-400 hover:text-gray-600" aria-label="Cerrar"><X className="w-5 h-5" /></button>
        </div>
        <div className="overflow-y-auto p-2">
          {isLoading ? (
            <div className="flex items-center justify-center py-10"><Loader2 className="w-6 h-6 animate-spin text-blue-600" /></div>
          ) : error ? (
            <p className="p-4 text-sm text-red-600 dark:text-red-400">{(error as Error).message}</p>
          ) : items.length === 0 ? (
            <p className="p-4 text-sm text-gray-500 dark:text-gray-400">Sin datos para mostrar.</p>
          ) : (
            <ul className="divide-y dark:divide-gray-700/60">
              {items.map((it, i) => (
                <li key={it.nombre + i} className="flex items-center justify-between gap-3 px-3 py-2">
                  <div className="min-w-0">
                    <div className="text-sm font-medium text-gray-800 dark:text-gray-100 truncate">{it.nombre}</div>
                    <div className="text-xs text-gray-500 dark:text-gray-400">{it.detalle}</div>
                  </div>
                  <div className="text-sm font-semibold tabular-nums text-gray-900 dark:text-white shrink-0">{moneyC(it.valor)}</div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  )
}
