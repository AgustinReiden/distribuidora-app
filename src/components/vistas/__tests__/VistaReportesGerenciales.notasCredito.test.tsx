/**
 * Notas de crédito de venta en el gerencial (#845, mig 289).
 *
 * Antes el crédito de una NC se registraba como pago `nota_credito` y contaba
 * como COBRADO, y ningún KPI la descontaba: la contribución quedaba
 * sobreestimada por el monto de las notas. Ahora:
 *   · card propia "Notas de crédito"
 *   · contribución = margen neto − mermas − comisión − NC (los márgenes no cambian)
 *   · el % cobrado es sólo plata; el crédito aplicado va en su propia línea y las
 *     formas no dinerarias van marcadas
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
  BonifPromosChart: () => <div />, MermasMotivoChart: () => <div />,
}));

vi.mock('../../../hooks/queries/useReporteGerencialQuery', () => ({
  usePosicionFiscalQuery: () => ({ data: null, isLoading: false }),
}));

import VistaReportesGerenciales from '../VistaReportesGerenciales';
import type { ReporteGerencial } from '../../../hooks/queries/useReporteGerencialQuery';

function reporte(over: Partial<ReporteGerencial['kpis']> = {}, cobranza?: ReporteGerencial['cobranza']): ReporteGerencial {
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
      notas_credito_venta: 100000, notas_credito_venta_n: 3,
      ...over,
    },
    mensual: [], vendedores: [], categorias: [], top_productos: [], top_clientes: [],
    cobranza: cobranza ?? {
      formas: [
        { forma_pago: 'efectivo', monto: 14000000, no_dineraria: false },
        { forma_pago: 'nota_credito', monto: 100000, no_dineraria: true },
      ],
      cobrado: 14000000, credito_aplicado: 100000, pendiente: 3985420,
    },
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

/** La card de un KPI: el label y su valor comparten el contenedor. */
function card(label: string): HTMLElement {
  return screen.getByText(label, { exact: true }).parentElement as HTMLElement;
}

async function abrirDetalle(user: ReturnType<typeof userEvent.setup>) {
  const toggle = screen.getAllByRole('button').find(b => /detalle/i.test(b.textContent ?? ''));
  if (toggle) await user.click(toggle);
}

describe('VistaReportesGerenciales › notas de crédito de venta', () => {
  it('tiene card propia con el monto y la cantidad', () => {
    renderVista(reporte());
    const c = card('Notas de crédito');
    expect(within(c).getByText('$100 K')).toBeInTheDocument();
    expect(c).toHaveTextContent('3 de venta');
  });

  it('la contribución resta las NC: margen neto − mermas − comisión − NC', () => {
    renderVista(reporte());
    // 3.360.000 − 50.000 − 302.426 − 100.000 = 2.907.574. Sin restar la NC
    // daría 3.007.574 ($3,01 M).
    expect(within(card('Contribución est.')).getByText('$2,91 M')).toBeInTheDocument();
  });

  it('los márgenes no cambian: se muestran tal cual vienen del RPC', () => {
    renderVista(reporte());
    expect(within(card('Margen neto')).getByText('$3,36 M')).toBeInTheDocument();
    expect(within(card('Margen comercial')).getByText('$3,60 M')).toBeInTheDocument();
  });

  it('una respuesta cacheada sin la clave muestra 0 y no toca la contribución', () => {
    renderVista(reporte({ notas_credito_venta: undefined, notas_credito_venta_n: undefined }));
    expect(within(card('Notas de crédito')).getByText('$0')).toBeInTheDocument();
    expect(within(card('Contribución est.')).getByText('$3,01 M')).toBeInTheDocument();
  });
});

describe('VistaReportesGerenciales › cobranza: plata vs crédito aplicado', () => {
  it('el % cobrado es sólo plata', async () => {
    const user = userEvent.setup();
    renderVista(reporte());
    await abrirDetalle(user);
    // 14.000.000 / 18.085.420 = 77,4%. Contando el crédito daría 77,9%.
    expect(screen.getByText(/77,4% cobrado en plata/)).toBeInTheDocument();
  });

  it('el crédito aplicado va en su propia línea y la forma no dineraria va marcada', async () => {
    const user = userEvent.setup();
    renderVista(reporte());
    await abrirDetalle(user);
    const fila = screen.getByText('Crédito aplicado (NC y adelantos)').closest('tr') as HTMLElement;
    expect(within(fila).getByText('$100 K')).toBeInTheDocument();
    const nc = screen.getByText('nota_credito').closest('tr') as HTMLElement;
    expect(within(nc).getByText('(no dinerario)')).toBeInTheDocument();
    const ef = screen.getByText('efectivo').closest('tr') as HTMLElement;
    expect(within(ef).queryByText('(no dinerario)')).not.toBeInTheDocument();
    // 'Cobrado' también aparece en el criterio de la card: se toma la celda.
    const cobrado = screen.getAllByText('Cobrado').find(e => e.tagName === 'TD')!.closest('tr') as HTMLElement;
    expect(within(cobrado).getByText('$14,00 M')).toBeInTheDocument();
  });

  it('sin crédito aplicado no muestra la línea', async () => {
    const user = userEvent.setup();
    renderVista(reporte({}, { formas: [{ forma_pago: 'efectivo', monto: 100, no_dineraria: false }], cobrado: 100, pendiente: 0 }));
    await abrirDetalle(user);
    expect(screen.queryByText('Crédito aplicado (NC y adelantos)')).not.toBeInTheDocument();
  });
});
