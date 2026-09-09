/**
 * Stock de la red: lo que NO se puede esconder.
 *
 * El emparejado entre sucursales es una heurística (código o nombre exactos) y
 * empareja poco: medido el 2026-09-08, de 176 productos en Tucumán y 111 en
 * Taco Pozo emparejaron 10. Si la vista mostrara solo los emparejados, el
 * 96% del catálogo desaparecería de la pantalla sin decirlo. Estos tests fijan
 * que lo que no empareja se sigue viendo, con su sucursal y su cantidad.
 */
import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ReporteStockRed } from './ReporteStockRed';
import type { StockRed } from '../../../hooks/queries/useStockRedQuery';

const mockQuery = vi.fn();
vi.mock('../../../hooks/queries/useStockRedQuery', () => ({
  useStockRedQuery: (...args: unknown[]) => mockQuery(...args),
}));

const formatPrecio = (n: number): string => `$${n}`;

const DATA: StockRed = {
  meta: {
    sucursal_id: null,
    sucursal_nombre: 'Red (consolidado)',
    generado_at: '2026-09-08T00:00:00Z',
    criterio: 'costo promedio ponderado',
  },
  sucursales: [
    {
      sucursal_id: 2,
      sucursal_nombre: 'Taco Pozo',
      productos: 2,
      productos_con_stock: 2,
      unidades: 12,
      valuacion_promedio: 1000,
    },
    {
      sucursal_id: 1,
      sucursal_nombre: 'Tucuman',
      productos: 2,
      productos_con_stock: 1,
      unidades: 7,
      valuacion_promedio: 2000,
    },
  ],
  productos: [
    {
      producto_id: 10, sucursal_id: 1, sucursal_nombre: 'Tucuman',
      nombre: 'ALFATUC BLANCO x 18 u', codigo: 'A1', categoria: 'GALLETITAS',
      stock: 7, costo_promedio: 4300, costo_reposicion: 4300,
      ultimo_tipo_compra: 'ZZ', precio: 6000,
    },
    {
      producto_id: 11, sucursal_id: 1, sucursal_nombre: 'Tucuman',
      nombre: 'SOLO TUCUMAN', codigo: null, categoria: 'VARIOS',
      stock: 0, costo_promedio: null, costo_reposicion: null,
      ultimo_tipo_compra: null, precio: 100,
    },
    {
      producto_id: 20, sucursal_id: 2, sucursal_nombre: 'Taco Pozo',
      nombre: 'ALFATUC BLANCO DISPLAY X 18', codigo: 'A1', categoria: 'GALLETITAS',
      stock: 3, costo_promedio: 4500, costo_reposicion: 4500,
      ultimo_tipo_compra: 'ZZ', precio: 6500,
    },
    {
      producto_id: 21, sucursal_id: 2, sucursal_nombre: 'Taco Pozo',
      nombre: 'SOLO TACO POZO', codigo: 'B9', categoria: 'VARIOS',
      stock: 9, costo_promedio: 50, costo_reposicion: 60,
      ultimo_tipo_compra: 'FC', precio: 120,
    },
  ],
};

function montar(data: StockRed = DATA): void {
  mockQuery.mockReturnValue({ data, isLoading: false, error: null });
  render(<ReporteStockRed formatPrecio={formatPrecio} />);
}

describe('ReporteStockRed', () => {
  it('dice que es solo lectura', () => {
    montar();
    expect(screen.getByText(/Solo lectura/i)).toBeInTheDocument();
  });

  it('muestra las dos sucursales, no solo la activa', () => {
    montar();
    expect(screen.getAllByText('Tucuman').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Taco Pozo').length).toBeGreaterThan(0);
  });

  it('empareja el producto que está en las dos y muestra el stock de cada una', () => {
    montar();
    expect(screen.getByText('En más de una sucursal (1)')).toBeInTheDocument();
    // La celda del nombre lleva además el código y la categoría, así que la
    // fila se busca por su contenido y no por un texto exacto.
    const fila = screen
      .getAllByRole('row')
      .find((r) => r.textContent?.includes('ALFATUC BLANCO DISPLAY X 18'));
    expect(fila).toBeDefined();
    expect(fila).toHaveTextContent('7');
    expect(fila).toHaveTextContent('3');
    // El costo y el precio de la OTRA sucursal, que es el punto del reporte.
    expect(fila).toHaveTextContent('$4500');
    expect(fila).toHaveTextContent('$6500');
  });

  it('el par muestra los dos nombres: el emparejado es una heurística y tiene que poder auditarse', () => {
    montar();
    const fila = screen
      .getAllByRole('row')
      .find((r) => r.textContent?.includes('ALFATUC BLANCO DISPLAY X 18'));
    expect(fila).toHaveTextContent('Tucuman: ALFATUC BLANCO x 18 u');
  });

  it('lo que no empareja NO se esconde: va en su propia sección, por sucursal', () => {
    montar();
    expect(screen.getByText('Solo en Tucuman (1)')).toBeInTheDocument();
    expect(screen.getByText('Solo en Taco Pozo (1)')).toBeInTheDocument();
    expect(screen.getByText('SOLO TUCUMAN')).toBeInTheDocument();
    expect(screen.getByText('SOLO TACO POZO')).toBeInTheDocument();
  });

  it('con una sucursal elegida muestra su catálogo completo, emparejados incluidos', async () => {
    montar();
    await userEvent.selectOptions(screen.getByLabelText('Sucursal'), '2');

    expect(screen.getByText('Taco Pozo (2)')).toBeInTheDocument();
    expect(screen.getByText('ALFATUC BLANCO DISPLAY X 18')).toBeInTheDocument();
    expect(screen.getByText('SOLO TACO POZO')).toBeInTheDocument();
    // Nada de la otra sucursal.
    expect(screen.queryByText('SOLO TUCUMAN')).not.toBeInTheDocument();
  });

  it('el buscador encuentra por el nombre de la otra sucursal', async () => {
    montar();
    await userEvent.type(screen.getByLabelText('Buscar producto'), 'display');

    expect(screen.getByText('En más de una sucursal (1)')).toBeInTheDocument();
    expect(screen.getByText('Solo en Taco Pozo (0)')).toBeInTheDocument();
  });

  it('"solo con stock" esconde el que está en cero en todas', async () => {
    montar();
    await userEvent.click(screen.getByLabelText('Solo con stock'));

    expect(screen.queryByText('SOLO TUCUMAN')).not.toBeInTheDocument();
    expect(screen.getByText('SOLO TACO POZO')).toBeInTheDocument();
  });

  it('avisa el error en vez de mostrar una tabla vacía', () => {
    mockQuery.mockReturnValue({ data: undefined, isLoading: false, error: new Error('boom') });
    render(<ReporteStockRed formatPrecio={formatPrecio} />);
    expect(screen.getByText(/No se pudo cargar el stock de la red: boom/)).toBeInTheDocument();
  });
});
