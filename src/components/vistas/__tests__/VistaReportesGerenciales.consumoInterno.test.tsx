/**
 * Consumo interno (vales blancos, tipo_factura = 'VB') en el gerencial.
 *
 * Un VB es consumo a costo hacia una empresa propia: NO es venta. El RPC lo saca de
 * `venta`, CMV y márgenes y lo informa aparte en `kpis.consumo_interno {monto, pedidos}`.
 * La vista lo muestra como card propia y tolera que el campo no exista (respuesta de
 * antes de esa migración, o cacheada).
 *
 * La vista se importa DIRECTO, no por el container (lazy, flake del PR #514).
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { MemoryRouter } from 'react-router-dom';
import { render, screen, within } from '@testing-library/react';

vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn() },
}));

vi.mock('../../../utils/excel', () => ({ createMultiSheetExcel: vi.fn() }));

vi.mock('../reportes-gerenciales/charts', () => ({
  EvolucionChart: () => <div />, DiarioChart: () => <div />, VendedoresChart: () => <div />,
  CategoriasChart: () => <div />, WaterfallChart: () => <div />, CobranzaDonut: () => <div />,
  BonifPromosChart: () => <div />, MermasMotivoChart: () => <div />,
}));

const posicionFiscal = vi.hoisted(() => ({ data: null as unknown }));
vi.mock('../../../hooks/queries/useReporteGerencialQuery', () => ({
  usePosicionFiscalQuery: () => ({ data: posicionFiscal.data, isLoading: false }),
}));

import VistaReportesGerenciales from '../VistaReportesGerenciales';
import type { ReporteGerencial } from '../../../hooks/queries/useReporteGerencialQuery';

function reporte(over: Partial<ReporteGerencial['kpis']> = {}): ReporteGerencial {
  return {
    meta: {
      sucursal_id: 1, sucursal_nombre: 'Tucumán', desde: '2026-10-01', hasta: '2026-10-31',
      generado_at: '2026-10-06T12:00:00Z', incluye_no_entregados: false,
    },
    kpis: {
      venta: 18085420, pedidos: 120, clientes: 60, ticket: 150000, clientes_nuevos: 2,
      cmv: 12000000, bonif: 240000, unidades: 5000, unidades_bonif: 100,
      margen_comercial: 3600000, margen_neto: 3360000, base_comision: 18085420,
      comision_pct_default: 2, mermas: 50000, compras: 9000000, ingreso_sin_costo: 0,
      ...over,
    },
    mensual: [], vendedores: [], categorias: [], top_productos: [], top_clientes: [],
    cobranza: { formas: [], cobrado: 0, pendiente: 0 },
    serie_diaria: [], flags: { ingreso_sin_costo: 0, pct_sin_costo: 0 },
    alertas: [],
  } as unknown as ReporteGerencial;
}

const periodo = {
  key: 'oct', label: 'Octubre 2026', desde: '2026-10-01', hasta: '2026-10-31',
  esMes: true, periodoMes: '2026-10-01', parcial: false,
};

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
      comisionCalculada={302426}
      comisionPorVendedor={null}
    /></MemoryRouter>
  );
}

function card(label: string): HTMLElement {
  return screen.getByText(label, { exact: true }).parentElement as HTMLElement;
}

describe('VistaReportesGerenciales › consumo interno (vales blancos)', () => {
  it('tiene card propia con el monto a costo y la cantidad de vales', () => {
    renderVista(reporte({ consumo_interno: { monto: 10843304, pedidos: 193 } }));
    const c = card('Consumo interno');
    expect(within(c).getByText('$10,84 M')).toBeInTheDocument();
    expect(c).toHaveTextContent('193 vales blancos');
    expect(c).toHaveTextContent(/fuera de la venta/i);
  });

  it('no toca la venta: se muestra tal cual viene del RPC', () => {
    renderVista(reporte({ consumo_interno: { monto: 10843304, pedidos: 193 } }));
    expect(within(card('Venta entregada')).getByText('$18,09 M')).toBeInTheDocument();
  });

  it('un solo vale va en singular', () => {
    renderVista(reporte({ consumo_interno: { monto: 5000, pedidos: 1 } }));
    expect(card('Consumo interno')).toHaveTextContent('1 vale blanco ·');
  });

  it('una respuesta sin el campo (RPC viejo o cacheada) no muestra la card ni rompe', () => {
    renderVista(reporte());
    expect(screen.queryByText('Consumo interno', { exact: true })).not.toBeInTheDocument();
    expect(card('Venta entregada')).toBeInTheDocument();
  });
});
