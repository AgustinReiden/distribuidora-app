// Gráficos de la vista de Reportes Gerenciales (react-chartjs-2).
// Tematizados con la paleta de la app y conscientes del modo oscuro.
import React, { useMemo } from 'react'
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  BarElement,
  LineElement,
  PointElement,
  ArcElement,
  Tooltip,
  Legend,
  Filler,
} from 'chart.js'
import { Bar, Line, Doughnut } from 'react-chartjs-2'
import { useTheme } from '../../../contexts/ThemeContext'
import { money } from './formato'
import type { ReporteMes, ReporteVendedor, ReporteCategoria, ReporteCobranza, BonifPromo } from '../../../hooks/queries'

ChartJS.register(
  CategoryScale, LinearScale, BarElement, LineElement, PointElement,
  ArcElement, Tooltip, Legend, Filler,
)

const PALETTE = {
  blue: '#2563eb',
  emerald: '#059669',
  amber: '#d97706',
  red: '#dc2626',
  violet: '#7c3aed',
  cyan: '#0891b2',
  slate: '#64748b',
}

function useChartTheme() {
  const { darkMode } = useTheme()
  return useMemo(() => ({
    tick: darkMode ? '#94a3b8' : '#64748b',
    grid: darkMode ? 'rgba(148,163,184,0.14)' : 'rgba(100,116,139,0.14)',
    border: darkMode ? 'rgba(148,163,184,0.3)' : 'rgba(100,116,139,0.3)',
    surface: darkMode ? '#1f2937' : '#ffffff',
    tooltipBg: darkMode ? '#0f172a' : '#1e293b',
  }), [darkMode])
}

const fmtM = (v: number | string) => '$' + Number(v) / 1e6 + 'M'

function baseTooltip(bg: string) {
  return {
    backgroundColor: bg, padding: 10, cornerRadius: 6, displayColors: false,
    titleFont: { weight: 'bold' as const }, bodyColor: '#e2e8f0', titleColor: '#fff',
  }
}

// --- Evolución mensual: venta + bonificaciones (barras) + margen neto % (línea) ---
export function EvolucionChart({ data }: { data: ReporteMes[] }): React.ReactElement {
  const t = useChartTheme()
  // Gráfico mixto (barras + línea): tipamos laxo para react-chartjs-2.
  const chartData: any = {
    labels: data.map(m => m.mes),
    datasets: [
      { type: 'bar', label: 'Venta', data: data.map(m => m.venta), backgroundColor: PALETTE.blue, borderRadius: 4, order: 3, yAxisID: 'y' },
      { type: 'bar', label: 'Bonificaciones', data: data.map(m => m.bonif), backgroundColor: PALETTE.amber, borderRadius: 4, order: 2, yAxisID: 'y' },
      {
        type: 'line', label: 'Margen neto %',
        data: data.map(m => m.venta ? ((m.venta - m.cmv - m.bonif) / m.venta) * 100 : 0),
        borderColor: PALETTE.violet, backgroundColor: PALETTE.violet, tension: 0.35,
        borderWidth: 2.5, pointRadius: 4, pointBackgroundColor: t.surface, pointBorderWidth: 2,
        order: 1, yAxisID: 'y1',
      },
    ],
  }
  return (
    <Bar
      data={chartData}
      options={{
        maintainAspectRatio: false, interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { position: 'bottom', labels: { usePointStyle: true, boxWidth: 8, padding: 14, color: t.tick } },
          tooltip: { ...baseTooltip(t.tooltipBg), callbacks: { label: (c) => c.dataset.yAxisID === 'y1' ? ` ${c.dataset.label}: ${Number(c.raw).toFixed(1)}%` : ` ${c.dataset.label}: ${money(Number(c.raw))}` } },
        },
        scales: {
          y: { position: 'left', ticks: { callback: fmtM, color: t.tick }, grid: { color: t.grid }, border: { display: false } },
          y1: { position: 'right', min: 0, ticks: { callback: (v) => v + '%', color: t.tick }, grid: { display: false }, border: { display: false } },
          x: { ticks: { color: t.tick }, grid: { display: false }, border: { color: t.border } },
        },
      }}
    />
  )
}

