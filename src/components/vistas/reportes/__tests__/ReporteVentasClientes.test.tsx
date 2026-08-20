/**
 * Tests de la pestaña "Por Cliente" de Reportes.
 *
 * Cubren justamente lo que la versión anterior hacía mal:
 *   1) lista TODOS los clientes (antes cortaba en 30 con un slice);
 *   2) la zona de la ficha es una columna propia por fila;
 *   3) los totales del pie salen del RPC, no de sumar las filas visibles;
 *   4) el desglose por mes aparece sólo si el rango abarca más de un mes;
 *   5) los pedidos sin cliente se muestran con su aviso, en vez de desaparecer.
 *
 * El hook se mockea: el cuadre de los números contra prod ya lo garantiza el
 * RPC (mig 197), acá se verifica el render.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, within } from '@testing-library/react';
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

import { ReporteVentasClientes } from '../ReporteVentasClientes';
import type { VentasPorCliente } from '../../../../hooks/queries/useVentasPorClienteQuery';

const formatPrecio = (n: number): string => `$${n.toLocaleString('es-AR')}`;

function datos(overrides: Partial<VentasPorCliente> = {}): VentasPorCliente {
  return {
    meta: {
      desde: '2026-06-01',
      hasta: '2026-08-20',
      preventista_id: 'p-1',
      preventista_nombre: 'Christian',
      sucursal_id: 1,
      sucursal_nombre: 'Tucuman',
      generado_at: '2026-08-20T17:00:00Z',
      criterio: 'Pedidos entregados…',
    },
    meses: ['2026-06', '2026-07'],
    vendedores: [{ id: 'p-1', nombre: 'Christian', pedidos: 10, total: 3000 }],
    totales: { clientes: 2, pedidos: 10, total: 3000 },
    clientes: [
      {
        cliente_id: 11,
        codigo: 101,
        nombre: 'BENJAMIN PAZ 298',
        zona: 'ZONA 4 CHRISTIAN',
        pedidos: 7,
        total: 2000,
        por_mes: { '2026-06': 1200, '2026-07': 800 },
      },
      {
        cliente_id: 22,
        codigo: 102,
        nombre: 'Escuela Avellaneda',
        zona: 'ZONA 1 MARCELO',
        pedidos: 3,
        total: 1000,
        por_mes: { '2026-06': 1000 },
      },
    ],
    zonas: [
      { zona: 'ZONA 4 CHRISTIAN', clientes: 1, pedidos: 7, total: 2000, ticket_promedio: 285.71 },
      { zona: 'ZONA 1 MARCELO', clientes: 1, pedidos: 3, total: 1000, ticket_promedio: 333.33 },
    ],
    ...overrides,
  };
}

function renderReporte(): void {
  render(
    <ReporteVentasClientes
      desde="2026-06-01"
      hasta="2026-08-20"
      preventistaId="p-1"
      formatPrecio={formatPrecio}
    />
  );
}

beforeEach(() => {
  mockUseQuery.mockReset();
  mockCrearExcel.mockClear();
});

describe('ReporteVentasClientes', () => {
  it('le pasa período y preventista al hook', () => {
    mockUseQuery.mockReturnValue({ data: datos(), isLoading: false, error: null });
    renderReporte();
    expect(mockUseQuery).toHaveBeenCalledWith('2026-06-01', '2026-08-20', 'p-1');
  });

  it('muestra la zona de la ficha en su propia columna, por fila', () => {
    mockUseQuery.mockReturnValue({ data: datos(), isLoading: false, error: null });
    renderReporte();

    const fila = screen.getByText('Escuela Avellaneda').closest('tr');
    expect(fila).not.toBeNull();
    // La venta fuera de zona es la lectura del informe: el cliente es de una
    // zona de MARCELO aunque la venta sea de Christian.
    expect(within(fila as HTMLElement).getByText('ZONA 1 MARCELO')).toBeInTheDocument();
    expect(screen.getByRole('columnheader', { name: /Zona/i })).toBeInTheDocument();
  });

  it('lista TODOS los clientes, sin cortar en 30', () => {
    const muchos = Array.from({ length: 45 }, (_, i) => ({
      cliente_id: i + 1,
      codigo: i + 1,
      nombre: `Cliente ${i + 1}`,
      zona: 'ZONA 1 CHRISTIAN',
      pedidos: 1,
      total: 100,
      por_mes: { '2026-06': 100 },
    }));
    mockUseQuery.mockReturnValue({
      data: datos({ clientes: muchos, totales: { clientes: 45, pedidos: 45, total: 4500 } }),
      isLoading: false,
      error: null,
    });
    renderReporte();

    expect(screen.getByText('Cliente 45')).toBeInTheDocument();
    expect(screen.getByText('Cliente 31')).toBeInTheDocument();
  });

  it('los totales del pie salen del RPC y no de sumar lo que se ve', () => {
    // totales.total (3000) coincide con las filas acá, pero el pie debe leer el
    // campo del RPC: es la única fuente que no depende de la paginación.
    mockUseQuery.mockReturnValue({ data: datos(), isLoading: false, error: null });
    renderReporte();

    expect(screen.getByText('TOTAL (2 clientes)')).toBeInTheDocument();
    const pie = screen.getByText('TOTAL (2 clientes)').closest('tr') as HTMLElement;
    expect(within(pie).getByText('$3.000')).toBeInTheDocument();
    expect(within(pie).getByText('10')).toBeInTheDocument();
  });

  it('el desglose por mes está oculto por defecto y se puede prender', async () => {
    const user = userEvent.setup();
    mockUseQuery.mockReturnValue({ data: datos(), isLoading: false, error: null });
    renderReporte();

    expect(screen.queryByRole('columnheader', { name: 'Jun 26' })).not.toBeInTheDocument();
    await user.click(screen.getByLabelText(/Desglose por mes/i));
    expect(screen.getByRole('columnheader', { name: 'Jun 26' })).toBeInTheDocument();
    expect(screen.getByRole('columnheader', { name: 'Jul 26' })).toBeInTheDocument();
  });

  it('no ofrece el desglose si el rango tiene un solo mes', () => {
    mockUseQuery.mockReturnValue({
      data: datos({ meses: ['2026-07'] }),
      isLoading: false,
      error: null,
    });
    renderReporte();
    expect(screen.queryByLabelText(/Desglose por mes/i)).not.toBeInTheDocument();
  });

  it('muestra los pedidos sin cliente con su aviso, en vez de esconderlos', () => {
    mockUseQuery.mockReturnValue({
      data: datos({
        clientes: [
          {
            cliente_id: null,
            codigo: null,
            nombre: '(sin cliente asignado)',
            zona: 'SIN ZONA',
            pedidos: 3,
            total: 83750,
            por_mes: { '2026-06': 83750 },
          },
        ],
        totales: { clientes: 1, pedidos: 3, total: 83750 },
      }),
      isLoading: false,
      error: null,
    });
    renderReporte();

    expect(screen.getByText('(sin cliente asignado)')).toBeInTheDocument();
    expect(screen.getByText('sin ficha')).toBeInTheDocument();
    expect(screen.getByText(/coincida con el total de ventas/i)).toBeInTheDocument();
  });

  it('el botón "Ver ficha" manda el id del cliente como string', async () => {
    const user = userEvent.setup();
    const onVerCliente = vi.fn();
    mockUseQuery.mockReturnValue({ data: datos(), isLoading: false, error: null });
    render(
      <ReporteVentasClientes
        desde="2026-06-01"
        hasta="2026-08-20"
        preventistaId="p-1"
        formatPrecio={formatPrecio}
        onVerCliente={onVerCliente}
      />
    );

    const fila = screen.getByText('BENJAMIN PAZ 298').closest('tr') as HTMLElement;
    await user.click(within(fila).getByRole('button', { name: /Ver ficha/i }));
    // String, no number: `clientes.id` es bigint y las dos fuentes lo tipan distinto.
    expect(onVerCliente).toHaveBeenCalledWith('11');
  });

  it('exporta dos hojas: una por cliente con la zona y una por zona', async () => {
    const user = userEvent.setup();
    mockUseQuery.mockReturnValue({ data: datos(), isLoading: false, error: null });
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    expect(mockCrearExcel).toHaveBeenCalledTimes(1);
    const [hojas, nombreArchivo] = mockCrearExcel.mock.calls[0];

    expect(hojas.map((h) => h.name)).toEqual(['Por cliente', 'Por zona']);

    // El Excel siempre lleva el desglose por mes, aunque en pantalla esté oculto.
    expect(hojas[0].data[0]).toMatchObject({
      '#': 1,
      Cliente: 'BENJAMIN PAZ 298',
      Zona: 'ZONA 4 CHRISTIAN',
      Pedidos: 7,
      Total: 2000,
      'Jun 26': 1200,
      'Jul 26': 800,
    });
    // Un cliente que no compró en julio va con 0, no con la celda ausente.
    expect(hojas[0].data[1]).toMatchObject({ Cliente: 'Escuela Avellaneda', 'Jul 26': 0 });

    expect(hojas[1].data[0]).toMatchObject({
      Zona: 'ZONA 4 CHRISTIAN',
      Clientes: 1,
      Pedidos: 7,
      Total: 2000,
    });

    // El nombre del archivo dice de quién y de cuándo es, sin espacios.
    expect(nombreArchivo).toBe('ventas-por-cliente-Christian-2026-06-01_2026-08-20');
  });

  it('muestra el error del RPC en vez de una tabla vacía', () => {
    mockUseQuery.mockReturnValue({
      data: undefined,
      isLoading: false,
      error: new Error('Acceso denegado: se requiere rol admin o encargado'),
    });
    renderReporte();
    expect(screen.getByText(/Acceso denegado/i)).toBeInTheDocument();
  });

  it('avisa cuando no hay ventas en el período', () => {
    mockUseQuery.mockReturnValue({
      data: datos({ clientes: [], zonas: [], totales: { clientes: 0, pedidos: 0, total: 0 } }),
      isLoading: false,
      error: null,
    });
    renderReporte();
    expect(screen.getByText(/No hay ventas entregadas/i)).toBeInTheDocument();
  });
});
