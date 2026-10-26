/**
 * La sección "Combos" del reporte gerencial (#1193): el KPI informativo, la
 * columna "Desc. combos" de la evolución mensual y el detalle por producto.
 * El descuento NO se resta de ningún margen: se prueba que el KPI de margen
 * neto no cambie con o sin combos.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { MemoryRouter } from 'react-router-dom';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

interface HojaExcel {
  name: string;
  data: Record<string, unknown>[];
  columnWidths?: number[];
}

const mockCrearExcel = vi.fn<(hojas: HojaExcel[], filename: string) => Promise<void>>(() =>
  Promise.resolve()
);

// La vista arrastra el barrel de hooks/queries (vía ModalAlertaDetalle), que
// crea el cliente de Supabase al importarse. Los tests corren SIN .env a
// propósito, así que se mockea en la raíz de la cadena.
vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn() },
}));

vi.mock('../../../utils/excel', () => ({
  createMultiSheetExcel: (hojas: HojaExcel[], filename: string) => mockCrearExcel(hojas, filename),
}));

// Los gráficos son chart.js: montarlos en jsdom no aporta nada al export y
// obliga a un canvas.
vi.mock('../reportes-gerenciales/charts', () => ({
  EvolucionChart: () => <div />, DiarioChart: () => <div />, VendedoresChart: () => <div />,
  CategoriasChart: () => <div />, WaterfallChart: () => <div />, CobranzaDonut: () => <div />,
  BonifPromosChart: () => <div />, MermasMotivoChart: () => <div />,
}));

// Mock completo, sin `importOriginal`: el módulo real importa `lib/supabase`,
// que exige las env vars — y los tests corren SIN .env a propósito.
vi.mock('../../../hooks/queries/useReporteGerencialQuery', () => ({
  usePosicionFiscalQuery: () => ({ data: null, isLoading: false }),
}));

import VistaReportesGerenciales from '../VistaReportesGerenciales';
import type { ReporteGerencial } from '../../../hooks/queries/useReporteGerencialQuery';

function reporte(over: Partial<ReporteGerencial> = {}): ReporteGerencial {
  return {
    meta: {
      sucursal_id: 1, sucursal_nombre: 'Tucumán', desde: '2026-08-01', hasta: '2026-08-31',
      generado_at: '2026-09-08T12:00:00Z', incluye_no_entregados: false,
    },
    kpis: {
      venta: 100000, pedidos: 50, clientes: 20, ticket: 2000, clientes_nuevos: 3,
      cmv: 60000, bonif: 5000, unidades: 500, unidades_bonif: 25,
      margen_comercial: 40000, margen_neto: 35000, base_comision: 95000,
      comision_pct_default: 2, mermas: 1000, compras: 70000, ingreso_sin_costo: 0,
      venta_real: 90000, margen_real: 38000,
    },
    mensual: [{ mes: '2026-08', pedidos: 50, venta: 100000, clientes: 20, ticket: 2000, cmv: 60000, bonif: 5000, mermas: 1000, compras: 70000 }],
    vendedores: [{ nombre: 'Christian', rol: 'preventista', pedidos: 30, venta: 60000, margen_comercial: 24000, bonif: 3000, base_nc: 58000 }],
    categorias: [{ categoria: 'Bebidas', venta: 70000, margen_comercial: 28000, bonif: 3500, sin_costo: false }],
    top_productos: [{ nombre: 'Coca 2L', unidades: 200, venta: 40000, margen: 16000 }],
    top_clientes: [{ cliente: 'Kiosco Luna', pedidos: 12, venta: 25000 }],
    cobranza: { formas: [{ forma_pago: 'efectivo', monto: 80000 }], cobrado: 80000, pendiente: 20000 },
    serie_diaria: [['2026-08-01', 3000]],
    flags: { ingreso_sin_costo: 0, pct_sin_costo: 0 },
    mermas_motivo: [{ motivo: 'rotura', unidades: 10, costo: 900, clasificacion: 'perdida' }],
    bonif_promos: [{ promocion: '2x1', producto: 'Coca 2L', unidades: 20, es_fraccion: false, costo: 2000, valor_venta: 4000 }],
    alertas: [{ severidad: 'warning', codigo: 'x', titulo: 'Deuda vencida', detalle: 'd', valor: 1, seccion: 'sec-cobranza' }],
    ...over,
  } as ReporteGerencial;
}

const periodo = {
  key: 'ago', label: 'Agosto 2026', desde: '2026-08-01', hasta: '2026-08-31',
  esMes: true, periodoMes: '2026-08-01', parcial: false,
};

/**
 * `null` significa "sin reporte". No se usa `undefined` porque pasarlo dispara
 * el valor por defecto del parámetro y terminaría renderizando el reporte
 * completo — que es justo lo contrario de lo que quiere ese caso.
 */
