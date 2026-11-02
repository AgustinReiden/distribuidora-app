/** El export de "Rentabilidad". Componente importado directo (ver #514). */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
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

    // El export hace un import() dinámico: hay que esperar la llamada, no leerla en el acto (#1006).
    await waitFor(() => expect(mockCrearExcel).toHaveBeenCalledTimes(1));
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

  it('separa el margen fuera de combo y dentro de combo (#1193)', async () => {
    const user = userEvent.setup();
    const r = reporte(1) as { productos: Record<string, unknown>[] };
    r.productos[0].fueraDeCombo = { cantidad: 6, ingresos: 600, costos: 360, margen: 240 };
    r.productos[0].dentroDeCombo = { cantidad: 4, ingresos: 400, costos: 240, margen: 160 };
    renderReporte({ reporte: r as never, combos: 'solo' });

    expect(screen.getByText('$240')).toBeInTheDocument();
    expect(screen.getByText('$160')).toBeInTheDocument();
    expect(screen.getByText(/sólo las líneas vendidas dentro de un combo/i)).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));
    await waitFor(() => expect(mockCrearExcel).toHaveBeenCalledTimes(1));
    const [hojas, nombre] = mockCrearExcel.mock.calls[0];
    expect(hojas[1].data[0]).toMatchObject({ 'Margen fuera de combo': 240, 'Margen dentro de combo': 160 });
    expect(nombre).toBe('rentabilidad-2026-06-01_2026-08-20-solo-combos');
  });

  it('el resumen lleva el desglose fiscal, que en la tabla no está', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    await waitFor(() => expect(mockCrearExcel).toHaveBeenCalledTimes(1));
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

    await waitFor(() => expect(mockCrearExcel).toHaveBeenCalledTimes(1));
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

describe('ReporteRentabilidad › productos sin costo (#1289)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  function conSinCosto(cantidadProductos: number, marcado: number, ingresosSinCosto = 600) {
    const r = reporte(cantidadProductos) as {
      productos: Record<string, unknown>[];
      totales: Record<string, unknown>;
    };
    r.productos[marcado].sinCosto = true;
    r.totales.ingresosSinCosto = ingresosSinCosto;
    return r as never;
  }

  it('sin líneas sin costo no marca ni avisa nada', () => {
    renderReporte();
    expect(screen.queryByText(/Margen sobreestimado/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/△/)).not.toBeInTheDocument();
  });

  it('marca el producto con △ y avisa el monto y el porcentaje junto a los totales', () => {
    renderReporte({ reporte: conSinCosto(3, 1) });

    expect(screen.getByText(/Margen sobreestimado/i).closest('p')).toHaveTextContent(
      'el 20.0% de los ingresos ($600) proviene de un producto sin costo cargado'
    );
    const fila = screen.getByText('Producto 1').closest('tr');
    expect(fila).toHaveTextContent('△ Producto 1');
    expect(screen.getByText('Producto 0').closest('tr')).not.toHaveTextContent('△');
    expect(screen.getByText(/△ = margen inflado/)).toBeInTheDocument();
  });

  // La tabla muestra 20: un producto sin costo con poco margen puede quedar
  // afuera, y el aviso no puede depender de que esté en pantalla.
  it('avisa aunque el producto sin costo esté fuera de los 20 de la tabla', () => {
    renderReporte({ reporte: conSinCosto(25, 22) });
    expect(screen.getByText(/Margen sobreestimado/i)).toBeInTheDocument();
    expect(screen.queryByText(/△ = margen inflado/)).not.toBeInTheDocument();
  });

  it('el Excel lleva la marca y el monto', async () => {
    const user = userEvent.setup();
    renderReporte({ reporte: conSinCosto(3, 1) });

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    await waitFor(() => expect(mockCrearExcel).toHaveBeenCalledTimes(1));
    const [hojas] = mockCrearExcel.mock.calls[0];
    const porConcepto = Object.fromEntries(hojas[0].data.map((f) => [f.Concepto, f.Monto]));
    expect(porConcepto['Ingresos sin costo']).toBe(600);
    expect(porConcepto['Productos sin costo']).toBe(1);
    expect(hojas[1].data[0]['Sin costo']).toBe('');
    expect(hojas[1].data[1]['Sin costo']).toBe('Sí');
  });

  it('muestra la fila "(producto borrado)" aunque no tenga id ni código', () => {
    const r = reporte(1) as { productos: Record<string, unknown>[] };
    r.productos.push({
      ...producto(1),
      id: null,
      nombre: '(producto borrado)',
      codigo: null,
      sinCosto: true,
    });
    renderReporte({ reporte: r as never });

    const fila = screen.getByText(/\(producto borrado\)/).closest('tr');
    expect(fila).toHaveTextContent('△ (producto borrado)');
    expect(fila).toHaveTextContent('Líneas de productos que ya no están en el catálogo');
    expect(screen.getByText('Producto 0').closest('tr')).not.toHaveTextContent('catálogo');
  });
});
