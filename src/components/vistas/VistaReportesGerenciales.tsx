import React, { useState, useMemo, useEffect } from 'react'
import {
  Loader2, TrendingUp, Percent, AlertTriangle, FileText, Building2, CalendarRange, ChevronDown, Target,
} from 'lucide-react'
import ReactMarkdown from 'react-markdown'
import NumberInput from '../ui/NumberInput'
import { money, moneyC, pct, N, rolLabel } from './reportes-gerenciales/formato'
import {
  EvolucionChart, DiarioChart, VendedoresChart, CategoriasChart, WaterfallChart, CobranzaDonut,
} from './reportes-gerenciales/charts'
import Sparkline from './reportes-gerenciales/Sparkline'
import Alertas from './reportes-gerenciales/Alertas'
import ModalMetas from './reportes-gerenciales/ModalMetas'
import ModalAlertaDetalle from './reportes-gerenciales/ModalAlertaDetalle'
import type { ReporteGerencial, AnalisisMensual, MetasGerenciales, Alerta } from '../../hooks/queries'

// Alertas cuyo detalle es una LISTA (modal). El resto hace scroll a su sección.
const ALERTA_CON_LISTA = new Set(['cobranza_vencida', 'clientes_inactivos', 'productos_sin_costo'])

export interface PeriodoOpt {
  key: string
  label: string
  desde: string
  hasta: string
  esMes: boolean
  periodoMes: string | null // YYYY-MM-01 si es un mes, para el análisis
  parcial: boolean
}

export interface SucursalOpt {
  id: number | null // null = red consolidada
  nombre: string
}

export interface VistaReportesGerencialesProps {
  reporte: ReporteGerencial | undefined
  loading: boolean
  error: string | null
  sucursalSel: number | null
  periodoSel: PeriodoOpt
  opcionesSucursal: SucursalOpt[]
  opcionesPeriodo: PeriodoOpt[]
  onSucursal: (id: number | null) => void
  onPeriodo: (p: PeriodoOpt) => void
  onRango: (desde: string, hasta: string) => void
  incluirNoEntregados: boolean
  onIncluirNoEntregados: (v: boolean) => void
  comparar: boolean
  onComparar: (v: boolean) => void
  metas: MetasGerenciales | null
  metasEditable: boolean
  onGuardarMeta: (venta: number | null, margenNeto: number | null) => void
  guardandoMeta: boolean
  analisis: AnalisisMensual | null
}

// ---- helpers de UI -------------------------------------------------------
function Card({ children, className = '', id }: { children: React.ReactNode; className?: string; id?: string }): React.ReactElement {
  return (
    <div id={id} className={`bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-xl shadow-sm ${className}`}>
      {children}
    </div>
  )
}

function KpiCard({ label, value, sub, accent, delta }: { label: string; value: string; sub?: React.ReactNode; accent: string; delta?: React.ReactNode }): React.ReactElement {
  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-xl shadow-sm p-4 relative overflow-hidden">
      <div className="absolute left-0 top-0 bottom-0 w-1" style={{ background: accent }} />
      <div className="text-[11px] font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400 pl-1">{label}</div>
      <div className="text-2xl font-bold text-gray-900 dark:text-white mt-1.5 pl-1">{value}</div>
      {delta && <div className="mt-0.5 pl-1">{delta}</div>}
      {sub && <div className="text-xs text-gray-500 dark:text-gray-400 mt-0.5 pl-1">{sub}</div>}
    </div>
  )
}

/** Variación vs período anterior. invert=true ⇒ subir es malo (costos, mermas). */
function Delta({ cur, prev, invert = false }: { cur: number; prev: number | null | undefined; invert?: boolean }): React.ReactElement | null {
  if (prev == null || !isFinite(prev) || prev === 0) return null
  const d = cur - prev
  const ratio = d / Math.abs(prev)
  const flat = Math.abs(ratio) < 0.0005
  const good = invert ? d < 0 : d > 0
  const color = flat ? 'text-gray-400' : good ? 'text-emerald-600 dark:text-emerald-400' : 'text-red-600 dark:text-red-400'
  const arrow = flat ? '→' : d > 0 ? '▲' : '▼'
  return (
    <span className={`text-[11px] font-semibold ${color}`}>
      {arrow} {pct(Math.abs(ratio))} <span className="font-normal text-gray-400">vs ant.</span>
    </span>
  )
}

