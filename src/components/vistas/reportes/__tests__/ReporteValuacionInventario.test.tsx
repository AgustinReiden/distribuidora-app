/**
 * El export de "Valuación de Stock".
 *
 * Lo que más importa acá: el filtrado de esta pestaña es EN CLIENTE, así que un
 * export que mandara `data.productos` crudo ignoraría los filtros que el usuario
 * tiene puestos y el archivo no coincidiría con lo que está mirando.
 *
 * Componente importado directo (ver #514).
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
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

vi.mock('../../../../hooks/queries/useValuacionInventarioQuery', () => ({
  useValuacionInventarioQuery: () => mockUseQuery(),
}));

vi.mock('../../../../utils/excel', () => ({
  createMultiSheetExcel: (hojas: HojaExcel[], filename: string) => mockCrearExcel(hojas, filename),
}));

vi.mock('../../../layout/LoadingSpinner', () => ({
  default: () => <div>cargando…</div>,
}));

import { ReporteValuacionInventario } from '../ReporteValuacionInventario';

const formatPrecio = (n: number): string => `$${n.toLocaleString('es-AR')}`;

function datos() {
  return {
    meta: {
      sucursal_id: null,
      sucursal_nombre: 'Red',
      generado_at: '2026-09-07T15:00:00Z',
      criterio: 'Stock a costo promedio ponderado',
    },
    totales: { productos: 3, unidades: 60, valuacion_promedio: 6000, valuacion_reposicion: 6600, diferencia: 600 },
    sucursales: [
      { sucursal_id: 1, sucursal_nombre: 'Tucuman', productos: 2, unidades: 40, valuacion_promedio: 4000, valuacion_reposicion: 4400 },
      { sucursal_id: 2, sucursal_nombre: 'Taco Pozo', productos: 1, unidades: 20, valuacion_promedio: 2000, valuacion_reposicion: 2200 },
    ],
    categorias: [
      { categoria: 'Bebidas', productos: 2, unidades: 40, valuacion_promedio: 4000, valuacion_reposicion: 4400, diferencia: 400 },
      { categoria: 'Snacks', productos: 1, unidades: 20, valuacion_promedio: 2000, valuacion_reposicion: 2200, diferencia: 200 },
    ],
    productos: [
      { producto_id: 1, nombre: 'Coca 2L', categoria: 'Bebidas', sucursal_id: 1, sucursal_nombre: 'Tucuman', stock: 20, costo_promedio: 100, costo_reposicion: 110, ultimo_tipo_compra: 'FC', valuacion_promedio: 2000, valuacion_reposicion: 2200, diferencia: 200 },
      { producto_id: 2, nombre: 'Agua 500', categoria: 'Bebidas', sucursal_id: 1, sucursal_nombre: 'Tucuman', stock: 20, costo_promedio: 100, costo_reposicion: 110, ultimo_tipo_compra: 'FC', valuacion_promedio: 2000, valuacion_reposicion: 2200, diferencia: 200 },
      { producto_id: 3, nombre: 'Papas', categoria: 'Snacks', sucursal_id: 2, sucursal_nombre: 'Taco Pozo', stock: 20, costo_promedio: 100, costo_reposicion: 110, ultimo_tipo_compra: 'ZZ', valuacion_promedio: 2000, valuacion_reposicion: 2200, diferencia: 200 },
    ],
    calidad_datos: { stock_negativo: 1, sin_costo: 2, detalle_stock_negativo: [] },
  };
}

function renderReporte() {
  mockUseQuery.mockReturnValue({ data: datos(), isLoading: false, error: null });
  return render(<ReporteValuacionInventario formatPrecio={formatPrecio} />);
}

async function exportar(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));
  return mockCrearExcel.mock.calls[0];
}

describe('ReporteValuacionInventario › export', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('exporta tres hojas: metadatos, categorías y detalle', async () => {
    const user = userEvent.setup();
    renderReporte();

    const [hojas, nombreArchivo] = await exportar(user);

    expect(hojas.map((h) => h.name)).toEqual(['Info', 'Por categoría', 'Detalle']);
    expect(nombreArchivo).toBe('valuacion-inventario-Todas-2026-09-07');
    expect(hojas[2].data[0]).toMatchObject({
      Producto: 'Coca 2L',
      Categoría: 'Bebidas',
      Sucursal: 'Tucuman',
      Stock: 20,
      'Costo promedio': 100,
      'Costo reposición': 110,
      'Última compra': 'FC',
      'Valuación promedio': 2000,
    });
  });

  it('respeta el filtro de sucursal que el usuario tiene puesto', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.selectOptions(screen.getByRole('combobox', { name: 'Sucursal' }), '2');
    const [hojas, nombreArchivo] = await exportar(user);

    // Sólo el producto de Taco Pozo, no los tres.
    expect(hojas[2].data).toHaveLength(1);
    expect(hojas[2].data[0]).toMatchObject({ Producto: 'Papas', Sucursal: 'Taco Pozo' });
    expect(nombreArchivo).toBe('valuacion-inventario-Taco_Pozo-2026-09-07');
  });

  it('respeta el filtro de categoría', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.selectOptions(screen.getByRole('combobox', { name: 'Categoría' }), 'Snacks');
    const [hojas] = await exportar(user);

    expect(hojas[2].data).toHaveLength(1);
    expect(hojas[2].data[0]).toMatchObject({ Producto: 'Papas' });
  });

  it('la hoja de metadatos deja escrito qué filtro estaba aplicado', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.selectOptions(screen.getByRole('combobox', { name: 'Categoría' }), 'Snacks');
    const [hojas] = await exportar(user);
    const info = Object.fromEntries(hojas[0].data.map((f) => [f.Campo, f.Valor]));

    // Fuera de la app nadie puede saber si el archivo es de todo o de una parte.
    expect(info['Categoría (filtro aplicado)']).toBe('Snacks');
    expect(info['Sucursal (filtro aplicado)']).toBe('Todas');
    expect(info['Productos en este archivo']).toBe(1);
    expect(info['Productos en el reporte completo']).toBe(3);
    expect(info['Productos con stock negativo']).toBe(1);
    expect(info['Productos sin costo']).toBe(2);
  });

  it('los totales de la hoja Info son los del filtro, no los globales', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.selectOptions(screen.getByRole('combobox', { name: 'Categoría' }), 'Snacks');
    const [hojas] = await exportar(user);
    const info = Object.fromEntries(hojas[0].data.map((f) => [f.Campo, f.Valor]));

    expect(info['Valuación a costo promedio']).toBe(2000);
    expect(info['Unidades']).toBe(20);
  });

  // Las categorías que devuelve el RPC son globales: con un filtro puesto no
  // cuadrarían con el detalle del mismo archivo.
  it('el resumen por categoría se recalcula sobre lo filtrado', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.selectOptions(screen.getByRole('combobox', { name: 'Sucursal' }), '1');
    const [hojas] = await exportar(user);

    expect(hojas[1].data).toEqual([
      {
        Categoría: 'Bebidas',
        Productos: 2,
        Unidades: 40,
        'Valuación promedio': 4000,
        'Valuación reposición': 4400,
        Diferencia: 400,
      },
    ]);
  });
});
