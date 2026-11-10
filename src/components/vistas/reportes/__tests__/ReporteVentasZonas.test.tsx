/**
 * El export de "Por Zona".
 *
 * El componente se importa DIRECTO, no por ReportesContainer: los reportes son
 * lazy y un test que va por el container paga el `import()` del chunk en su
 * primera prueba, que es el flake del PR #514.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

interface HojaExcel {
  name: string;
  data: Record<string, unknown>[];
  columnWidths?: number[];
}

const mockUseQuery = vi.fn();
const mockCrearExcel = vi.fn<(hojas: HojaExcel[], filename: string) => Promise<void>>(() =>
  Promise.resolve()
);

vi.mock('../../../../hooks/queries/useVentasPorClienteQuery', () => ({
  useVentasPorClienteQuery: (desde: string, hasta: string, preventistaId: string | null) =>
    mockUseQuery(desde, hasta, preventistaId),
}));

vi.mock('../../../../utils/excel', () => ({
  createMultiSheetExcel: (hojas: HojaExcel[], filename: string) => mockCrearExcel(hojas, filename),
}));

vi.mock('../../../layout/LoadingSpinner', () => ({
  default: () => <div>cargando…</div>,
}));

import { ReporteVentasZonas } from '../ReporteVentasZonas';

const formatPrecio = (n: number): string => `$${n.toLocaleString('es-AR')}`;

function datos() {
  return {
    meta: {
      desde: '2026-06-01',
      hasta: '2026-08-20',
      preventista_id: null,
      preventista_nombre: 'Todos',
      sucursal_id: 1,
      sucursal_nombre: 'Tucuman',
      generado_at: '2026-08-20T17:00:00Z',
      criterio: 'Pedidos entregados…',
    },
    meses: ['2026-06'],
    vendedores: [],
    totales: { clientes: 3, pedidos: 12, total: 5000 },
    clientes: [],
    zonas: [
      { zona: 'ZONA 4 CHRISTIAN', clientes: 2, pedidos: 9, total: 4000, ticket_promedio: 444.44 },
      { zona: 'SIN ZONA', clientes: 1, pedidos: 3, total: 1000, ticket_promedio: 333.33 },
    ],
  };
}

function renderReporte() {
  return render(
    <ReporteVentasZonas
      desde="2026-06-01"
      hasta="2026-08-20"
      preventistaId={null}
      formatPrecio={formatPrecio}
    />
  );
}

describe('ReporteVentasZonas › export', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('exporta una hoja con la zona, el volumen y el ticket promedio', async () => {
    const user = userEvent.setup();
    mockUseQuery.mockReturnValue({ data: datos(), isLoading: false, error: null });
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    // El export hace un import() dinámico: hay que esperar la llamada, no leerla en el acto (#1006).
    await waitFor(() => expect(mockCrearExcel).toHaveBeenCalledTimes(1));
    const [hojas, nombreArchivo] = mockCrearExcel.mock.calls[0];

    expect(hojas.map((h) => h.name)).toEqual(['Por zona']);
    expect(hojas[0].data[0]).toMatchObject({
      Zona: 'ZONA 4 CHRISTIAN',
      Clientes: 2,
      Pedidos: 9,
      Total: 4000,
      'Ticket promedio': 444.44,
    });
    // Fracción, no porcentaje: el 0-1 lo formatea Excel como %.
    expect(hojas[0].data[0]['% del total']).toBeCloseTo(0.8);

    expect(nombreArchivo).toBe('ventas-por-zona-Todos-2026-06-01_2026-08-20');
  });

  it('el nombre del archivo dice de qué preventista es, sin espacios', async () => {
    const user = userEvent.setup();
    const d = datos();
    d.meta.preventista_nombre = 'Christian Perez';
    mockUseQuery.mockReturnValue({ data: d, isLoading: false, error: null });
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    await waitFor(() => expect(mockCrearExcel).toHaveBeenCalledTimes(1));
    const [, nombreArchivo] = mockCrearExcel.mock.calls[0];
    expect(nombreArchivo).toBe('ventas-por-zona-Christian_Perez-2026-06-01_2026-08-20');
  });

  it('sin ventas no hay botón que apretar', () => {
    const d = datos();
    d.zonas = [];
    mockUseQuery.mockReturnValue({ data: d, isLoading: false, error: null });
    renderReporte();

    expect(screen.queryByRole('button', { name: /Exportar a Excel/i })).not.toBeInTheDocument();
  });
});

describe('ReporteVentasZonas › zonas homónimas (REP-6) y formato (REP-3)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  function datosHomonimas() {
    const d = datos();
    d.zonas = [
      { zona_id: 11, zona: 'CENTRO', sucursal: 'Tucumán', clientes: 2, pedidos: 9, total: 4000, ticket_promedio: 444.44 },
      { zona_id: 22, zona: 'CENTRO', sucursal: 'Taco Pozo', clientes: 1, pedidos: 3, total: 1000, ticket_promedio: 333.33 },
    ] as never;
    return d;
  }

  it('dos zonas con el mismo nombre se distinguen por sucursal y no chocan en la key', () => {
    const errores = vi.spyOn(console, 'error').mockImplementation(() => {});
    mockUseQuery.mockReturnValue({ data: datosHomonimas(), isLoading: false, error: null });
    renderReporte();

    expect(screen.getByText('CENTRO (Tucumán)')).toBeInTheDocument();
    expect(screen.getByText('CENTRO (Taco Pozo)')).toBeInTheDocument();
    // React avisa por consola de dos hijos con la misma key.
    expect(errores.mock.calls.flat().join(' ')).not.toMatch(/same key/i);
    errores.mockRestore();
  });

  it('una zona sin homónima se lee sólo por su nombre', () => {
    mockUseQuery.mockReturnValue({ data: datos(), isLoading: false, error: null });
    renderReporte();
    expect(screen.getByText('ZONA 4 CHRISTIAN')).toBeInTheDocument();
  });

  it('el Excel lleva la etiqueta con sucursal y el formato de las columnas', async () => {
    const user = userEvent.setup();
    mockUseQuery.mockReturnValue({ data: datosHomonimas(), isLoading: false, error: null });
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));
    await waitFor(() => expect(mockCrearExcel).toHaveBeenCalledTimes(1));
    const [hojas] = mockCrearExcel.mock.calls[0];
    expect(hojas[0].data.map((f) => f.Zona)).toEqual(['CENTRO (Tucumán)', 'CENTRO (Taco Pozo)']);
    expect((hojas[0] as unknown as { formatos: Record<string, string> }).formatos).toMatchObject({
      '% del total': 'porcentaje',
      Total: 'moneda',
    });
  });
});