/** Semáforo de cumplimiento vs meta. factor prorratea la meta por días del mes en curso. */
function Semaforo({ cur, meta, factor }: { cur: number; meta: number | null | undefined; factor: number }): React.ReactElement | null {
  if (meta == null || meta <= 0) return null
  const objetivo = meta * factor
  const cumpl = objetivo > 0 ? cur / objetivo : 0
  const color = cumpl >= 1 ? 'text-emerald-600 dark:text-emerald-400' : cumpl >= 0.85 ? 'text-amber-600 dark:text-amber-400' : 'text-red-600 dark:text-red-400'
  const dot = cumpl >= 1 ? 'bg-emerald-500' : cumpl >= 0.85 ? 'bg-amber-500' : 'bg-red-500'
  return (
    <span className={`inline-flex items-center gap-1 text-[11px] font-semibold ${color}`} title={factor < 1 ? 'Meta prorrateada por días transcurridos' : 'Meta del mes'}>
      <span className={`w-2 h-2 rounded-full ${dot}`} />{pct(cumpl)} de la meta
    </span>
  )
}

function SectionTitle({ icon: Icon, title, hint, right }: { icon: React.ElementType; title: string; hint?: string; right?: React.ReactNode }): React.ReactElement {
  return (
    <div className="flex items-start justify-between gap-3 mb-4">
      <div className="flex items-center gap-2.5">
        <Icon className="w-5 h-5 text-blue-600 dark:text-blue-400 shrink-0" />
        <div>
          <h2 className="text-lg font-bold text-gray-900 dark:text-white leading-tight">{title}</h2>
          {hint && <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">{hint}</p>}
        </div>
      </div>
      {right}
    </div>
  )
}

const th = 'px-3 py-2.5 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400'
const td = 'px-3 py-2.5 text-sm text-gray-700 dark:text-gray-200'
const ACCENTS = { blue: '#2563eb', emerald: '#059669', amber: '#d97706', violet: '#7c3aed', red: '#dc2626', cyan: '#0891b2', slate: '#64748b' }

export default function VistaReportesGerenciales({
  reporte, loading, error, sucursalSel, periodoSel, opcionesSucursal, opcionesPeriodo,
  onSucursal, onPeriodo, onRango, incluirNoEntregados, onIncluirNoEntregados,
  comparar, onComparar, metas, metasEditable, onGuardarMeta, guardandoMeta, analisis,
}: VistaReportesGerencialesProps): React.ReactElement {
  const [comPct, setComPct] = useState(2)
  const [comBase, setComBase] = useState<'nc' | 'ent'>('nc')
  const [detalleAbierto, setDetalleAbierto] = useState(false)
  const [showMetas, setShowMetas] = useState(false)

  // Prorrateo de la meta: en un mes en curso compara contra la parte transcurrida.
  const metaFactor = useMemo(() => {
    if (!periodoSel.esMes || !periodoSel.periodoMes) return 1
    const [yy, mm] = periodoSel.periodoMes.split('-').map(Number)
    const diasMes = new Date(yy, mm, 0).getDate()
    if (!periodoSel.parcial) return 1
    const diaHasta = Number(periodoSel.hasta.split('-')[2])
    return Math.min(Math.max(diaHasta, 1) / diasMes, 1)
  }, [periodoSel.esMes, periodoSel.periodoMes, periodoSel.parcial, periodoSel.hasta])

  const metasOn = periodoSel.esMes && !!metas && (metas.venta != null || metas.margen_neto != null)

  const [alertaDetalle, setAlertaDetalle] = useState<Alerta | null>(null)

  const irASeccion = (seccion: string): void => {
    setDetalleAbierto(true)
    setTimeout(() => document.getElementById(`sec-${seccion}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 80)
  }

  // Click en una alerta: si tiene lista (clientes que deben, inactivos…) abre un
  // modal con esa lista; si no, baja a la sección relacionada.
  const onAlerta = (a: Alerta): void => {
    if (ALERTA_CON_LISTA.has(a.codigo)) setAlertaDetalle(a)
    else irASeccion(a.seccion)
  }

  useEffect(() => {
    if (reporte?.kpis?.comision_pct_default) setComPct(reporte.kpis.comision_pct_default)
  }, [reporte?.kpis?.comision_pct_default])

  const k = reporte?.kpis
  const derived = useMemo(() => {
    if (!k) return null
    const comBaseTotal = comBase === 'nc' ? k.base_comision : k.venta
    const comision = comBaseTotal * comPct / 100
    const contrib = k.margen_neto - k.mermas - comision
    return { comision, contrib }
  }, [k, comPct, comBase])

  // Período anterior (lo calcula el RPC y viene en reporte.comparativo).
  const kp = comparar ? (reporte?.comparativo ?? null) : null
  const cmp = !!kp
  const derivedPrev = useMemo(() => {
    if (!kp) return null
    const base = comBase === 'nc' ? kp.base_comision : kp.venta
    const comision = base * comPct / 100
    return { comision, contrib: kp.margen_neto - kp.mermas - comision }
  }, [kp, comPct, comBase])

  return (
    <div className="space-y-5">
      {/* Header + selectores */}
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Reportes Gerenciales</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            {reporte ? `${reporte.meta.sucursal_nombre} · ${periodoSel.label}` : 'Cargando…'}
            <span className="font-medium"> · {incluirNoEntregados ? 'Todos los pedidos' : 'Ventas entregadas'}</span>
            {cmp && reporte?.comparativo && <span className="text-gray-400"> · vs {reporte.comparativo.desde} → {reporte.comparativo.hasta}</span>}
            {periodoSel.parcial && <span className="text-amber-600 dark:text-amber-400 font-medium"> · período en curso (parcial)</span>}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {/* Toggle: ventas entregadas vs todos los pedidos (pendientes/en camino/entregados) */}
          <div className="flex items-center bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg p-0.5 shadow-sm">
            {([['Entregadas', false], ['Todos', true]] as const).map(([lbl, val]) => (
              <button
                key={lbl}
                type="button"
                onClick={() => onIncluirNoEntregados(val)}
                title={val ? 'Incluye pendientes, en camino (asignados) y entregados' : 'Solo ventas efectivamente entregadas'}
                className={`px-2.5 py-1 text-xs font-semibold rounded-md transition-colors ${incluirNoEntregados === val ? 'bg-blue-600 text-white' : 'text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700'}`}
              >
                {lbl}
              </button>
            ))}
          </div>
          <button
            type="button"
            onClick={() => onComparar(!comparar)}
            title="Comparar contra el período anterior de igual duración"
            className={`px-2.5 py-1.5 text-xs font-semibold rounded-lg border shadow-sm transition-colors ${comparar ? 'bg-blue-600 text-white border-blue-600' : 'bg-white dark:bg-gray-800 text-gray-600 dark:text-gray-300 border-gray-200 dark:border-gray-700 hover:bg-gray-100 dark:hover:bg-gray-700'}`}
          >
            Comparar
          </button>
          {metasEditable && (
            <button
              type="button"
              onClick={() => setShowMetas(true)}
              title="Cargar las metas (objetivos) del mes"
              className="flex items-center gap-1 px-2.5 py-1.5 text-xs font-semibold rounded-lg border shadow-sm bg-white dark:bg-gray-800 text-gray-600 dark:text-gray-300 border-gray-200 dark:border-gray-700 hover:bg-gray-100 dark:hover:bg-gray-700"
            >
              <Target className="w-3.5 h-3.5" /> Metas
            </button>
          )}
          <div className="flex items-center gap-1.5 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg px-2.5 py-1.5 shadow-sm">
            <Building2 className="w-4 h-4 text-gray-400" />
            <select
              value={String(sucursalSel ?? 'red')}
              onChange={(e) => onSucursal(e.target.value === 'red' ? null : Number(e.target.value))}
              className="bg-transparent text-sm font-medium text-gray-800 dark:text-gray-100 focus:outline-none"
            >
              {opcionesSucursal.map(s => (
                <option key={String(s.id ?? 'red')} value={String(s.id ?? 'red')}>{s.nombre}</option>
              ))}
            </select>
          </div>
          <div className="flex items-center gap-1.5 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg px-2.5 py-1.5 shadow-sm">
            <CalendarRange className="w-4 h-4 text-gray-400" />
            <select
              value={periodoSel.key}
              onChange={(e) => { const p = opcionesPeriodo.find(o => o.key === e.target.value); if (p) onPeriodo(p) }}
              className="bg-transparent text-sm font-medium text-gray-800 dark:text-gray-100 focus:outline-none"
            >
              {opcionesPeriodo.map(p => <option key={p.key} value={p.key}>{p.key === 'custom' ? 'Personalizado…' : p.label}</option>)}
            </select>
          </div>
          {/* Rango personalizado: date pickers desde/hasta */}
          {periodoSel.key === 'custom' && (
            <div className="flex items-center gap-1.5 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg px-2.5 py-1.5 shadow-sm">
              <input
                type="date"
                value={periodoSel.desde}
                max={periodoSel.hasta || undefined}
                onChange={(e) => onRango(e.target.value, periodoSel.hasta)}
                className="bg-transparent text-sm text-gray-800 dark:text-gray-100 focus:outline-none"
                aria-label="Desde"
              />
              <span className="text-gray-400 text-xs">→</span>
              <input
                type="date"
                value={periodoSel.hasta}
                min={periodoSel.desde || undefined}
                onChange={(e) => onRango(periodoSel.desde, e.target.value)}
                className="bg-transparent text-sm text-gray-800 dark:text-gray-100 focus:outline-none"
                aria-label="Hasta"
              />
            </div>
          )}
        </div>
      </div>

      {error && (
        <Card className="p-5 border-red-200 dark:border-red-900">
          <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
        </Card>
      )}

      {loading || !reporte || !k || !derived ? (
        <div className="flex items-center justify-center py-24">
          <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
        </div>
      ) : (
        <>
          {/* KPIs */}
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            <KpiCard label={incluirNoEntregados ? 'Venta (todos)' : 'Venta entregada'} value={moneyC(k.venta)} sub={`${N.format(k.pedidos)} pedidos`} accent={ACCENTS.blue}
              delta={<div className="space-y-1">
                <div className="flex items-center justify-between gap-2">{cmp ? <Delta cur={k.venta} prev={kp!.venta} /> : <span />}<Sparkline data={(reporte.serie_diaria ?? []).map((s) => Number(s[1]))} /></div>
                {metasOn && metas?.venta != null && <Semaforo cur={k.venta} meta={metas.venta} factor={metaFactor} />}
              </div>} />
            <KpiCard label="Margen comercial" value={moneyC(k.margen_comercial)} sub={<><b>{pct(k.margen_comercial / k.venta)}</b> antes de bonif.</>} accent={ACCENTS.cyan}
              delta={cmp ? <Delta cur={k.margen_comercial} prev={kp!.margen_comercial} /> : undefined} />
            <KpiCard label="Bonificaciones" value={moneyC(k.bonif)} sub={<><b>{pct(k.bonif / k.venta)}</b> de la venta</>} accent={ACCENTS.amber}
              delta={cmp ? <Delta cur={k.bonif} prev={kp!.bonif} invert /> : undefined} />
            <KpiCard label="Margen neto" value={moneyC(k.margen_neto)} sub={<><b>{pct(k.margen_neto / k.venta)}</b> post bonif.</>} accent={ACCENTS.violet}
              delta={<div className="space-y-1">
                {cmp && <Delta cur={k.margen_neto} prev={kp!.margen_neto} />}
                {metasOn && metas?.margen_neto != null && <Semaforo cur={k.margen_neto} meta={metas.margen_neto} factor={metaFactor} />}
              </div>} />
            <KpiCard label={`Comisión ${String(comPct).replace('.', ',')}%`} value={moneyC(derived.comision)} sub={`base ${comBase === 'nc' ? 'no cancelado' : 'entregado'}`} accent={ACCENTS.slate}
              delta={cmp && derivedPrev ? <Delta cur={derived.comision} prev={derivedPrev.comision} invert /> : undefined} />
            <KpiCard label="Mermas" value={moneyC(k.mermas)} sub="producto perdido" accent={ACCENTS.red}
              delta={cmp ? <Delta cur={k.mermas} prev={kp!.mermas} invert /> : undefined} />
            <KpiCard label="Contribución est." value={moneyC(derived.contrib)} sub={<><b>{pct(derived.contrib / k.venta)}</b> antes de gastos fijos</>} accent={ACCENTS.emerald}
              delta={cmp && derivedPrev ? <Delta cur={derived.contrib} prev={derivedPrev.contrib} /> : undefined} />
            <KpiCard label="Ticket promedio" value={moneyC(k.ticket)} sub={`${N.format(k.clientes)} clientes · ${N.format(k.clientes_nuevos)} nuevos`} accent={ACCENTS.blue}
              delta={cmp ? <Delta cur={k.ticket} prev={kp!.ticket} /> : undefined} />
          </div>

          {/* Flag: productos sin costo */}
          {reporte.flags.pct_sin_costo >= 1 && (
            <div className="flex items-start gap-2.5 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg px-4 py-3">
              <AlertTriangle className="w-5 h-5 text-amber-600 dark:text-amber-400 shrink-0 mt-0.5" />
              <p className="text-sm text-amber-800 dark:text-amber-200">
                <b>Margen sobreestimado:</b> el {pct(reporte.flags.pct_sin_costo / 100)} de la venta ({money(reporte.flags.ingreso_sin_costo)}) proviene de productos sin costo cargado,
                que se computan con costo cero. El margen real es algo menor. Conviene completar el maestro de costos.
              </p>
            </div>
          )}

          {/* Qué requiere tu atención */}
          <Alertas items={reporte.alertas ?? []} onSelect={onAlerta} />

          {/* Detalle completo: colapsable; los gráficos montan recién al abrir (perf) */}
          <button
            type="button"
            onClick={() => setDetalleAbierto((o) => !o)}
            className="flex items-center gap-1.5 text-sm font-semibold text-blue-600 dark:text-blue-400 hover:underline"
          >
            <ChevronDown className={`w-4 h-4 transition-transform ${detalleAbierto ? 'rotate-180' : ''}`} />
            {detalleAbierto ? 'Ocultar detalle' : 'Ver detalle completo (evolución, vendedores, categorías, cobranza…)'}
          </button>

          {detalleAbierto && (<>
          {/* Evolución mensual */}
          <Card id="sec-evolucion" className="p-5">
            <SectionTitle icon={TrendingUp} title="Evolución mensual" hint="Venta, bonificaciones y margen neto por mes." />
            <div className="grid lg:grid-cols-3 gap-5">
              <div className="lg:col-span-2 h-72"><EvolucionChart data={reporte.mensual} /></div>
              <div className="overflow-x-auto">
                <table className="w-full">
                  <thead><tr className="border-b dark:border-gray-700">
                    <th className={`${th} text-left`}>Mes</th><th className={`${th} text-right`}>Venta</th>
                    <th className={`${th} text-right`}>Bonif.</th><th className={`${th} text-right`}>Mg neto</th>
                  </tr></thead>
                  <tbody className="divide-y dark:divide-gray-700/60">
                    {reporte.mensual.map(m => (
                      <tr key={m.mes}>
                        <td className={`${td} font-medium`}>{m.mes}</td>
                        <td className={`${td} text-right tabular-nums`}>{moneyC(m.venta)}</td>
                        <td className={`${td} text-right tabular-nums`}>{moneyC(m.bonif)}</td>
                        <td className={`${td} text-right tabular-nums`}>{pct(m.venta ? (m.venta - m.cmv - m.bonif) / m.venta : 0)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          </Card>

          {/* Waterfall + diario */}
          <div className="grid lg:grid-cols-2 gap-5">
            <Card className="p-5">
              <SectionTitle icon={TrendingUp} title="De la venta a la contribución" hint="Composición del resultado, paso a paso." />
              <div className="h-72"><WaterfallChart venta={k.venta} cmv={k.cmv} bonif={k.bonif} mermas={k.mermas} comision={derived.comision} /></div>
            </Card>
            <Card className="p-5">
              <SectionTitle icon={TrendingUp} title="Ritmo diario de ventas" hint="Facturación entregada por día." />
              <div className="h-72"><DiarioChart data={reporte.serie_diaria} /></div>
            </Card>
          </div>

          {/* Vendedores + comisiones */}
          <Card className="p-5">
            <SectionTitle
              icon={Percent} title="Equipo comercial y comisiones"
              hint="La comisión se recalcula en vivo."
              right={
                <div className="flex items-center gap-3 bg-gray-50 dark:bg-gray-700/40 border dark:border-gray-600 rounded-lg px-3 py-2">
                  <div className="flex items-center gap-1.5">
                    <span className="text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase">Comisión</span>
                    <NumberInput min={0} max={100} value={comPct} onChange={setComPct} commitOnChange emptyValue={0}
                      className="w-14 px-2 py-1 border rounded text-center text-sm font-semibold dark:bg-gray-700 dark:border-gray-600 dark:text-white" />
                    <span className="text-sm font-medium text-gray-600 dark:text-gray-300">%</span>
                  </div>
                  <select value={comBase} onChange={(e) => setComBase(e.target.value as 'nc' | 'ent')}
                    className="text-xs font-medium bg-white dark:bg-gray-700 border dark:border-gray-600 rounded px-2 py-1 text-gray-700 dark:text-gray-200">
                    <option value="nc">No cancelado</option>
                    <option value="ent">Entregado</option>
                  </select>
                </div>
              }
            />
            <div className="grid lg:grid-cols-3 gap-5">
              <div className="lg:col-span-2 overflow-x-auto">
                <table className="w-full">
                  <thead><tr className="border-b dark:border-gray-700">
                    <th className={`${th} text-left`}>Vendedor</th><th className={`${th} text-right`}>Venta</th>
                    <th className={`${th} text-right`}>Mg neto</th><th className={`${th} text-right`}>% neto</th>
                    <th className={`${th} text-right`}>Comisión</th>
                  </tr></thead>
                  <tbody className="divide-y dark:divide-gray-700/60">
                    {[...reporte.vendedores].sort((a, b) => b.venta - a.venta).map((v, i) => {
                      const mn = v.margen_comercial - v.bonif
                      const base = comBase === 'nc' ? v.base_nc : v.venta
                      const mnp = v.venta ? mn / v.venta : 0
                      return (
                        <tr key={v.nombre + i} className="hover:bg-gray-50 dark:hover:bg-gray-700/40">
                          <td className={td}>
                            <span className="font-semibold text-gray-800 dark:text-white">{v.nombre}</span>
                            <span className="ml-2 text-[10px] font-semibold uppercase px-1.5 py-0.5 rounded border border-gray-300 dark:border-gray-600 text-gray-500 dark:text-gray-400">{rolLabel(v.rol)}</span>
                          </td>
                          <td className={`${td} text-right tabular-nums`}>{moneyC(v.venta)}</td>
                          <td className={`${td} text-right tabular-nums ${mn < 0 ? 'text-red-600 dark:text-red-400' : ''}`}>{moneyC(mn)}</td>
                          <td className={`${td} text-right tabular-nums font-medium ${mnp < 0.1 ? 'text-amber-600 dark:text-amber-400' : 'text-emerald-600 dark:text-emerald-400'}`}>{pct(mnp)}</td>
                          <td className={`${td} text-right tabular-nums font-bold text-gray-900 dark:text-white`}>{money(base * comPct / 100)}</td>
                        </tr>
                      )
                    })}
                  </tbody>
                  <tfoot>
                    <tr className="border-t-2 dark:border-gray-600 font-bold">
                      <td className={`${td} text-gray-900 dark:text-white`}>Total</td>
                      <td className={`${td} text-right tabular-nums`}>{moneyC(reporte.vendedores.reduce((s, v) => s + v.venta, 0))}</td>
                      <td className={`${td} text-right tabular-nums`}>{moneyC(reporte.vendedores.reduce((s, v) => s + v.margen_comercial - v.bonif, 0))}</td>
                      <td className={td}></td>
                      <td className={`${td} text-right tabular-nums`}>{money(reporte.vendedores.reduce((s, v) => s + (comBase === 'nc' ? v.base_nc : v.venta) * comPct / 100, 0))}</td>
                    </tr>
                  </tfoot>
                </table>
              </div>
              <div className="h-72"><VendedoresChart data={reporte.vendedores} /></div>
            </div>
          </Card>

          {/* Categorías */}
          <Card id="sec-categorias" className="p-5">
            <SectionTitle icon={TrendingUp} title="Mezcla por categoría" hint="Venta y margen comercial. △ = margen inflado por productos sin costo." />
            <div className="grid lg:grid-cols-3 gap-5">
              <div className="lg:col-span-2 h-80"><CategoriasChart data={reporte.categorias} /></div>
              <div className="overflow-x-auto">
                <table className="w-full">
                  <thead><tr className="border-b dark:border-gray-700">
                    <th className={`${th} text-left`}>Categoría</th><th className={`${th} text-right`}>Venta</th><th className={`${th} text-right`}>Mg com.</th>
                  </tr></thead>
                  <tbody className="divide-y dark:divide-gray-700/60">
                    {reporte.categorias.map(c => (
                      <tr key={c.categoria}>
                        <td className={`${td} font-medium`}>{c.sin_costo && <span className="text-amber-500">△ </span>}{c.categoria}</td>
                        <td className={`${td} text-right tabular-nums`}>{moneyC(c.venta)}</td>
                        <td className={`${td} text-right tabular-nums ${c.margen_comercial < 0 ? 'text-red-600 dark:text-red-400' : ''}`}>{moneyC(c.margen_comercial)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          </Card>

          {/* Top productos / clientes */}
          <div className="grid lg:grid-cols-2 gap-5">
            <Card className="p-5">
              <SectionTitle icon={TrendingUp} title="Top 10 productos" hint="Por facturación de venta real." />
              <table className="w-full">
                <thead><tr className="border-b dark:border-gray-700">
                  <th className={`${th} text-left`}>Producto</th><th className={`${th} text-right`}>Unid.</th><th className={`${th} text-right`}>Venta</th>
                </tr></thead>
                <tbody className="divide-y dark:divide-gray-700/60">
                  {reporte.top_productos.map((p, i) => (
                    <tr key={p.nombre}>
                      <td className={td}><span className="text-gray-400 font-semibold mr-1.5">{i + 1}</span>{p.nombre}</td>
                      <td className={`${td} text-right tabular-nums`}>{N.format(p.unidades)}</td>
                      <td className={`${td} text-right tabular-nums`}>{moneyC(p.venta)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Card>
            <Card id="sec-clientes" className="p-5">
              <SectionTitle icon={TrendingUp} title="Top 10 clientes" hint="Por facturación entregada." />
              <table className="w-full">
                <thead><tr className="border-b dark:border-gray-700">
                  <th className={`${th} text-left`}>Cliente</th><th className={`${th} text-right`}>Ped.</th><th className={`${th} text-right`}>Venta</th>
                </tr></thead>
                <tbody className="divide-y dark:divide-gray-700/60">
                  {reporte.top_clientes.map((c, i) => (
                    <tr key={c.cliente + i}>
                      <td className={td}><span className="text-gray-400 font-semibold mr-1.5">{i + 1}</span>{c.cliente}</td>
                      <td className={`${td} text-right tabular-nums`}>{c.pedidos}</td>
                      <td className={`${td} text-right tabular-nums`}>{moneyC(c.venta)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Card>
          </div>

          {/* Cobranza + costos */}
          <div className="grid lg:grid-cols-2 gap-5">
            <Card id="sec-cobranza" className="p-5">
              <SectionTitle icon={TrendingUp} title="Cobranza y formas de pago" hint={`${pct(reporte.cobranza.cobrado / (k.venta || 1))} cobrado.`} />
              <div className="grid grid-cols-2 gap-4 items-center">
                <div className="h-48"><CobranzaDonut cobranza={reporte.cobranza} /></div>
                <table className="w-full">
                  <tbody className="divide-y dark:divide-gray-700/60">
                    {reporte.cobranza.formas.map(f => (
                      <tr key={f.forma_pago}>
                        <td className={`${td} capitalize`}>{f.forma_pago}</td>
                        <td className={`${td} text-right tabular-nums`}>{moneyC(f.monto)}</td>
                      </tr>
                    ))}
                    <tr className="font-semibold">
                      <td className={`${td} text-emerald-600 dark:text-emerald-400`}>Cobrado</td>
                      <td className={`${td} text-right tabular-nums text-emerald-600 dark:text-emerald-400`}>{moneyC(reporte.cobranza.cobrado)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </Card>
            <Card id="sec-mermas" className="p-5">
              <SectionTitle icon={TrendingUp} title="Otros costos del período" hint="Mermas, bonificaciones y reposición." />
              <table className="w-full">
                <thead><tr className="border-b dark:border-gray-700">
                  <th className={`${th} text-left`}>Mes</th><th className={`${th} text-right`}>Mermas</th><th className={`${th} text-right`}>Bonif.</th><th className={`${th} text-right`}>Compras</th>
                </tr></thead>
                <tbody className="divide-y dark:divide-gray-700/60">
                  {reporte.mensual.map(m => (
                    <tr key={m.mes}>
                      <td className={`${td} font-medium`}>{m.mes}</td>
                      <td className={`${td} text-right tabular-nums`}>{moneyC(m.mermas)}</td>
                      <td className={`${td} text-right tabular-nums`}>{moneyC(m.bonif)}</td>
                      <td className={`${td} text-right tabular-nums`}>{moneyC(m.compras)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Card>
          </div>

          {/* Análisis mensual (Claude Code) */}
          <Card className="p-5">
            <SectionTitle icon={FileText} title="Análisis del período" hint="Lectura ejecutiva generada con Claude Code." />
            {analisis?.analisis_md ? (
              <div className="text-sm text-gray-700 dark:text-gray-200 leading-relaxed space-y-2">
                <ReactMarkdown components={{
                  h1: ({ children }) => <h3 className="text-base font-bold text-gray-900 dark:text-white mt-3 mb-1">{children}</h3>,
                  h2: ({ children }) => <h3 className="text-base font-bold text-gray-900 dark:text-white mt-3 mb-1">{children}</h3>,
                  h3: ({ children }) => <h4 className="text-sm font-bold text-gray-800 dark:text-gray-100 mt-2 mb-1">{children}</h4>,
                  p: ({ children }) => <p className="mb-2">{children}</p>,
                  ul: ({ children }) => <ul className="list-disc pl-5 space-y-1 mb-2">{children}</ul>,
                  ol: ({ children }) => <ol className="list-decimal pl-5 space-y-1 mb-2">{children}</ol>,
                  strong: ({ children }) => <strong className="font-semibold text-gray-900 dark:text-white">{children}</strong>,
                }}>{analisis.analisis_md}</ReactMarkdown>
                {analisis.generado_at && (
                  <p className="text-xs text-gray-400 pt-2 border-t dark:border-gray-700">
                    Generado por {analisis.generado_por ?? '—'} · {new Date(analisis.generado_at).toLocaleDateString('es-AR')}
                  </p>
                )}
              </div>
            ) : (
              <div className="text-center py-8 text-gray-500 dark:text-gray-400">
                <FileText className="w-10 h-10 mx-auto mb-3 opacity-40" />
                <p className="font-medium">Sin análisis para {periodoSel.esMes ? periodoSel.label : 'el período'}</p>
                <p className="text-xs mt-1">
                  {periodoSel.esMes
                    ? 'Generalo desde Claude Code con el comando /reporte-mensual.'
                    : 'El análisis escrito se asocia a meses; elegí un mes para verlo.'}
                </p>
              </div>
            )}
          </Card>
          </>)}
        </>
      )}

      {showMetas && (
        <ModalMetas
          metas={metas}
          periodoLabel={periodoSel.label}
          sucursalNombre={reporte?.meta.sucursal_nombre ?? ''}
          guardando={guardandoMeta}
          onGuardar={(v, m) => { onGuardarMeta(v, m); setShowMetas(false) }}
          onClose={() => setShowMetas(false)}
        />
      )}

      {alertaDetalle && (
        <ModalAlertaDetalle
          titulo={alertaDetalle.titulo}
          codigo={alertaDetalle.codigo}
          sucursalId={sucursalSel}
          onClose={() => setAlertaDetalle(null)}
        />
      )}
    </div>
  )
}
