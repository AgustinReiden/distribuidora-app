/**
 * El export fraccionado del dashboard gerencial.
 *
 * La vista se importa DIRECTO, no por `ReportesGerencialesContainer`: allá se
 * carga lazy y un test que va por el container paga el `import()` del chunk en
 * su primera prueba, que es el flake del PR #514.
 *
 * El armado de las filas se prueba en `utils/exportGerencial.test.ts`; acá se
 * prueba el cableado: que cada botón baje SU bloque, con su nombre de archivo,
 * y que la hoja de metadatos vaya en todos.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { MemoryRouter } from 'react-router-dom';
import { render, screen } from '@testing-library/react';
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
function renderVista(r: ReporteGerencial | null = reporte()) {
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
      comparar={false}
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

describe('VistaReportesGerenciales › export fraccionado', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('el resumen se baja solo, con su propio archivo', async () => {
    const user = userEvent.setup();
    renderVista();

    await user.click(screen.getByRole('button', { name: /Descargar los KPIs/i }));

    const [hojas, filename] = mockCrearExcel.mock.calls[0];
    expect(hojas.map(h => h.name)).toEqual(['Info', 'Resumen']);
    expect(filename).toBe('gerencial-resumen-Tucumán-2026-08-01_2026-08-31');
  });

  it('cada bloque baja SU archivo, no el dashboard entero', async () => {
    const user = userEvent.setup();
    renderVista();
    await abrirDetalle(user);

    await user.click(screen.getByRole('button', { name: /Descargar Top productos/i }));

    const [hojas, filename] = mockCrearExcel.mock.calls[0];
    expect(hojas.map(h => h.name)).toEqual(['Info', 'Top productos']);
    expect(filename).toBe('gerencial-top-productos-Tucumán-2026-08-01_2026-08-31');
    expect(hojas[1].data[0]).toMatchObject({ Producto: 'Coca 2L', Unidades: 200 });
  });

  // Es el punto del pedido: varios archivos sueltos en una carpeta, y cada uno
  // tiene que poder interpretarse solo.
  it('TODOS los archivos llevan la hoja de metadatos', async () => {
    const user = userEvent.setup();
    renderVista();
    await abrirDetalle(user);

    const botones = screen.getAllByRole('button').filter(b =>
      /^Descargar /.test(b.getAttribute('aria-label') ?? b.getAttribute('title') ?? '')
    );
    expect(botones.length).toBeGreaterThan(4);

    for (const b of botones) {
      mockCrearExcel.mockClear();
      await user.click(b);
      const [hojas] = mockCrearExcel.mock.calls[0];
      expect(hojas[0].name).toBe('Info');
    }
  });

  it('la hoja de metadatos dice sucursal, rango y criterio', async () => {
    const user = userEvent.setup();
    renderVista();

    await user.click(screen.getByRole('button', { name: /Descargar los KPIs/i }));

    const [hojas] = mockCrearExcel.mock.calls[0];
    const info = Object.fromEntries(hojas[0].data.map(f => [f.Campo, f.Valor]));
    expect(info['Sucursal']).toBe('Tucumán');
    expect(info['Desde']).toBe('2026-08-01');
    expect(info['Criterio de venta']).toContain('Sólo pedidos entregados');
  });

  it('"Todo" junta los bloques en un archivo con una sola hoja Info', async () => {
    const user = userEvent.setup();
    renderVista();

    await user.click(screen.getByRole('button', { name: /Descargar todos los bloques/i }));

    const [hojas, filename] = mockCrearExcel.mock.calls[0];
    expect(hojas.filter(h => h.name === 'Info')).toHaveLength(1);
    expect(hojas.length).toBeGreaterThan(8);
    expect(filename).toBe('gerencial-todo-Tucumán-2026-08-01_2026-08-31');
  });

  describe('las dos formas del payload que rompen el export', () => {
    it('la serie diaria viene en TUPLAS y sale con encabezados de verdad', async () => {
      const user = userEvent.setup();
      renderVista();
      await abrirDetalle(user);

      await user.click(screen.getByRole('button', { name: /Descargar Evolución/i }));

      const [hojas] = mockCrearExcel.mock.calls[0];
      const serie = hojas.find(h => h.name === 'Serie diaria')!;
      // Sin mapear, los headers saldrían '0' y '1'.
      expect(Object.keys(serie.data[0])).toEqual(['Fecha', 'Venta']);
    });

    it('un KPI opcional ausente no escribe undefined en la celda', async () => {
      // `margen_real` y `venta_real` no vienen en respuestas cacheadas de
      // versiones viejas del RPC.
      const r = reporte();
      delete (r.kpis as unknown as Record<string, unknown>).margen_real;
      delete (r.kpis as unknown as Record<string, unknown>).venta_real;

      const user = userEvent.setup();
      renderVista(r);
      await user.click(screen.getByRole('button', { name: /Descargar los KPIs/i }));

      const [hojas] = mockCrearExcel.mock.calls[0];
      const filas = hojas[1].data;
      expect(filas.every(f => f.Valor !== undefined)).toBe(true);
      const info = Object.fromEntries(filas.map(f => [f.Indicador, f.Valor]));
      expect(info['Margen real']).toBe(40000); // el fallback de la pantalla
    });
  });

  it('sin reporte no hay nada que bajar', () => {
    renderVista(null);
    expect(screen.queryByRole('button', { name: /Descargar los KPIs/i })).not.toBeInTheDocument();
  });
});