function renderVista(r: ReporteGerencial | null = reporte(), comparar = false) {
  // Las cards llevan links "Ver detalle" a /reportes: <Link> exige un Router.
  return render(
    <MemoryRouter><VistaReportesGerenciales
      reporte={r ?? undefined}
      loading={false}
      error={null}
      sucursalSel={1}
      periodoSel={periodo}
      opcionesSucursal={[{ id: 1, nombre: 'Tucumán' }]}
      opcionesPeriodo={[periodo]}
      onSucursal={vi.fn()}
      onPeriodo={vi.fn()}
      onRango={vi.fn()}
      incluirNoEntregados={false}
      onIncluirNoEntregados={vi.fn()}
      comparar={comparar}
      onComparar={vi.fn()}
      metas={null}
      metasEditable={false}
      onGuardarMeta={vi.fn()}
      guardandoMeta={false}
      analisis={null}
      {...({} as Record<string, unknown>)}
    /></MemoryRouter>
  );
}

/** El detalle (categorías, top, cobranza…) monta recién al abrir el colapsable. */
async function abrirDetalle(user: ReturnType<typeof userEvent.setup>) {
  const toggle = screen.getAllByRole('button').find(b => /detalle/i.test(b.textContent ?? ''));
  if (toggle) await user.click(toggle);
}


const combos = {
  meta: { sucursal_id: 1, sucursal_nombre: 'Tucumán', desde: '2026-08-01', hasta: '2026-08-31' },
  kpis: { combos_vendidos: 2, venta: 18400, descuento: 3680, costo: 9033, ingreso_real: 18400, margen: 9367, descuento_anterior: 1840, venta_anterior: 9200 },
  combos: [{
    combo_id: 7, nombre: 'Fernet + Coca', sucursal_id: 1, combos_vendidos: 2, venta: 18400, descuento: 3680,
    costo: 9033, ingreso_real: 18400, margen: 9367,
    productos: [
      { producto_id: 1, producto: 'Fernet Branca 750', unidades: 2, venta: 10000, descuento: 2000, costo: 5831, margen: 4169 },
      { producto_id: 2, producto: 'Coca 2,25', unidades: 3, venta: 8400, descuento: 1680, costo: 3202, margen: 5198 },
    ],
  }],
  mensual: [{ mes: '2026-08', combo_id: 7, combos: 2, venta: 18400, descuento: 3680, margen: 9367 }],
  semanal: [{ semana: '2026-08-03', combo_id: 7, combos: 2, venta: 18400, descuento: 3680, margen: 9367 }],
};

describe('VistaReportesGerenciales › combos', () => {
  beforeEach(() => { vi.clearAllMocks(); });

  it('muestra el KPI informativo con % de la venta y el delta contra el período anterior', () => {
    renderVista(reporte({ combos, comparativo: { ...reporte().kpis, desde: '2026-07-01', hasta: '2026-07-31' } }), true);
    expect(screen.getByText('Descuento por combos')).toBeInTheDocument();
    expect(document.body.textContent).toMatch(/3,7%\s*de la venta · 2 combos · informativo/);
    // 3680 vs 1840: +100%
    expect(document.body.textContent).toMatch(/▲\s*100,0%/);
  });

  it('no suma ni resta el descuento al margen neto', () => {
    renderVista(reporte({ combos }));
    // margen_neto 35000 sobre venta 100000: el mismo con o sin la sección.
    expect(screen.getByText(/35,0%/)).toBeInTheDocument();
  });

  it('sin combos vendidos no hay KPI ni sección', () => {
    renderVista(reporte());
    expect(screen.queryByText('Descuento por combos')).not.toBeInTheDocument();
  });

  it('abre un combo y muestra cada producto con su precio prorrateado', async () => {
    const user = userEvent.setup();
    renderVista(reporte({ combos }));
    await abrirDetalle(user);
    expect(screen.getByText('Combos')).toBeInTheDocument();
    expect(screen.queryByText('Fernet Branca 750')).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: /Ver los productos de Fernet \+ Coca/ }));
    expect(screen.getByText('Fernet Branca 750')).toBeInTheDocument();
    expect(screen.getByText('Coca 2,25')).toBeInTheDocument();
  });

  it('la evolución mensual suma la columna Desc. combos', async () => {
    const user = userEvent.setup();
    renderVista(reporte({ combos }));
    await abrirDetalle(user);
    expect(screen.getByRole('columnheader', { name: 'Desc. combos' })).toBeInTheDocument();
  });

  it('el export de combos baja su bloque', async () => {
    const user = userEvent.setup();
    renderVista(reporte({ combos }));
    await abrirDetalle(user);
    await user.click(screen.getByRole('button', { name: /Descargar Combos en Excel/i }));
    await waitFor(() => expect(mockCrearExcel).toHaveBeenCalledTimes(1));
    const [hojas, nombre] = mockCrearExcel.mock.calls[0];
    expect(nombre).toContain('gerencial-combos-');
    expect(hojas.map(h => h.name)).toContain('Combos por producto');
  });
});
