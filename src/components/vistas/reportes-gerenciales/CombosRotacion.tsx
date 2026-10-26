/**
 * Rotación, conversión y combos rotos del reporte gerencial (#1193, parte B).
 * Los datos salen de `reporte_combos_rotacion` (mig 390).
 */
import React from 'react'
import { moneyC, pct, N } from './formato'
import { conversionCombo, variacionRotacion } from '../../../utils/combosReporte'
import type { ReporteCombosRotacion } from '../../../hooks/queries/useReporteGerencialQuery'

const th = 'px-3 py-2.5 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400'
const td = 'px-3 py-2.5 text-sm text-gray-700 dark:text-gray-200'
const U = new Intl.NumberFormat('es-AR', { maximumFractionDigits: 1 })

export default function CombosRotacion({ data }: { data: ReporteCombosRotacion }): React.ReactElement {
  const { rotos } = data
  return (
    <div className="space-y-5">
      <div>
        <h3 className="text-sm font-bold text-gray-900 dark:text-white mb-1">Rotación y conversión</h3>
        <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">
          Unidades por semana de cada componente durante la vigencia del combo, contra un período igual de antes.
          El producto a mover va destacado. Conversión = pedidos con el combo / pedidos con alguno de sus productos.
        </p>
        {data.combos.length === 0 && (
          <p className="text-sm text-gray-400">Ningún combo estuvo vigente en el período.</p>
        )}
        {data.combos.map(c => {
          const conv = conversionCombo(c.pedidos_con_combo, c.pedidos_con_producto)
          return (
            <div key={c.combo_id} className="mb-4 overflow-x-auto">
              <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1 mb-1">
                <span className="font-semibold text-gray-900 dark:text-white">{c.nombre}</span>
                <span className="text-xs text-gray-500">
                  vigencia {c.vigencia_desde} → {c.vigencia_hasta} ({N.format(c.dias)} días) · antes {c.previo_desde} → {c.previo_hasta}
                </span>
                <span className="text-xs font-medium text-blue-700 dark:text-blue-300">
                  Conversión {pct(conv)} ({N.format(c.pedidos_con_combo)} de {N.format(c.pedidos_con_producto)} pedidos)
                </span>
              </div>
              <table className="w-full">
                <thead><tr className="border-b dark:border-gray-700">
                  <th className={`${th} text-left`}>Componente</th>
                  <th className={`${th} text-right`}>Antes (u/sem)</th>
                  <th className={`${th} text-right`}>Durante (u/sem)</th>
                  <th className={`${th} text-right`}>Variación</th>
                </tr></thead>
                <tbody className="divide-y dark:divide-gray-700/60">
                  {c.productos.map(p => {
                    const v = variacionRotacion(p.por_semana_durante, p.por_semana_antes)
                    const color = v != null && v < 0 ? 'text-red-600 dark:text-red-400' : v != null && v > 0 ? 'text-emerald-600 dark:text-emerald-400' : ''
                    return (
                      <tr key={p.producto_id} className={p.es_a_mover ? 'bg-amber-50 dark:bg-amber-900/20' : ''}>
                        <td className={td}>
                          {p.producto}
                          {p.es_a_mover && (
                            <span className="ml-2 text-[10px] font-semibold uppercase px-1.5 py-0.5 rounded border border-amber-300 dark:border-amber-700 text-amber-700 dark:text-amber-300">a mover</span>
                          )}
                        </td>
                        <td className={`${td} text-right tabular-nums`}>{U.format(p.por_semana_antes)}</td>
                        <td className={`${td} text-right tabular-nums`}>{U.format(p.por_semana_durante)}</td>
                        <td className={`${td} text-right tabular-nums ${color}`}>
                          {v == null ? '—' : `${v > 0 ? '+' : ''}${pct(v)}`}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )
        })}
      </div>

      <div>
        <h3 className="text-sm font-bold text-gray-900 dark:text-white mb-1">Combos rotos por el cliente</h3>
        <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">
          Combos que el cliente rompió al rechazar parte de la entrega, y lo que el pedido pagó de más por quedar a precio sin combo.
        </p>
        {rotos.combos_rotos === 0 ? (
          <p className="text-sm text-gray-400">Ningún combo se rompió en el período.</p>
        ) : (
          <>
            <p className="text-sm text-gray-700 dark:text-gray-200 mb-2">
              <b>{N.format(rotos.combos_rotos)}</b> de {N.format(rotos.combos_armados)} combos rotos en {N.format(rotos.pedidos_afectados)} pedidos ·
              recargo recuperado <b>{moneyC(rotos.recargo_recuperado)}</b>
            </p>
            <div className="overflow-x-auto">
              <table className="w-full">
                <thead><tr className="border-b dark:border-gray-700">
                  <th className={`${th} text-left`}>Combo</th>
                  <th className={`${th} text-right`}>Armados</th>
                  <th className={`${th} text-right`}>Rotos</th>
                  <th className={`${th} text-right`}>Pedidos</th>
                  <th className={`${th} text-right`}>Recargo</th>
                </tr></thead>
                <tbody className="divide-y dark:divide-gray-700/60">
                  {rotos.por_combo.map(r => (
                    <tr key={r.combo_id}>
                      <td className={td}>{r.nombre}</td>
                      <td className={`${td} text-right tabular-nums`}>{N.format(r.armados)}</td>
                      <td className={`${td} text-right tabular-nums`}>{N.format(r.rotos)}</td>
                      <td className={`${td} text-right tabular-nums`}>{N.format(r.pedidos)}</td>
                      <td className={`${td} text-right tabular-nums`}>{moneyC(r.recargo)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}
      </div>
    </div>
  )
}