// --- Ritmo diario de ventas ---
export function DiarioChart({ data }: { data: [string, number][] }): React.ReactElement {
  const t = useChartTheme()
  return (
    <Line
      data={{
        labels: data.map(d => d[0]),
        datasets: [{
          label: 'Venta', data: data.map(d => d[1]),
          borderColor: PALETTE.cyan, borderWidth: 2, tension: 0.3, fill: true, pointRadius: 0,
          backgroundColor: (ctx) => {
            const { ctx: c, chartArea } = ctx.chart
            if (!chartArea) return 'rgba(8,145,178,0.15)'
            const g = c.createLinearGradient(0, chartArea.top, 0, chartArea.bottom)
            g.addColorStop(0, 'rgba(8,145,178,0.25)'); g.addColorStop(1, 'rgba(8,145,178,0)')
            return g
          },
        }],
      }}
      options={{
        maintainAspectRatio: false,
        plugins: { legend: { display: false }, tooltip: { ...baseTooltip(t.tooltipBg), callbacks: { label: (c) => ' ' + money(Number(c.raw)) } } },
        scales: {
          y: { ticks: { callback: fmtM, color: t.tick }, grid: { color: t.grid }, border: { display: false } },
          x: { ticks: { maxTicksLimit: 10, autoSkip: true, color: t.tick }, grid: { display: false }, border: { color: t.border } },
        },
      }}
    />
  )
}

// --- Vendedores: margen neto + bonificaciones (barras horizontales apiladas) ---
export function VendedoresChart({ data }: { data: ReporteVendedor[] }): React.ReactElement {
  const t = useChartTheme()
  const v = [...data].sort((a, b) => b.venta - a.venta)
  const hasBonif = v.some(x => x.bonif > 0)
  const datasets: any[] = [
    { label: 'Margen neto', data: v.map(x => x.margen_comercial - x.bonif), backgroundColor: PALETTE.emerald, borderRadius: 4, stack: 'a' },
  ]
  if (hasBonif) datasets.push({ label: 'Bonificaciones', data: v.map(x => x.bonif), backgroundColor: PALETTE.amber, borderRadius: 4, stack: 'a' })
  return (
    <Bar
      data={{ labels: v.map(x => x.nombre), datasets }}
      options={{
        maintainAspectRatio: false, indexAxis: 'y', interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { display: hasBonif, position: 'bottom', labels: { usePointStyle: true, boxWidth: 8, padding: 12, color: t.tick } },
          tooltip: { ...baseTooltip(t.tooltipBg), callbacks: { label: (c) => ` ${c.dataset.label}: ${money(Number(c.raw))}` } },
        },
        scales: {
          x: { stacked: true, ticks: { callback: fmtM, color: t.tick }, grid: { color: t.grid }, border: { display: false } },
          y: { stacked: true, ticks: { color: t.tick }, grid: { display: false }, border: { color: t.border } },
        },
      }}
    />
  )
}

// --- Categorías: venta + margen comercial (barras horizontales) ---
export function CategoriasChart({ data }: { data: ReporteCategoria[] }): React.ReactElement {
  const t = useChartTheme()
  const top = data.slice(0, 12)
  return (
    <Bar
      data={{
        labels: top.map(c => c.categoria),
        datasets: [
          { label: 'Venta', data: top.map(c => c.venta), backgroundColor: PALETTE.blue, borderRadius: 4 },
          { label: 'Margen comercial', data: top.map(c => c.margen_comercial), backgroundColor: top.map(c => c.margen_comercial < 0 ? PALETTE.red : PALETTE.emerald), borderRadius: 4 },
        ],
      }}
      options={{
        maintainAspectRatio: false, indexAxis: 'y',
        plugins: {
          legend: { position: 'bottom', labels: { usePointStyle: true, boxWidth: 8, padding: 12, color: t.tick } },
          tooltip: { ...baseTooltip(t.tooltipBg), callbacks: { label: (c) => ` ${c.dataset.label}: ${money(Number(c.raw))}` } },
        },
        scales: {
          x: { ticks: { callback: fmtM, color: t.tick }, grid: { color: t.grid }, border: { display: false } },
          y: { ticks: { color: t.tick, font: { size: 11 } }, grid: { display: false }, border: { color: t.border } },
        },
      }}
    />
  )
}

