/**
 * REP-11: con "Todos" (incluye no entregados) la comisión y la contribución no
 * se muestran: la venta se reconoce con la entrega, y la comisión real es sólo
 * de lo entregado. REP-2: un solo neto en la terna fiscal.
 *
 * La vista se importa DIRECTO, no por el container (lazy, flake del PR #514).
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { MemoryRouter } from 'react-router-dom';
import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn() },
}));

vi.mock('../../../utils/excel', () => ({ createMultiSheetExcel: vi.fn() }));

vi.mock('../reportes-gerenciales/charts', () => ({
  EvolucionChart: () => <div />, DiarioChart: () => <div />, VendedoresChart: () => <div />,
  CategoriasChart: () => <div />, WaterfallChart: () => <div data-testid="waterfall" />, CobranzaDonut: () => <div />,
  BonifPromosChart: () => <div />,
}));

vi.mock('../../../hooks/queries/useReporteGerencialQuery', () => ({
  usePosicionFiscalQuery: () => ({ data: null, isLoading: false }),
}));

import VistaReportesGerenciales from '../VistaReportesGerenciales';
import type { ReporteGerencial } from '../../../hooks/queries/useReporteGerencialQuery';

const VENDEDORES = [
  { id: 'u-juan', nombre: 'Juan', rol: 'preventista', pedidos: 100, venta: 15121320, margen_comercial: 3000000, bonif: 200000, base_nc: 15121320 },
];

function reporte(incluye: boolean): ReporteGerencial {
  const kpis = {
    venta: 18085420, pedidos: 120, clientes: 60, ticket: 150000, clientes_nuevos: 2,
    cmv: 12000000, bonif: 240000, unidades: 5000, unidades_bonif: 100,
    margen_comercial: 3600000, margen_neto: 3360000, base_comision: 18085420,
    comision_pct_default: 2, mermas: 50000, compras: 9000000, ingreso_sin_costo: 0,
    venta_real: 16000000, venta_neta: 16000000, iva_debito: 2085420, fc_pedidos: 40, fc_venta: 10000000,
  };
  return {
    meta: {
      sucursal_id: 1, sucursal_nombre: 'Tucumán', desde: '2026-08-01', hasta: '2026-08-31',
      generado_at: '2026-09-08T12:00:00Z', incluye_no_entregados: incluye,
    },
    kpis,
    comparativo: { ...kpis },
    mensual: [], vendedores: VENDEDORES, categorias: [], top_productos: [], top_clientes: [],
    cobranza: { formas: [], cobrado: 0, pendiente: 0 },
    serie_diaria: [], flags: { ingreso_sin_costo: 0, pct_sin_costo: 0 },
    alertas: [],
  } as unknown as ReporteGerencial;
}

const periodo = {
  key: 'ago', label: 'Agosto 2026', desde: '2026-08-01', hasta: '2026-08-31',
  esMes: true, periodoMes: '2026-08-01', parcial: false,
};

function renderVista(incluye: boolean) {
  return render(
    <MemoryRouter><VistaReportesGerenciales
      reporte={reporte(incluye)}
      loading={false}
      error={null}
      sucursalSel={1}
      periodoSel={periodo}
      opcionesSucursal={[{ id: 1, nombre: 'Tucumán' }]}
      opcionesPeriodo={[periodo]}
      onSucursal={vi.fn()}
      onPeriodo={vi.fn()}
      onRango={vi.fn()}
      incluirNoEntregados={incluye}
      onIncluirNoEntregados={vi.fn()}
      comparar
      onComparar={vi.fn()}
      metas={null}
      metasEditable={false}
      onGuardarMeta={vi.fn()}
      guardandoMeta={false}
      analisis={null}
      comisionCalculada={302426}
      comisionCalculadaPrev={250000}
      comisionPorVendedor={[{ id: 'u-juan', nombre: 'Juan', comision: 302426 }]}
    /></MemoryRouter>
  );
}

const card = (label: string): HTMLElement => screen.getByText(label).closest('div')!.parentElement as HTMLElement;

describe('VistaReportesGerenciales › "Todos" no mezcla comisión y contribución (REP-11)', () => {
  it('con "Todos" las tarjetas de comisión y contribución dicen — y que pase a Entregadas', () => {
    renderVista(true);
    for (const label of ['Comisión', 'Contribución est.']) {
      const c = card(label);
      expect(within(c).getByText('—')).toBeInTheDocument();
      expect(within(c).getByText(/Se calculan sobre lo entregado: pasá a «Entregadas»/)).toBeInTheDocument();
    }
    expect(screen.queryByText('Comisión (reglas)')).not.toBeInTheDocument();
  });

  it('con "Todos" no se dibuja el waterfall ni van las columnas de comisión', async () => {
    renderVista(true);
    await userEvent.click(screen.getByRole('button', { name: /Ver detalle completo/i }));
    expect(screen.queryByTestId('waterfall')).not.toBeInTheDocument();
    expect(screen.queryByRole('columnheader', { name: /Comisión/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('columnheader', { name: /Simulado/ })).not.toBeInTheDocument();
    expect(screen.queryByLabelText('Porcentaje de comisión a simular')).not.toBeInTheDocument();
  });

  it('con "Entregadas" sigue todo como antes', async () => {
    renderVista(false);
    expect(screen.getByText('Comisión (reglas)')).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: /Ver detalle completo/i }));
    expect(screen.getByTestId('waterfall')).toBeInTheDocument();
    expect(screen.getByRole('columnheader', { name: /Comisión/ })).toBeInTheDocument();
    expect(screen.getByRole('columnheader', { name: /Simulado/ })).toBeInTheDocument();
  });
});

describe('VistaReportesGerenciales › un solo neto (REP-2)', () => {
  it('la terna fiscal tiene una línea de venta neta y el IVA débito', () => {
    renderVista(false);
    const texto = document.body.textContent ?? '';
    expect(texto.match(/Venta neta/gi)).toHaveLength(1);
    expect(texto).toContain('Venta neta (venta − IVA débito; en ZZ, el final)');
    expect(texto).not.toContain('Venta real (FC neto');
    expect(texto).toContain('IVA débito de la venta');
  });
});
