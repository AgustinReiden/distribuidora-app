/**
 * Bloque "Envíos" del gerencial (cargo de envío, spec §2, mig cargo_5).
 *
 * `reporte_gerencial.envios` trae recaudado, pedidos que pagaron, gratis,
 * bonificados, % que pagó, venta de productos y venta + envíos. Es `null` cuando
 * en el período ningún pedido fue cobrado, gratis o bonificado (la sucursal no
 * cobra envío): ahí la palabra "envío" no aparece en la pantalla. Una respuesta
 * vieja o cacheada no trae la clave: tampoco.
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

function reporte(envios?: ReporteGerencial['envios']): ReporteGerencial {
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
    },
    mensual: [], vendedores: [], categorias: [], top_productos: [], top_clientes: [],
    cobranza: { formas: [], cobrado: 0, pendiente: 0 },
    serie_diaria: [], flags: { ingreso_sin_costo: 0, pct_sin_costo: 0 },
    alertas: [],
    ...(envios !== undefined ? { envios } : {}),
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

describe('VistaReportesGerenciales › envíos', () => {
  const envios = {
    recaudado: 45500, cobrados: 91, gratis: 23, bonificados: 6, pct_cobrado: 0.7583,
    venta_productos: 18085420, venta_total: 18130920,
  };

  it('con envios muestra los siete números', () => {
    renderVista(reporte(envios));
    const b = screen.getByTestId('envios');
    expect(b).toHaveTextContent(/Envíos/);
    expect(within(b).getByText('Recaudado').parentElement).toHaveTextContent(/\$\s?45\.500/);
    expect(within(b).getByText('Pagaron').parentElement).toHaveTextContent('91');
    expect(within(b).getByText('Gratis').parentElement).toHaveTextContent('23');
    expect(within(b).getByText('Bonificados').parentElement).toHaveTextContent('6');
    expect(within(b).getByText('% que pagó').parentElement).toHaveTextContent('75,8%');
    expect(within(b).getByText('Venta de productos').parentElement).toHaveTextContent('$18,09 M');
    expect(within(b).getByText('Venta + envíos').parentElement).toHaveTextContent('$18,13 M');
  });

  it('la venta del kpi no suma el envío', () => {
    renderVista(reporte(envios));
    expect(within(card('Venta entregada')).getByText('$18,09 M')).toBeInTheDocument();
  });

  it('con envios null no aparece la palabra envío', () => {
    renderVista(reporte(null));
    expect(screen.queryByTestId('envios')).not.toBeInTheDocument();
    expect(document.body.textContent ?? '').not.toMatch(/env[ií]o/i);
  });

  it('una respuesta sin la clave (RPC viejo o cacheada) tampoco', () => {
    renderVista(reporte());
    expect(screen.queryByTestId('envios')).not.toBeInTheDocument();
    expect(document.body.textContent ?? '').not.toMatch(/env[ií]o/i);
  });
});
