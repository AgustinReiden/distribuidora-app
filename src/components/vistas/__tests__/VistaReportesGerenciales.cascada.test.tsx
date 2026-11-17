/**
 * B11c (#1639), la cascada y los % del gerencial contra lo que manda el server.
 *
 *  · H1: el gráfico en cascada recibe lo vendido sin costo (`sinCosto`) cuando el server lo dejó fuera
 *    del margen, y «Mg comerc.» y «Contrib.» del gráfico dan lo mismo que las cards.
 *  · H4: el margen de cada mes de la tabla de Evolución sale sobre la venta con costo, como la card.
 *  · % con venta 0 o negativa: «—», no un número al revés.
 *
 * La vista se importa DIRECTO (no por el container, lazy). El gráfico se reemplaza por un doble que
 * arma los pasos con `pasosCascada` real y los escribe como texto.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { pasosCascada } from '../../../utils/cascadaGerencial'

vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn() },
}))

vi.mock('../../../utils/excel', () => ({ createMultiSheetExcel: vi.fn() }))

vi.mock('../reportes-gerenciales/charts', () => ({
  EvolucionChart: () => <div />, DiarioChart: () => <div />, VendedoresChart: () => <div />,
  CategoriasChart: () => <div />, CobranzaDonut: () => <div />,
  BonifPromosChart: () => <div />, MermasMotivoChart: () => <div />,
  WaterfallChart: (props: Parameters<typeof pasosCascada>[0]) => {
    const { pasos } = pasosCascada(props)
    return (
      <div data-testid="cascada">
        {pasos.map(p => <span key={p.l} data-paso={p.l}>{p.v}</span>)}
      </div>
    )
  },
}))

vi.mock('../../../hooks/queries/useReporteGerencialQuery', () => ({
  usePosicionFiscalQuery: () => ({ data: null, isLoading: false }),
}))

import VistaReportesGerenciales from '../VistaReportesGerenciales'
import type { ReporteGerencial } from '../../../hooks/queries/useReporteGerencialQuery'

// Venta 1.000.000 con 80.000 sin costo y CMV 600.000 (de lo que sí tiene costo).
function reporte(kpis: Record<string, unknown> = {}, over: Record<string, unknown> = {}): ReporteGerencial {
  return {
    meta: {
      sucursal_id: 1, sucursal_nombre: 'Tucumán', desde: '2026-10-01', hasta: '2026-10-31',
      generado_at: '2026-10-06T12:00:00Z', incluye_no_entregados: false,
    },
    kpis: {
      venta: 1000000, pedidos: 120, clientes: 60, ticket: 8000, clientes_nuevos: 2,
      cmv: 600000, bonif: 50000, unidades: 5000, unidades_bonif: 100,
      mermas: 10000, compras: 900000, base_comision: 1000000, comision_pct_default: 2,
      ...kpis,
    },
    mensual: [], vendedores: [], categorias: [], top_productos: [], top_clientes: [],
    cobranza: { formas: [], cobrado: 0, pendiente: 0 },
    serie_diaria: [], flags: { ingreso_sin_costo: 0, pct_sin_costo: 0 },
    alertas: [],
    ...over,
  } as unknown as ReporteGerencial
}

// Server nuevo: trae venta_bruta y sus márgenes ya excluyen lo sin costo.
const SERVER_NUEVO = {
  venta_bruta: 1000000, ingreso_sin_costo: 80000, notas_credito_venta: 0,
  margen_comercial: 320000, margen_neto: 270000, // 1.000.000 − 80.000 − 600.000 (− 50.000)
}
// Server de hoy: sin venta_bruta; su margen todavía cuenta lo sin costo.
const SERVER_VIEJO = {
  ingreso_sin_costo: 80000,
  margen_comercial: 400000, margen_neto: 350000,
}

const periodo = {
  key: 'oct', label: 'Octubre 2026', desde: '2026-10-01', hasta: '2026-10-31',
  esMes: true, periodoMes: '2026-10-01', parcial: false,
}

function renderVista(r: ReporteGerencial) {
  return render(
    <MemoryRouter><VistaReportesGerenciales
      reporte={r} loading={false} error={null} sucursalSel={1} periodoSel={periodo}
      opcionesSucursal={[{ id: 1, nombre: 'Tucumán' }]} opcionesPeriodo={[periodo]}
      onSucursal={vi.fn()} onPeriodo={vi.fn()} onRango={vi.fn()}
      incluirNoEntregados={false} onIncluirNoEntregados={vi.fn()}
      comparar={false} onComparar={vi.fn()}
      metas={null} metasEditable={false} onGuardarMeta={vi.fn()} guardandoMeta={false}
      analisis={null}
      comisionCalculada={20000}
      comisionPorVendedor={null}
    /></MemoryRouter>,
  )
}

function card(label: string): HTMLElement {
  return screen.getByText(label, { exact: true }).parentElement as HTMLElement
}

/** El detalle (cascada, evolución, tablas) está detrás del botón «Ver detalle». */
async function abrirDetalle() {
  const toggle = screen.getAllByRole('button').find(b => /detalle/i.test(b.textContent ?? ''))
  if (toggle) await userEvent.setup().click(toggle)
}

const paso = (nombre: string): number => {
  const el = within(screen.getByTestId('cascada')).getByText((_, e) => e?.getAttribute('data-paso') === nombre)
  return Number(el.textContent)
}

