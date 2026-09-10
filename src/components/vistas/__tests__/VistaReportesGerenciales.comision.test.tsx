/**
 * Las dos comisiones de la tabla de vendedores.
 *
 * EL BUG QUE FIJA
 * ---------------
 * La mig 207 hizo que el % por defecto dependa del rol: un admin o un encargado
 * comisionan 0%. Pero en el gerencial había DOS cálculos de comisión y sólo uno
 * miraba las reglas:
 *
 *   · el KPI de arriba usaba `calcular_comisiones` — correcto
 *   · la tabla de vendedores hacía `base × comPct / 100` — el mismo % para todos
 *
 * En agosto la misma pantalla mostraba $804.668 en el KPI y $926.042 en el pie
 * de la tabla. La diferencia, $121.374, eran seis no-preventistas cobrando un
 * 2% que la liquidación real dice que es 0.
 *
 * El bug estaba latente desde antes: mientras TODOS cobraban 2%, multiplicar
 * por un % plano daba el mismo número. La mig 207 lo destapó.
 *
 * La vista se importa DIRECTO, no por el container (lazy, flake del PR #514).
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
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
// Se usa el MISMO formateador que la vista para armar las expectativas.
import { money } from '../reportes-gerenciales/formato';
import type { ReporteGerencial } from '../../../hooks/queries/useReporteGerencialQuery';

/**
 * `money` es Intl y separa con espacio DURO (U+00A0). testing-library normaliza
 * el texto del DOM —colapsa \s, que incluye el duro— pero NO el string que uno
 * le pasa, así que compararlo crudo nunca matchea. Se normaliza igual.
 */
const $$ = (x: number): string => money(x).replace(/\s/g, ' ');

/** Un preventista y un encargado, como en los datos reales de agosto. */
const VENDEDORES = [
  { id: 'u-juan', nombre: 'Juan', rol: 'preventista', pedidos: 100, venta: 15121320, margen_comercial: 3000000, bonif: 200000, base_nc: 15121320 },
  { id: 'u-jony', nombre: 'Jony', rol: 'encargado', pedidos: 20, venta: 2964100, margen_comercial: 600000, bonif: 40000, base_nc: 2964100 },
];

