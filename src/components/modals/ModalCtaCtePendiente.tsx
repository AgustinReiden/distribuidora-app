/**
 * ModalCtaCtePendiente — detalle y total de los pedidos ENTREGADOS que quedaron
 * pendientes de cobro (cuenta corriente).
 *
 * Se abre desde la pantalla de Rendiciones y arranca con el MISMO rango de
 * fechas que se esta mirando ahi, para poder cuadrar "entregue X / cobre Y /
 * quedo Z en cta cte" sobre el mismo periodo. El rango filtra por FECHA DE
 * ENTREGA (el dia en que se genero la deuda), no por fecha de pago.
 *
 * Datos: RPC `obtener_pedidos_ctacte_pendientes` (mig 138), una fila por pedido.
 */
import { memo, useCallback, useEffect, useMemo, useState } from 'react'
import { Download, Loader2, Users, FileText } from 'lucide-react'
import ModalBase from './ModalBase'
import { supabase } from '../../hooks/supabase/base'

export interface CtaCtePendienteRow {
  pedido_id: number
  fecha_pedido: string
  fecha_entrega: string
  dias: number
  cliente_id: number
  cliente_nombre: string
  transportista_nombre: string
  total: number
  cobrado: number
  saldo: number
  estado_pago: string
}

export interface ModalCtaCtePendienteProps {
  fechaDesde: string
  fechaHasta: string
  /** Transportista del filtro de la vista ('' = todos) */
  transportistaId?: string
  onClose: () => void
}

function formatMoney(value: number | undefined | null): string {
  return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(value || 0)
}

function formatFechaCorta(fechaISO: string | null): string {
  if (!fechaISO) return '—'
  const [y, m, d] = fechaISO.split('-')
  return `${d}/${m}/${y}`
}

