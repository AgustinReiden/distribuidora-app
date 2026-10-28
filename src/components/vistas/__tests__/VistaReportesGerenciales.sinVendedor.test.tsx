/**
 * La fila "(sin vendedor)" de la tabla de vendedores (#1262, REP-2).
 *
 * `reporte_gerencial` dejaba fuera los pedidos sin `usuario_id` (hay dos de
 * marzo, $75.400) y Σ vendedores no cerraba contra la venta. Desde la mig 410
 * van en una fila con `id: null`, `rol: null` y `base_nc: 0`. La tabla la
 * muestra sin chip de rol, y nadie liquida comisión por ella: el cruce con
 * `calcular_comisiones` es por id, y un id null no cruza con nada.
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
  CategoriasChart: () => <div />, WaterfallChart: () => <div />, CobranzaDonut: () => <div />,
  BonifPromosChart: () => <div />,
}));

vi.mock('../../../hooks/queries/useReporteGerencialQuery', () => ({
  usePosicionFiscalQuery: () => ({ data: null, isLoading: false }),
}));

import VistaReportesGerenciales from '../VistaReportesGerenciales';
import { money } from '../reportes-gerenciales/formato';
import type { ReporteGerencial } from '../../../hooks/queries/useReporteGerencialQuery';

const $$ = (x: number): string => money(x).replace(/\s/g, ' ');

const VENDEDORES = [
  { id: 'u-juan', nombre: 'Juan', rol: 'preventista', pedidos: 100, venta: 15121320, margen_comercial: 3000000, bonif: 200000, base_nc: 15121320 },
  { id: null, nombre: '(sin vendedor)', rol: null, pedidos: 2, venta: 75400, margen_comercial: 20000, bonif: 0, base_nc: 0 },
];

function reporte(): ReporteGerencial {
  return {
    meta: {
      sucursal_id: 2, sucursal_nombre: 'Taco Pozo', desde: '2026-03-01', hasta: '2026-03-31',
      generado_at: '2026-10-28T12:00:00Z', incluye_no_entregados: false,
    },
    kpis: {
      venta: 15196720, pedidos: 102, clientes: 60, ticket: 150000, clientes_nuevos: 2,
      cmv: 12000000, bonif: 200000, unidades: 5000, unidades_bonif: 100,
      margen_comercial: 3020000, margen_neto: 2820000, base_comision: 15121320,
      comision_pct_default: 2, mermas: 50000, compras: 9000000, ingreso_sin_costo: 0,
    },
    mensual: [], vendedores: VENDEDORES, categorias: [], top_productos: [], top_clientes: [],
    cobranza: { formas: [], cobrado: 0, pendiente: 0 },
    serie_diaria: [], flags: { ingreso_sin_costo: 0, pct_sin_costo: 0 },
    alertas: [],
  } as unknown as ReporteGerencial;
}

const periodo = {
  key: 'mar', label: 'Marzo 2026', desde: '2026-03-01', hasta: '2026-03-31',
  esMes: true, periodoMes: '2026-03-01', parcial: false,
};

function renderVista() {
  return render(
    <MemoryRouter><VistaReportesGerenciales
      reporte={reporte()}
      loading={false}
      error={null}
      sucursalSel={2}
      periodoSel={periodo}
      opcionesSucursal={[{ id: 2, nombre: 'Taco Pozo' }]}
      opcionesPeriodo={[periodo]}
      onSucursal={vi.fn()}
      onPeriodo={vi.fn()}
      onRango={vi.fn()}
      incluirNoEntregados={false}
      onIncluirNoEntregados={vi.fn()}
      comparar={false}
      onComparar={vi.fn()}
      metas={null}
      metasEditable={false}
      onGuardarMeta={vi.fn()}
      guardandoMeta={false}
      analisis={null}
      comisionCalculada={302426}
      comisionPorVendedor={[{ id: 'u-juan', nombre: 'Juan', comision: 302426 }]}
    /></MemoryRouter>
  );
}

async function abrirDetalle(user: ReturnType<typeof userEvent.setup>) {
  const toggle = screen.getAllByRole('button').find(b => /detalle/i.test(b.textContent ?? ''));
  if (toggle) await user.click(toggle);
}

describe('VistaReportesGerenciales › fila "(sin vendedor)"', () => {
  it('aparece con su venta y sin chip de rol', async () => {
    const user = userEvent.setup();
    renderVista();
    await abrirDetalle(user);

    const fila = screen.getByText('(sin vendedor)').closest('tr') as HTMLElement;
    expect(fila).toBeInTheDocument();
    expect(within(fila).queryByText('Prev')).not.toBeInTheDocument();
    // La celda del nombre tiene sólo el nombre: no hay un chip vacío al lado.
    expect(fila.querySelector('td')?.querySelectorAll('span')).toHaveLength(1);
  });

  it('no liquida comisión, y el pie de la columna real sigue siendo el del KPI', async () => {
    const user = userEvent.setup();
    renderVista();
    await abrirDetalle(user);

    const fila = screen.getByText('(sin vendedor)').closest('tr') as HTMLElement;
    // Real 0 (no cruza con calcular_comisiones) y simulado 0 (base_nc es 0).
    expect(within(fila).getAllByText($$(0))).toHaveLength(2);

    const tabla = screen.getByText('Vendedor').closest('table') as HTMLElement;
    const total = within(tabla).getByText('Total').closest('tr') as HTMLElement;
    expect(within(total).getAllByText($$(302426)).length).toBeGreaterThan(0);
  });
});