// --- Composición del resultado (waterfall) ---
export function WaterfallChart({
  venta, cmv, bonif, mermas, comision,
}: { venta: number; cmv: number; bonif: number; mermas: number; comision: number }): React.ReactElement {
  const t = useChartTheme()
  const mc = venta - cmv
  const mn = mc - bonif
  const contrib = mn - mermas - comision
  const steps = [
    { l: 'Venta', v: venta, r: [0, venta], c: PALETTE.blue },
    { l: '− CMV', v: -cmv, r: [mc, venta], c: PALETTE.red },
    { l: 'Mg comerc.', v: mc, r: [0, mc], c: PALETTE.cyan },
    { l: '− Bonif.', v: -bonif, r: [mn, mc], c: PALETTE.red },
    { l: '− Mermas', v: -mermas, r: [mn - mermas, mn], c: PALETTE.red },
    { l: '− Comis.', v: -comision, r: [contrib, mn - mermas], c: PALETTE.red },
    { l: 'Contrib.', v: contrib, r: [0, contrib], c: PALETTE.emerald },
  ]
  return (
    <Bar
      data={{ labels: steps.map(s => s.l), datasets: [{ label: 'monto', data: steps.map(s => s.r) as any, backgroundColor: steps.map(s => s.c), borderRadius: 3 }] }}
      options={{
        maintainAspectRatio: false,
        plugins: { legend: { display: false }, tooltip: { ...baseTooltip(t.tooltipBg), callbacks: { label: (c) => ' ' + money(steps[c.dataIndex].v) } } },
        scales: {
          y: { ticks: { callback: fmtM, color: t.tick }, grid: { color: t.grid }, border: { display: false } },
          x: { ticks: { color: t.tick, font: { size: 10 } }, grid: { display: false }, border: { color: t.border } },
        },
      }}
    />
  )
}

// --- Bonificaciones: costo vs valor de venta por promoción (barras horiz.) ---
export function BonifPromosChart({ data }: { data: BonifPromo[] }): React.ReactElement {
  const t = useChartTheme()
  // Agrupar por promoción y quedarse con las 10 de mayor valor de venta.
  const porPromo = new Map<string, { costo: number; valor_venta: number }>()
  for (const b of data) {
    const acc = porPromo.get(b.promocion) ?? { costo: 0, valor_venta: 0 }
    acc.costo += b.costo
    acc.valor_venta += b.valor_venta
    porPromo.set(b.promocion, acc)
  }
  const top = [...porPromo.entries()]
    .sort((a, b) => b[1].valor_venta - a[1].valor_venta)
    .slice(0, 10)
  return (
    <Bar
      data={{
        labels: top.map(([promo]) => promo),
        datasets: [
          { label: 'Valor de venta', data: top.map(([, v]) => v.valor_venta), backgroundColor: PALETTE.blue, borderRadius: 4 },
          { label: 'Costo real', data: top.map(([, v]) => v.costo), backgroundColor: PALETTE.amber, borderRadius: 4 },
        ],
      }}
      options={{
        maintainAspectRatio: false, indexAxis: 'y',
        plugins: {
          legend: { position: 'bottom', labels: { usePointStyle: true, boxWidth: 8, padding: 12, color: t.tick } },
          tooltip: { ...baseTooltip(t.tooltipBg), callbacks: { label: (c) => ` ${c.dataset.label}: ${money(Number(c.raw))}` } },
        },
        scales: {
          x: { ticks: { callback: fmtM, color: t.tick }, grid: { color: t.grid }, border: { display: false } },
          y: { ticks: { color: t.tick, font: { size: 11 } }, grid: { display: false }, border: { color: t.border } },
        },
      }}
    />
  )
}

// --- Cobranza: dona de formas de pago ---
export function CobranzaDonut({ cobranza }: { cobranza: ReporteCobranza }): React.ReactElement {
  const t = useChartTheme()
  const colors = [PALETTE.emerald, PALETTE.blue, PALETTE.violet, PALETTE.amber, PALETTE.cyan, PALETTE.slate]
  return (
    <Doughnut
      data={{
        labels: cobranza.formas.map(f => f.forma_pago),
        datasets: [{ data: cobranza.formas.map(f => f.monto), backgroundColor: cobranza.formas.map((_, i) => colors[i % colors.length]), borderWidth: 2, borderColor: t.surface }],
      }}
      options={{
        maintainAspectRatio: false, cutout: '62%',
        plugins: { legend: { display: false }, tooltip: { ...baseTooltip(t.tooltipBg), callbacks: { label: (c) => ` ${c.label}: ${money(Number(c.raw))}` } } },
      }}
    />
  )
}
