/** El export de "Rentabilidad". Componente importado directo (ver #514). */
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

import { ReporteRentabilidadSection } from '../ReporteRentabilidad';

const formatPrecio = (n: number): string => `$${n.toLocaleString('es-AR')}`;

function producto(i: number) {
  return {
    id: `p${i}`,
    nombre: `Producto ${i}`,
    codigo: `C${i}`,
    cantidadVendida: 10,
    ingresos: 1000 - i,
    costos: 600,
    margen: 400 - i,
    margenPorcentaje: 40,
  };
}

function reporte(cantidadProductos = 3) {
  return {
    productos: Array.from({ length: cantidadProductos }, (_, i) => producto(i)),
    totales: {
      ingresosTotales: 3000,
      costosTotales: 1800,
      margenTotal: 1200,
      cantidadPedidos: 25,
      margenPorcentaje: 40,
      ventasBrutas: 3630,
      ivaDiscriminado: 630,
      impuestosInternos: 0,
      ventasNetas: 3000,
    },
  };
}

function renderReporte(props: Partial<ComponentProps<typeof ReporteRentabilidadSection>> = {}) {
  return render(
    <ReporteRentabilidadSection
      reporte={reporte() as never}
      loading={false}
      formatPrecio={formatPrecio}
      desde="2026-06-01"
      hasta="2026-08-20"
      {...props}
    />
  );
}

describe('ReporteRentabilidad › export', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('exporta el resumen fiscal y el detalle por producto', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [hojas, nombreArchivo] = mockCrearExcel.mock.calls[0];
    expect(hojas[0].name).toBe('Resumen');
    expect(hojas[1].name).toBe('Productos (todos, 3)');
    expect(nombreArchivo).toBe('rentabilidad-2026-06-01_2026-08-20');

    expect(hojas[1].data[0]).toMatchObject({
      '#': 1,
      Producto: 'Producto 0',
      Código: 'C0',
      Vendido: 10,
      Ingresos: 1000,
      Costos: 600,
      Margen: 400,
    });
  });

  it('el resumen lleva el desglose fiscal, que en la tabla no está', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [hojas] = mockCrearExcel.mock.calls[0];
    const porConcepto = Object.fromEntries(
      hojas[0].data.map((f) => [f.Concepto, f.Monto])
    );
    expect(porConcepto['Ventas brutas']).toBe(3630);
    expect(porConcepto['IVA discriminado']).toBe(630);
    expect(porConcepto['Ventas netas']).toBe(3000);
    expect(porConcepto['Margen']).toBe(1200);
  });

  // El bug que este export podría haber tenido: la tabla muestra 20 y el
  // archivo tiene que llevar todos, con el nombre de la hoja diciéndolo.
  it('el Excel lleva TODOS los productos, no los 20 de la pantalla', async () => {
    const user = userEvent.setup();
    renderReporte({ reporte: reporte(45) as never });

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [hojas] = mockCrearExcel.mock.calls[0];
    expect(hojas[1].data).toHaveLength(45);
    expect(hojas[1].name).toBe('Productos (todos, 45)');
  });

  it('la pantalla avisa que muestra menos filas que el archivo', () => {
    renderReporte({ reporte: reporte(45) as never });
    expect(screen.getByText(/Se muestran los 20 de mayor margen/i)).toBeInTheDocument();
    expect(screen.getByText(/El Excel lleva los 45/i)).toBeInTheDocument();
  });

  it('con 20 productos o menos no avisa nada', () => {
    renderReporte({ reporte: reporte(20) as never });
    expect(screen.queryByText(/El Excel lleva los/i)).not.toBeInTheDocument();
  });

  it('sin productos el botón está deshabilitado', () => {
    renderReporte({ reporte: reporte(0) as never });
    expect(screen.getByRole('button', { name: /Exportar a Excel/i })).toBeDisabled();
  });
});
