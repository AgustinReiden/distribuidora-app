/**
 * Gastos con factura A o M en la posición fiscal del gerencial (gastos, entrega 1).
 *
 * `posicion_fiscal` suma el IVA y las percepciones de los gastos al crédito y
 * devuelve la clave `gastos`. Es opcional en el tipo: una respuesta vieja o
 * cacheada no la trae, y ahí la línea no aparece ni la vista se rompe. Con
 * `cantidad: 0` tampoco.
 *
 * La vista se importa DIRECTO, no por el container (lazy, flake del PR #514).
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { MemoryRouter } from 'react-router-dom';
import { render, screen } from '@testing-library/react';
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

const posicionFiscal = vi.hoisted(() => ({ data: null as unknown }));
vi.mock('../../../hooks/queries/useReporteGerencialQuery', () => ({
  usePosicionFiscalQuery: () => ({ data: posicionFiscal.data, isLoading: false }),
}));

import VistaReportesGerenciales from '../VistaReportesGerenciales';
import type { PosicionFiscal, ReporteGerencial } from '../../../hooks/queries/useReporteGerencialQuery';

const reporte = {
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
} as unknown as ReporteGerencial;

const periodo = {
  key: 'oct', label: 'Octubre 2026', desde: '2026-10-01', hasta: '2026-10-31',
  esMes: true, periodoMes: '2026-10-01', parcial: false,
};

function fiscal(gastos?: PosicionFiscal['gastos']): PosicionFiscal {
  return {
    meta: { sucursal_id: 1, sucursal_nombre: 'Tucumán', desde: '2026-10-01', hasta: '2026-10-31', generado_at: '', nota: '' },
    ventas: { fc_pedidos: 10, fc_venta: 1000000, fc_neto: 826446, iva_debito: 173554, ii_ventas_fc: 0, zz_pedidos: 2, zz_venta: 50000, pct_fc: 95 },
    compras: {
      fc_compras: 3, fc_total: 600000, fc_neto: 495868, iva_credito: 104132, ii_compras: 0,
      percepcion_iva: 0, percepcion_iibb: 0, zz_compras: 0, zz_total: 0, pct_fc: 100,
    },
    posicion: { saldo_tecnico: 69422, iva_debito: 173554, iva_credito: 104132, percepciones_a_favor: 0 },
    ...(gastos !== undefined ? { gastos } : {}),
  };
}

async function abrirDetalle(datos: PosicionFiscal) {
  posicionFiscal.data = datos;
  const user = userEvent.setup();
  render(
    <MemoryRouter><VistaReportesGerenciales
      reporte={reporte} loading={false} error={null} sucursalSel={1} periodoSel={periodo}
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
  await user.click(screen.getByRole('button', { name: /Ver detalle completo/ }));
}

describe('VistaReportesGerenciales › gastos en la posición fiscal', () => {
  it('sin la clave gastos (RPC viejo o cacheado) no hay texto de gastos y no rompe', async () => {
    await abrirDetalle(fiscal());
    expect(screen.getByText('Posición IVA')).toBeInTheDocument();
    expect(screen.queryByText(/Gastos con factura A o M/)).not.toBeInTheDocument();
  });

  it('con cantidad 0 tampoco', async () => {
    await abrirDetalle(fiscal({ cantidad: 0, iva_credito: 0, percepcion_iva: 0, percepcion_iibb: 0 }));
    expect(screen.queryByText(/Gastos con factura A o M/)).not.toBeInTheDocument();
  });

  it('con gastos muestra la cantidad, el IVA y las dos percepciones', async () => {
    await abrirDetalle(fiscal({ cantidad: 4, iva_credito: 8678, percepcion_iva: 1000, percepcion_iibb: 250 }));
    const linea = screen.getByText(/Gastos con factura A o M/);
    expect(linea).toHaveTextContent('Gastos con factura A o M (4)');
    expect(linea).toHaveTextContent('IVA $9 K');
    expect(linea).toHaveTextContent('percepciones IVA $1 K');
    expect(linea).toHaveTextContent('IIBB $250');
  });
});
