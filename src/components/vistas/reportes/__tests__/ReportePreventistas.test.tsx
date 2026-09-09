/** El export de "Por Preventista". Componente importado directo (ver #514). */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import type { ComponentProps } from 'react';
import userEvent from '@testing-library/user-event';

interface HojaExcel {
  name: string;
  data: Record<string, unknown>[];
  columnWidths?: number[];
}

const mockCrearExcel = vi.fn<(hojas: HojaExcel[], filename: string) => Promise<void>>(() =>
  Promise.resolve()
);

vi.mock('../../../../utils/excel', () => ({
  createMultiSheetExcel: (hojas: HojaExcel[], filename: string) => mockCrearExcel(hojas, filename),
}));

vi.mock('../../../layout/LoadingSpinner', () => ({
  default: () => <div>cargando…</div>,
}));

import { ReportePreventistas } from '../ReportePreventistas';

const formatPrecio = (n: number): string => `$${n.toLocaleString('es-AR')}`;

const filas = [
  { id: 'u1', nombre: 'Christian', email: 'chris@x.com', totalVentas: 4000, cantidadPedidos: 9, totalPagado: 3000, totalPendiente: 1000 },
  { id: 'u2', nombre: 'Marcelo', email: 'marce@x.com', totalVentas: 1000, cantidadPedidos: 3, totalPagado: 1000, totalPendiente: 0 },
];

function renderReporte(props: Partial<ComponentProps<typeof ReportePreventistas>> = {}) {
  return render(
    <ReportePreventistas
      reportePreventistas={filas as never}
      loading={false}
      formatPrecio={formatPrecio}
      desde="2026-06-01"
      hasta="2026-08-20"
      {...props}
    />
  );
}

describe('ReportePreventistas › export', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('exporta una hoja con las ventas, lo pagado y lo pendiente', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [hojas, nombreArchivo] = mockCrearExcel.mock.calls[0];
    expect(hojas.map((h) => h.name)).toEqual(['Por preventista']);
    expect(hojas[0].data[0]).toMatchObject({
      Preventista: 'Christian',
      Email: 'chris@x.com',
      'Total ventas': 4000,
      Pedidos: 9,
      Pagado: 3000,
      Pendiente: 1000,
    });
    expect(nombreArchivo).toBe('ventas-por-preventista-2026-06-01_2026-08-20');
  });

  it('la última fila es el TOTAL, igual que el pie de la tabla', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [hojas] = mockCrearExcel.mock.calls[0];
    expect(hojas[0].data[hojas[0].data.length - 1]).toMatchObject({
      Preventista: 'TOTAL',
      'Total ventas': 5000,
      Pedidos: 12,
      Pagado: 4000,
      Pendiente: 1000,
    });
  });

  it('sin filtro de fecha el archivo dice "todo", no un rango inventado', async () => {
    const user = userEvent.setup();
    renderReporte({ desde: '', hasta: '' });

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [, nombreArchivo] = mockCrearExcel.mock.calls[0];
    expect(nombreArchivo).toBe('ventas-por-preventista-todo');
  });

  it('con media fecha el archivo dice cuál falta, no la inventa', async () => {
    const user = userEvent.setup();
    renderReporte({ desde: '2026-06-01', hasta: '' });

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [, nombreArchivo] = mockCrearExcel.mock.calls[0];
    expect(nombreArchivo).toBe('ventas-por-preventista-2026-06-01_hoy');
  });

  it('sin datos no hay botón que apretar', () => {
    renderReporte({ reportePreventistas: [] });
    expect(screen.queryByRole('button', { name: /Exportar a Excel/i })).not.toBeInTheDocument();
  });
});
