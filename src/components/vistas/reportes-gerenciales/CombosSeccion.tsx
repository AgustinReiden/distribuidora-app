/**
 * Cuerpo de la sección "Combos" del reporte gerencial (#1193).
 *
 * El Card y el título viven en la vista, igual que en las demás secciones. Acá
 * van las tablas: combos con su detalle por producto, y la evolución mensual y
 * semanal. Todo sale de `reporte_combos` (mig 387).
 *
 * El descuento del combo es INFORMATIVO y no se resta de ningún margen: la venta
 * ya entró más barata.
 */
import React, { useMemo, useState } from 'react'
import { ChevronRight } from 'lucide-react'
import { Criterio } from '../../ui/Criterio'
import { Button } from '../../ui/Button'
import { moneyC, pct, N } from './formato'
import { ratio, serieDeCombos } from '../../../utils/combosReporte'
import type { ReporteCombos } from '../../../hooks/queries/useReporteGerencialQuery'

const th = 'px-3 py-2.5 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400'
const td = 'px-3 py-2.5 text-sm text-gray-700 dark:text-gray-200'
const neg = (x: number): string => (x < 0 ? 'text-red-600 dark:text-red-400' : '')

export default function CombosSeccion({ combos }: { combos: ReporteCombos }): React.ReactElement {
  const [abiertos, setAbiertos] = useState<Set<number>>(new Set())
  const [vista, setVista] = useState<'mensual' | 'semanal'>('mensual')
  const [comboSel, setComboSel] = useState<number | null>(null)

  const alternar = (id: number): void => setAbiertos(prev => {
    const s = new Set(prev)
    if (s.has(id)) s.delete(id); else s.add(id)
    return s
  })

  const serie = useMemo(
    () => serieDeCombos(vista === 'mensual' ? combos.mensual : combos.semanal, comboSel).reverse(),
    [combos.mensual, combos.semanal, vista, comboSel],
  )
  const k = combos.kpis

  return (
    <div className="space-y-5">
      <Criterio>
        Venta de las líneas de combo de pedidos <strong>entregados</strong>, por fecha del pedido. El <strong>descuento</strong> es lo que
        el cliente ahorró contra comprar suelto: es <strong>informativo</strong>, ya está adentro de la venta y no se resta de ningún margen.
        El margen es el real (ingreso real − costo). Un producto puede figurar bajo costo dentro del combo aunque el combo gane plata: mirá el margen del combo entero.
      </Criterio>

      <div className="overflow-x-auto">
        <table className="w-full">
          <thead><tr className="border-b dark:border-gray-700">
            <th className={`${th} text-left`}>Combo</th>
            <th className={`${th} text-right`}>Vendidos</th>
            <th className={`${th} text-right`}>Venta</th>
            <th className={`${th} text-right`}>Descuento</th>
            <th className={`${th} text-right`}>Costo</th>
            <th className={`${th} text-right`}>Margen</th>
            <th className={`${th} text-right`}>Margen %</th>
          </tr></thead>
          {combos.combos.map(c => {
            const abierto = abiertos.has(c.combo_id)
            return (
              <tbody key={c.combo_id} className="divide-y dark:divide-gray-700/60">
                <tr className="bg-gray-50 dark:bg-gray-700/40">
                  <td className={`${td} font-semibold text-gray-900 dark:text-white`}>
                    <button
                      type="button"
                      onClick={() => alternar(c.combo_id)}
                      aria-expanded={abierto}
                      aria-label={`${abierto ? 'Ocultar' : 'Ver'} los productos de ${c.nombre}`}
                      className="inline-flex items-center gap-1.5 text-left hover:underline"
                    >
                      <ChevronRight className={`w-4 h-4 shrink-0 transition-transform ${abierto ? 'rotate-90' : ''}`} aria-hidden="true" />
                      {c.nombre}
                    </button>
                  </td>
                  <td className={`${td} text-right tabular-nums`}>{N.format(c.combos_vendidos)}</td>
                  <td className={`${td} text-right tabular-nums`}>{moneyC(c.venta)}</td>
                  <td className={`${td} text-right tabular-nums`}>{moneyC(c.descuento)}</td>
                  <td className={`${td} text-right tabular-nums`}>{moneyC(c.costo)}</td>
                  <td className={`${td} text-right tabular-nums font-semibold ${neg(c.margen)}`}>{moneyC(c.margen)}</td>
                  <td className={`${td} text-right tabular-nums ${neg(c.margen)}`}>{pct(ratio(c.margen, c.ingreso_real))}</td>
                </tr>
                {abierto && c.productos.map(p => (
                  <tr key={p.producto_id}>
                    <td className={`${td} pl-9`}>
                      {p.producto}
                      <span className="ml-2 text-[11px] text-gray-400">
                        {N.format(p.unidades)} u. · {moneyC(ratio(p.venta, p.unidades))} c/u en el combo
                      </span>
                    </td>
                    <td className={td}></td>
                    <td className={`${td} text-right tabular-nums`}>{moneyC(p.venta)}</td>
                    <td className={`${td} text-right tabular-nums`}>{moneyC(p.descuento)}</td>
                    <td className={`${td} text-right tabular-nums`}>{moneyC(p.costo)}</td>
                    <td className={`${td} text-right tabular-nums ${neg(p.margen)}`}>{moneyC(p.margen)}</td>
                    <td className={`${td} text-right tabular-nums ${neg(p.margen)}`}>
                      {pct(ratio(p.margen, p.venta))}
                    </td>
                  </tr>
                ))}
              </tbody>
            )
          })}
          <tfoot>
            <tr className="border-t-2 dark:border-gray-600 font-bold">
              <td className={`${td} text-gray-900 dark:text-white`}>Total</td>
              <td className={`${td} text-right tabular-nums`}>{N.format(k.combos_vendidos)}</td>
              <td className={`${td} text-right tabular-nums`}>{moneyC(k.venta)}</td>
              <td className={`${td} text-right tabular-nums`}>{moneyC(k.descuento)}</td>
              <td className={`${td} text-right tabular-nums`}>{moneyC(k.costo)}</td>
              <td className={`${td} text-right tabular-nums ${neg(k.margen)}`}>{moneyC(k.margen)}</td>
              <td className={`${td} text-right tabular-nums ${neg(k.margen)}`}>{pct(ratio(k.margen, k.ingreso_real))}</td>
            </tr>
          </tfoot>
        </table>
      </div>

      <div>
        <div className="flex flex-wrap items-center gap-3 mb-2">
          <h3 className="text-sm font-bold text-gray-900 dark:text-white">Evolución</h3>
          <div className="flex items-center bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg p-0.5">
            {(['mensual', 'semanal'] as const).map(v => (
              <Button
                key={v}
                type="button"
                size="sm"
                variant={vista === v ? 'primary' : 'ghost'}
                onClick={() => setVista(v)}
                aria-pressed={vista === v}
                className="h-7 px-2.5 text-xs"
              >
                {v === 'mensual' ? 'Por mes' : 'Por semana'}
              </Button>
            ))}
          </div>
          <select
            value={comboSel == null ? '' : String(comboSel)}
            onChange={e => setComboSel(e.target.value === '' ? null : Number(e.target.value))}
            aria-label="Combo de la evolución"
            className="text-xs font-medium bg-white dark:bg-gray-700 border dark:border-gray-600 rounded px-2 py-1 text-gray-700 dark:text-gray-200"
          >
            <option value="">Todos los combos</option>
            {combos.combos.map(c => <option key={c.combo_id} value={c.combo_id}>{c.nombre}</option>)}
          </select>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full">
            <thead><tr className="border-b dark:border-gray-700">
              <th className={`${th} text-left`}>{vista === 'mensual' ? 'Mes' : 'Semana del'}</th>
              <th className={`${th} text-right`}>Vendidos</th>
              <th className={`${th} text-right`}>Venta</th>
              <th className={`${th} text-right`}>Descuento</th>
              <th className={`${th} text-right`}>Margen</th>
            </tr></thead>
            <tbody className="divide-y dark:divide-gray-700/60">
              {serie.map(p => (
                <tr key={p.periodo}>
                  <td className={`${td} font-medium`}>{p.periodo}</td>
                  <td className={`${td} text-right tabular-nums`}>{N.format(p.combos)}</td>
                  <td className={`${td} text-right tabular-nums`}>{moneyC(p.venta)}</td>
                  <td className={`${td} text-right tabular-nums`}>{moneyC(p.descuento)}</td>
                  <td className={`${td} text-right tabular-nums ${neg(p.margen)}`}>{moneyC(p.margen)}</td>
                </tr>
              ))}
              {serie.length === 0 && (
                <tr><td colSpan={5} className={`${td} text-center text-gray-400`}>Sin ventas de combos en el período.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
