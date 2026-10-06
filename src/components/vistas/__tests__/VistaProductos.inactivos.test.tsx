/**
 * Baja lógica de productos en la lista de Productos.
 *
 * - Los inactivos están ocultos por defecto; el chip "Ver inactivos" muestra
 *   SOLO los inactivos (sumados al resto se perdían entre cientos).
 * - Se marcan con el badge "Inactivo" (fila y tarjeta).
 * - Desactivar / Reactivar aparece sólo si el container pasa `puedeDesactivar`
 *   (admin): la vista obedece la prop, no decide por su cuenta.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import type { ComponentProps } from 'react';

vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn() },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(),
}));

import VistaProductos from '../VistaProductos';
import type { ProductoDB } from '../../../types';

class ObservadorStub {
  observe(): void { /* no-op */ }
  unobserve(): void { /* no-op */ }
  disconnect(): void { /* no-op */ }
  takeRecords(): [] { return []; }
}
globalThis.ResizeObserver ??= ObservadorStub as unknown as typeof ResizeObserver;
globalThis.IntersectionObserver ??= ObservadorStub as unknown as typeof IntersectionObserver;

const PRODUCTOS = [
  { id: '1', codigo: 'A-1', nombre: 'Activo Uno', precio: 100, stock: 50, stock_minimo: 10, categoria: 'Cat', activo: true },
  { id: '2', codigo: 'B-2', nombre: 'Sin Campo Dos', precio: 200, stock: 50, stock_minimo: 10, categoria: 'Cat' },
  { id: '3', codigo: 'C-3', nombre: 'Retirado Tres', precio: 300, stock: 50, stock_minimo: 10, categoria: 'Cat', activo: false },
] as unknown as ProductoDB[];

function montar(props: Partial<ComponentProps<typeof VistaProductos>> = {}, productos = PRODUCTOS) {
  const onToggleActivoProducto = vi.fn();
  render(
    <MemoryRouter>
      <VistaProductos
        productos={productos}
        productosStockBajo={[]}
        loading={false}
        isAdmin
        onNuevoProducto={vi.fn()}
        onEditarProducto={vi.fn()}
        onEliminarProducto={vi.fn()}
        onToggleActivoProducto={onToggleActivoProducto}
        {...props}
      />
    </MemoryRouter>,
  );
  return { onToggleActivoProducto };
}

const filas = () => within(screen.getByRole('table')).getAllByRole('row').slice(1);

describe('VistaProductos — inactivos', () => {
  it('oculta los inactivos por defecto y el chip está apagado', () => {
    montar();
    expect(filas()).toHaveLength(2);
    expect(screen.queryByText('Retirado Tres')).not.toBeInTheDocument();
    const chip = screen.getByRole('button', { name: /ver inactivos/i });
    expect(chip).toHaveAttribute('aria-pressed', 'false');
    expect(chip).toHaveTextContent('(1)');
  });

  it('con el chip prendido muestra SOLO los inactivos, con el badge "Inactivo" en la fila y en la tarjeta', async () => {
    const user = userEvent.setup();
    montar();
    await user.click(screen.getByRole('button', { name: /ver inactivos/i }));
    expect(filas()).toHaveLength(1);
    const fila = within(screen.getByRole('table')).getByText('Retirado Tres').closest('tr') as HTMLElement;
    expect(within(fila).getByText('Inactivo')).toBeInTheDocument();
    // Fila + tarjeta: el badge aparece una vez por layout.
    expect(screen.getAllByText('Inactivo')).toHaveLength(2);
    // Los activos no se listan mientras el chip está prendido.
    expect(within(screen.getByRole('table')).queryByText('Activo Uno')).not.toBeInTheDocument();
  });

  it('apagar el chip vuelve a los activos', async () => {
    const user = userEvent.setup();
    montar();
    const chip = screen.getByRole('button', { name: /ver inactivos/i });
    await user.click(chip);
    await user.click(chip);
    expect(filas()).toHaveLength(2);
    expect(screen.queryByText('Retirado Tres')).not.toBeInTheDocument();
  });

  it('prender el chip con un rubro elegido vuelve a "todas": los inactivos de otro rubro se ven', async () => {
    const user = userEvent.setup();
    const productos = [
      ...PRODUCTOS.slice(0, 2),
      { ...PRODUCTOS[2], categoria: 'Otra' },
    ] as ProductoDB[];
    montar({}, productos);
    await user.click(screen.getByRole('button', { name: 'Cat' }));
    await user.click(screen.getByRole('button', { name: /ver inactivos/i }));
    expect(within(screen.getByRole('table')).getByText('Retirado Tres')).toBeInTheDocument();
  });

  it('sin inactivos no hay chip', () => {
    montar({}, PRODUCTOS.slice(0, 2));
    expect(screen.queryByRole('button', { name: /ver inactivos/i })).not.toBeInTheDocument();
  });

  it('con puedeDesactivar: "Desactivar" en los activos y "Reactivar" en el inactivo', async () => {
    const user = userEvent.setup();
    const { onToggleActivoProducto } = montar({ puedeDesactivar: true });

    let tabla = screen.getByRole('table');
    expect(within(tabla).getByRole('button', { name: 'Desactivar Activo Uno' })).toBeInTheDocument();
    expect(within(tabla).queryByRole('button', { name: 'Reactivar Activo Uno' })).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: /ver inactivos/i }));
    tabla = screen.getByRole('table');
    await user.click(within(tabla).getByRole('button', { name: 'Reactivar Retirado Tres' }));
    expect(onToggleActivoProducto).toHaveBeenCalledWith(expect.objectContaining({ id: '3' }));
  });

  it('sin puedeDesactivar no hay botón Desactivar/Reactivar aunque la vista sea admin', async () => {
    const user = userEvent.setup();
    montar({ puedeDesactivar: false });
    await user.click(screen.getByRole('button', { name: /ver inactivos/i }));
    expect(screen.queryByRole('button', { name: /^(Desactivar|Reactivar)/ })).not.toBeInTheDocument();
    // Eliminar sigue (sólo admin).
    expect(screen.getAllByRole('button', { name: /^Eliminar/ }).length).toBeGreaterThan(0);
  });
});