function reporte(): ReporteGerencial {
  return {
    meta: {
      sucursal_id: 1, sucursal_nombre: 'Tucumán', desde: '2026-08-01', hasta: '2026-08-31',
      generado_at: '2026-09-08T12:00:00Z', incluye_no_entregados: false,
    },
    kpis: {
      venta: 18085420, pedidos: 120, clientes: 60, ticket: 150000, clientes_nuevos: 2,
      cmv: 12000000, bonif: 240000, unidades: 5000, unidades_bonif: 100,
      margen_comercial: 3600000, margen_neto: 3360000, base_comision: 18085420,
      comision_pct_default: 2, mermas: 50000, compras: 9000000, ingreso_sin_costo: 0,
    },
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

/** Lo que devuelve `calcular_comisiones`: Jony es encargado, cobra 0. */
const COMISION_REAL = [
  { id: 'u-juan', nombre: 'Juan', comision: 302426 },
  { id: 'u-jony', nombre: 'Jony', comision: 0 },
];

function renderVista(comisionPorVendedor: { id: string; nombre: string; comision: number }[] | null = COMISION_REAL) {
  return render(
    <VistaReportesGerenciales
      reporte={reporte()}
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
      comisionCalculada={302426}
      comisionPorVendedor={comisionPorVendedor}
    />
  );
}

async function abrirDetalle(user: ReturnType<typeof userEvent.setup>) {
  const toggle = screen.getAllByRole('button').find(b => /detalle/i.test(b.textContent ?? ''));
  if (toggle) await user.click(toggle);
}

function filaDe(nombre: string): HTMLElement {
  return screen.getByText(nombre).closest('tr') as HTMLElement;
}

describe('VistaReportesGerenciales › comisión por vendedor', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('un encargado cobra 0 en la columna de lo que se liquida', async () => {
    const user = userEvent.setup();
    renderVista();
    await abrirDetalle(user);

    // Antes esta celda mostraba $59.282: base_nc × 2%, sin mirar el rol.
    const jony = filaDe('Jony');
    expect(within(jony).getByText($$(0))).toBeInTheDocument();
  });

  it('el simulador sigue mostrando su número, en su propia columna', async () => {
    const user = userEvent.setup();
    renderVista();
    await abrirDetalle(user);

    // 2.964.100 × 2% = 59.282. Sigue estando, pero como simulación.
    const jony = filaDe('Jony');
    expect(within(jony).getByText($$(59282))).toBeInTheDocument();
  });

  it('un preventista tiene el mismo número en las dos columnas', async () => {
    const user = userEvent.setup();
    renderVista();
    await abrirDetalle(user);

    // 15.121.320 × 2% = 302.426, que es lo que devuelve el RPC para Juan.
    const juan = filaDe('Juan');
    expect(within(juan).getAllByText($$(302426))).toHaveLength(2);
  });

  it('la columna del simulador dice que es una simulación', async () => {
    const user = userEvent.setup();
    renderVista();
    await abrirDetalle(user);

    expect(screen.getByText(/Simulado 2%/)).toBeInTheDocument();
  });

  it('cambiar el % del simulador NO toca lo que se liquida', async () => {
    const user = userEvent.setup();
    renderVista();
    await abrirDetalle(user);

    const input = screen.getByLabelText('Porcentaje de comisión a simular');
    await user.clear(input);
    await user.type(input, '5');

    // La real no se mueve: sale de las reglas, no del input.
    expect(within(filaDe('Juan')).getByText($$(302426))).toBeInTheDocument();
    expect(within(filaDe('Jony')).getByText($$(0))).toBeInTheDocument();
  });

  // Es lo que hacía que la pantalla se contradijera consigo misma.
  it('el pie de la columna real cuadra con el KPI, no con el simulado', async () => {
    const user = userEvent.setup();
    renderVista();
    await abrirDetalle(user);

    // 'Total' dejo de ser unico en la pantalla: las cards de Mermas y Compras
    // tambien cierran con una fila Total. Se acota a la tabla de comisiones,
    // que es la unica con la columna 'Vendedor'.
    const tabla = screen.getByText('Vendedor').closest('table') as HTMLElement;
    const total = within(tabla).getByText('Total').closest('tr') as HTMLElement;
    // Real: 302.426 + 0. Simulado: (15.121.320 + 2.964.100) × 2% = 361.708.
    expect(within(total).getByText($$(302426))).toBeInTheDocument();
    expect(within(total).getByText($$(361708))).toBeInTheDocument();
  });

  // El motivo de la mig 209: antes el cruce era por nombre y dos homónimos
  // compartían la celda de comisión sin que nadie se enterara.
  it('cruza por ID, no por nombre: dos homónimos no comparten comisión', async () => {
    const user = userEvent.setup();
    render(
      <VistaReportesGerenciales
        reporte={{
          ...reporte(),
          vendedores: [
            { ...VENDEDORES[0], id: 'u-juan-1', nombre: 'Juan' },
            { ...VENDEDORES[1], id: 'u-juan-2', nombre: 'Juan' },
          ],
        } as unknown as ReporteGerencial}
        loading={false} error={null} sucursalSel={1} periodoSel={periodo}
        opcionesSucursal={[{ id: 1, nombre: 'Tucumán' }]} opcionesPeriodo={[periodo]}
        onSucursal={vi.fn()} onPeriodo={vi.fn()} onRango={vi.fn()}
        incluirNoEntregados={false} onIncluirNoEntregados={vi.fn()}
        comparar={false} onComparar={vi.fn()}
        metas={null} metasEditable={false} onGuardarMeta={vi.fn()} guardandoMeta={false}
        analisis={null}
        comisionCalculada={302426}
        comisionPorVendedor={[
          { id: 'u-juan-1', nombre: 'Juan', comision: 302426 },
          { id: 'u-juan-2', nombre: 'Juan', comision: 0 },
        ]}
      />
    );
    await abrirDetalle(user);

    // Los dos se llaman igual; cada uno tiene que ver SU número. Se mira la
    // celda de la columna real por posición (Vendedor, Venta, Mg neto, % neto,
    // Comisión, Simulado) y no por texto: el primero tiene el mismo importe en
    // las dos columnas y `getByText` encontraría dos.
    const filas = screen.getAllByText('Juan').map(e => e.closest('tr') as HTMLElement);
    expect(filas).toHaveLength(2);
    const comisionReal = (fila: HTMLElement) =>
      within(fila).getAllByRole('cell')[4].textContent?.replace(/\s/g, ' ');
    expect(comisionReal(filas[0])).toBe($$(302426));
    expect(comisionReal(filas[1])).toBe($$(0));
  });

  it('mientras la comisión real no llegó, se muestra sólo el simulador', async () => {
    const user = userEvent.setup();
    renderVista(null);
    await abrirDetalle(user);

    expect(screen.queryByText(/Simulado/)).not.toBeInTheDocument();
    // Y la única columna es la de siempre, sin fingir que es la liquidación.
    expect(within(filaDe('Jony')).getByText($$(59282))).toBeInTheDocument();
  });
});