describe('VistaReportesGerenciales › la cascada cierra con las cards (H1)', () => {
  it('server nuevo: «− Sin costo», «Mg comerc.» y «Contrib.» del gráfico son los de las cards', async () => {
    renderVista(reporte(SERVER_NUEVO))
    await abrirDetalle()

    expect(paso('− Sin costo')).toBe(-80000)
    // Mg comercial: 1.000.000 − 80.000 − 600.000 = 320.000, la card.
    expect(paso('Mg comerc.')).toBe(320000)
    expect(within(card('Margen comercial')).getByText('$320 K')).toBeInTheDocument()
    // Contribución: margen neto 270.000 − mermas 10.000 − comisión 20.000 = 240.000, la card.
    expect(paso('Contrib.')).toBe(240000)
    expect(within(card('Contribución est.')).getByText('$240 K')).toBeInTheDocument()
  })

  it('server nuevo con un sin costo NEGATIVO (una NC sobre un producto sin costo): sigue cerrando', async () => {
    renderVista(reporte({
      ...SERVER_NUEVO, ingreso_sin_costo: -5000, margen_comercial: 405000, margen_neto: 355000,
    }))
    await abrirDetalle()

    expect(paso('+ Sin costo')).toBe(5000)
    expect(paso('Mg comerc.')).toBe(405000)
    expect(within(card('Margen comercial')).getByText('$405 K')).toBeInTheDocument()
    expect(paso('Contrib.')).toBe(325000)
    expect(within(card('Contribución est.')).getByText('$325 K')).toBeInTheDocument()
  })

  it('server de hoy (sin venta_bruta): no hay paso «Sin costo» y el gráfico cierra con su margen', async () => {
    renderVista(reporte(SERVER_VIEJO))
    await abrirDetalle()

    expect(screen.queryByText((_, e) => /Sin costo/.test(e?.getAttribute('data-paso') ?? ''))).not.toBeInTheDocument()
    expect(paso('Mg comerc.')).toBe(400000)
    expect(within(card('Margen comercial')).getByText('$400 K')).toBeInTheDocument()
    expect(paso('Contrib.')).toBe(320000)
    expect(within(card('Contribución est.')).getByText('$320 K')).toBeInTheDocument()
  })

  it('con las notas de crédito ya restadas de la venta, la cascada no las resta otra vez', async () => {
    renderVista(reporte({
      ...SERVER_NUEVO, venta: 980000, venta_bruta: 1000000, notas_credito_venta: 20000,
      margen_comercial: 300000, margen_neto: 250000,
    }))
    await abrirDetalle()

    expect(paso('Contrib.')).toBe(220000) // 250.000 − 10.000 − 20.000
    expect(screen.queryByText((_, e) => e?.getAttribute('data-paso') === '− Notas de crédito')).not.toBeInTheDocument()
  })
})

describe('VistaReportesGerenciales › % con venta 0 o negativa', () => {
  it('Bonificaciones, Margen neto y Contribución dicen «—» y no «Infinity%» ni un % al revés', () => {
    renderVista(reporte({ ...SERVER_NUEVO, venta: 0, venta_bruta: 0, ingreso_sin_costo: 0, bonif: 5000 }))

    expect(card('Bonificaciones')).toHaveTextContent('— de la venta')
    expect(card('Contribución est.')).toHaveTextContent('— antes de gastos fijos')
    expect(document.body.textContent).not.toMatch(/Infinity|NaN/)
  })
})

describe('VistaReportesGerenciales › margen de cada mes en Evolución (H4)', () => {
  const mes = (over: Record<string, unknown> = {}) => ({
    mes: '2026-10', pedidos: 50, venta: 1000000, clientes: 20, ticket: 20000, cmv: 600000, bonif: 50000,
    mermas: 10000, compras: 900000, ...over,
  })

  it('server nuevo: el % sale sobre la venta con costo, como el de la card', async () => {
    renderVista(reporte(SERVER_NUEVO, { mensual: [mes({ ingreso_sin_costo: 80000 })] }))
    await abrirDetalle()

    // (1.000.000 − 80.000 − 600.000 − 50.000) / (1.000.000 − 80.000) = 270.000 / 920.000 = 29,3 %.
    // Contando lo sin costo como margen daría 35,0 %.
    const fila = within(document.getElementById('sec-evolucion') as HTMLElement).getByText('2026-10').closest('tr') as HTMLElement
    expect(within(fila).getByText('29,3%')).toBeInTheDocument()
  })

  it('server de hoy (sin venta_bruta): igual que antes, sobre la venta', async () => {
    renderVista(reporte(SERVER_VIEJO, { mensual: [mes({ ingreso_sin_costo: 80000 })] }))
    await abrirDetalle()

    const fila = within(document.getElementById('sec-evolucion') as HTMLElement).getByText('2026-10').closest('tr') as HTMLElement
    expect(within(fila).getByText('35,0%')).toBeInTheDocument()
  })

  it('un mes de venta negativa muestra «—»', async () => {
    renderVista(reporte(SERVER_NUEVO, { mensual: [mes({ venta: -20000, cmv: 0, bonif: 0 })] }))
    await abrirDetalle()

    const fila = within(document.getElementById('sec-evolucion') as HTMLElement).getByText('2026-10').closest('tr') as HTMLElement
    const celdas = within(fila).getAllByRole('cell')
    expect(celdas[celdas.length - 1]).toHaveTextContent('—')
  })
})