function ModalCtaCtePendiente({
  fechaDesde,
  fechaHasta,
  transportistaId,
  onClose
}: ModalCtaCtePendienteProps) {
  const [filas, setFilas] = useState<CtaCtePendienteRow[]>([])
  const [loading, setLoading] = useState(true)
  const [exportando, setExportando] = useState(false)
  /** false = solo el rango de la rendicion · true = toda la deuda viva */
  const [verTodo, setVerTodo] = useState(false)

  useEffect(() => {
    let cancelado = false
    setLoading(true)
    void (async () => {
      const { data, error } = await supabase.rpc('obtener_pedidos_ctacte_pendientes', {
        p_desde: verTodo ? null : fechaDesde,
        p_hasta: verTodo ? null : fechaHasta,
        p_transportista_id: transportistaId || null
      })
      if (cancelado) return
      if (error) {
        setFilas([])
      } else {
        setFilas((data || []).map((r: Record<string, unknown>) => ({
          pedido_id: Number(r.pedido_id),
          fecha_pedido: String(r.fecha_pedido ?? ''),
          fecha_entrega: String(r.fecha_entrega ?? ''),
          dias: Number(r.dias) || 0,
          cliente_id: Number(r.cliente_id),
          cliente_nombre: String(r.cliente_nombre ?? 'Cliente'),
          transportista_nombre: String(r.transportista_nombre ?? 'Sin asignar'),
          total: Number(r.total) || 0,
          cobrado: Number(r.cobrado) || 0,
          saldo: Number(r.saldo) || 0,
          estado_pago: String(r.estado_pago ?? 'pendiente')
        })))
      }
      setLoading(false)
    })()
    return () => { cancelado = true }
  }, [fechaDesde, fechaHasta, transportistaId, verTodo])

  const totales = useMemo(() => ({
    pedidos: filas.length,
    clientes: new Set(filas.map(f => f.cliente_id)).size,
    total: filas.reduce((a, f) => a + f.total, 0),
    cobrado: filas.reduce((a, f) => a + f.cobrado, 0),
    saldo: filas.reduce((a, f) => a + f.saldo, 0)
  }), [filas])

  const handleExportar = useCallback(async () => {
    if (filas.length === 0) return
    setExportando(true)
    try {
      const data = filas.map(f => ({
        Cliente: f.cliente_nombre,
        Pedido: f.pedido_id,
        'Fecha pedido': formatFechaCorta(f.fecha_pedido),
        'Fecha entrega': formatFechaCorta(f.fecha_entrega),
        Días: f.dias,
        Transportista: f.transportista_nombre,
        Total: f.total,
        Cobrado: f.cobrado,
        Saldo: f.saldo,
        Estado: f.estado_pago
      }))
      const { createMultiSheetExcel } = await import('../../utils/excel')
      const sufijo = verTodo ? 'todo' : `${fechaDesde}_a_${fechaHasta}`
      await createMultiSheetExcel(
        [{ name: 'Cta Cte pendiente', data, columnWidths: [28, 9, 13, 13, 7, 20, 14, 14, 14, 11] }],
        `ctacte-pendiente-${sufijo}`
      )
    } finally {
      setExportando(false)
    }
  }, [filas, verTodo, fechaDesde, fechaHasta])

  return (
    <ModalBase
      title="Cuenta corriente pendiente"
      description="Pedidos entregados que todavía no se cobraron"
      onClose={onClose}
      maxWidth="max-w-5xl"
    >
      <div className="space-y-4">
        {/* Contexto del rango + toggle */}
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-sm text-gray-600 dark:text-gray-400">
            {verTodo
              ? 'Toda la deuda viva (sin filtro de fechas)'
              : <>Entregas del <strong>{formatFechaCorta(fechaDesde)}</strong> al <strong>{formatFechaCorta(fechaHasta)}</strong></>}
          </p>
          <label className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-300 cursor-pointer">
            <input
              type="checkbox"
              checked={verTodo}
              onChange={e => setVerTodo(e.target.checked)}
              className="rounded"
            />
            Ver toda la deuda
          </label>
        </div>

        {/* Totales */}
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3">
            <p className="text-xs text-gray-500 flex items-center gap-1"><FileText className="w-3 h-3" />Pedidos</p>
            <p className="text-xl font-bold text-gray-800 dark:text-white">{totales.pedidos}</p>
          </div>
          <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3">
            <p className="text-xs text-gray-500 flex items-center gap-1"><Users className="w-3 h-3" />Clientes</p>
            <p className="text-xl font-bold text-gray-800 dark:text-white">{totales.clientes}</p>
          </div>
          <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3">
            <p className="text-xs text-gray-500">Entregado</p>
            <p className="text-lg font-bold text-gray-800 dark:text-white">{formatMoney(totales.total)}</p>
            <p className="text-xs text-gray-500 mt-0.5">Cobrado: {formatMoney(totales.cobrado)}</p>
          </div>
          <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-3">
            <p className="text-xs text-blue-700 dark:text-blue-300">Saldo en cta cte</p>
            <p className="text-lg font-bold text-blue-700 dark:text-blue-300">{formatMoney(totales.saldo)}</p>
          </div>
        </div>

        <div className="flex justify-end">
          <button
            onClick={() => { void handleExportar() }}
            disabled={exportando || loading || filas.length === 0}
            className="text-sm inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-50"
          >
            <Download className="w-4 h-4" />
            {exportando ? 'Exportando…' : 'Exportar Excel'}
          </button>
        </div>

        {/* Detalle */}
        {loading ? (
          <div className="flex items-center justify-center py-10 text-gray-500 gap-2">
            <Loader2 className="w-5 h-5 animate-spin" />
            Cargando…
          </div>
        ) : filas.length === 0 ? (
          <p className="text-center py-10 text-gray-500">
            No hay pedidos entregados pendientes de cobro en este período.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-gray-500 dark:text-gray-400 border-b border-gray-200 dark:border-gray-700">
                  <th className="py-2 pr-2 font-medium">Cliente</th>
                  <th className="py-2 px-2 font-medium">Pedido</th>
                  <th className="py-2 px-2 font-medium">Entrega</th>
                  <th className="py-2 px-2 font-medium text-right">Días</th>
                  <th className="py-2 px-2 font-medium text-right">Total</th>
                  <th className="py-2 px-2 font-medium text-right">Cobrado</th>
                  <th className="py-2 pl-2 font-medium text-right">Saldo</th>
                </tr>
              </thead>
              <tbody>
                {filas.map(f => (
                  <tr key={f.pedido_id} className="border-b border-gray-100 dark:border-gray-700/50">
                    <td className="py-2 pr-2 text-gray-800 dark:text-gray-200">
                      {f.cliente_nombre}
                      {f.estado_pago === 'parcial' && (
                        <span className="ml-1.5 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
                          parcial
                        </span>
                      )}
                    </td>
                    <td className="py-2 px-2 text-gray-500">#{f.pedido_id}</td>
                    <td className="py-2 px-2 text-gray-500">{formatFechaCorta(f.fecha_entrega)}</td>
                    <td className="py-2 px-2 text-right text-gray-500">{f.dias}</td>
                    <td className="py-2 px-2 text-right text-gray-700 dark:text-gray-300">{formatMoney(f.total)}</td>
                    <td className="py-2 px-2 text-right text-emerald-600 dark:text-emerald-400">
                      {f.cobrado > 0 ? formatMoney(f.cobrado) : '—'}
                    </td>
                    <td className="py-2 pl-2 text-right font-semibold text-blue-700 dark:text-blue-300">{formatMoney(f.saldo)}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr className="border-t-2 border-gray-300 dark:border-gray-600">
                  <td colSpan={4} className="py-2 pr-2 font-semibold text-gray-700 dark:text-gray-200">
                    Total ({totales.pedidos} pedido{totales.pedidos !== 1 ? 's' : ''})
                  </td>
                  <td className="py-2 px-2 text-right font-semibold text-gray-700 dark:text-gray-200">{formatMoney(totales.total)}</td>
                  <td className="py-2 px-2 text-right font-semibold text-emerald-600 dark:text-emerald-400">{formatMoney(totales.cobrado)}</td>
                  <td className="py-2 pl-2 text-right font-bold text-blue-700 dark:text-blue-300">{formatMoney(totales.saldo)}</td>
                </tr>
              </tfoot>
            </table>
          </div>
        )}
      </div>
    </ModalBase>
  )
}

export default memo(ModalCtaCtePendiente)
