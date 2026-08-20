/**
 * Tests de la barra de filtros de las pestañas de ventas.
 *
 * Lo que importa acá:
 *   1) la lista de vendedores sale de los DATOS, no de `perfiles.rol` — si
 *      saliera del rol, Jony (encargado, $16,6M en 2026) no aparecería;
 *   2) se pide siempre con preventistaId = null, para que elegir a alguien no
 *      deje el desplegable con una sola opción;
 *   3) los atajos de mes escriben desde/hasta y "Personalizado" abre los campos;
 *   4) si el elegido no vendió en el período nuevo, la opción sigue visible en
 *      vez de que el <select> se vea en "Todos" con el filtro puesto.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

const mockUseQuery = vi.fn();

vi.mock('../../../../hooks/queries/useVentasPorClienteQuery', () => ({
  useVentasPorClienteQuery: (desde: string, hasta: string, preventistaId: string | null) =>
    mockUseQuery(desde, hasta, preventistaId),
}));

import { FiltrosVentas } from '../FiltrosVentas';
import type { FiltrosVentasValue } from '../filtrosVentasState';

const VENDEDORES = [
  { id: 'juan', nombre: 'Juan', pedidos: 912, total: 45796256.96 },
  { id: 'christian', nombre: 'Christian', pedidos: 1164, total: 40198490.26 },
  // Encargado: la prueba de que la lista no viene filtrada por rol.
  { id: 'jony', nombre: 'Jony', pedidos: 287, total: 16630570 },
];

const BASE: FiltrosVentasValue = {
  desde: '2026-01-01',
  hasta: '2026-08-20',
  preventistaId: null,
  presetId: 'anio-2026',
};

function renderFiltros(value: Partial<FiltrosVentasValue> = {}) {
  const onChange = vi.fn();
  render(<FiltrosVentas value={{ ...BASE, ...value }} onChange={onChange} />);
  return onChange;
}

beforeEach(() => {
  mockUseQuery.mockReset();
  mockUseQuery.mockReturnValue({ data: { vendedores: VENDEDORES } });
});

describe('FiltrosVentas', () => {
  it('lista a quien vendió, sin importar el rol, con su total', () => {
    renderFiltros();
    const select = screen.getByLabelText(/Vendedor/i);
    expect(select).toHaveTextContent('Juan — $45.8M');
    expect(select).toHaveTextContent('Christian — $40.2M');
    // Un desplegable por `rol = 'preventista'` se habría comido a Jony.
    expect(select).toHaveTextContent('Jony — $16.6M');
  });

  it('pide la lista con preventistaId null aunque haya uno elegido', () => {
    renderFiltros({ preventistaId: 'christian' });
    expect(mockUseQuery).toHaveBeenCalledWith('2026-01-01', '2026-08-20', null);
    // Y sigue mostrando a los tres, no sólo al elegido.
    expect(screen.getByLabelText(/Vendedor/i)).toHaveTextContent('Juan');
  });

  it('elegir un vendedor lo propaga', async () => {
    const user = userEvent.setup();
    const onChange = renderFiltros();
    await user.selectOptions(screen.getByLabelText(/Vendedor/i), 'christian');
    expect(onChange).toHaveBeenCalledWith(expect.objectContaining({ preventistaId: 'christian' }));
  });

  it('volver a "Todos" manda null y no la cadena vacía', async () => {
    const user = userEvent.setup();
    const onChange = renderFiltros({ preventistaId: 'christian' });
    await user.selectOptions(screen.getByLabelText(/Vendedor/i), '');
    expect(onChange).toHaveBeenCalledWith(expect.objectContaining({ preventistaId: null }));
  });

  it('un atajo de mes escribe desde y hasta', async () => {
    const user = userEvent.setup();
    const onChange = renderFiltros();
    const periodo = screen.getByLabelText(/Período/i);
    // El segundo preset es el mes en curso; se elige por su value.
    const opciones = Array.from((periodo as HTMLSelectElement).options).map((o) => o.value);
    const unMes = opciones.find((v) => v.startsWith('mes-')) as string;

    await user.selectOptions(periodo, unMes);
    const arg = onChange.mock.calls[0][0] as FiltrosVentasValue;
    expect(arg.presetId).toBe(unMes);
    expect(arg.desde).toMatch(/^\d{4}-\d{2}-01$/);
    expect(arg.hasta).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(arg.desde <= arg.hasta).toBe(true);
  });

  it('los campos de fecha aparecen sólo en "Personalizado"', async () => {
    const user = userEvent.setup();
    const onChange = renderFiltros();
    expect(screen.queryByLabelText('Desde')).not.toBeInTheDocument();

    await user.selectOptions(screen.getByLabelText(/Período/i), 'custom');
    expect(onChange).toHaveBeenCalledWith(expect.objectContaining({ presetId: 'custom' }));

    renderFiltros({ presetId: 'custom' });
    expect(screen.getByLabelText('Desde')).toBeInTheDocument();
    expect(screen.getByLabelText('Hasta')).toBeInTheDocument();
  });

  it('"Personalizado" no pisa las fechas que ya estaban', async () => {
    const user = userEvent.setup();
    const onChange = renderFiltros({ desde: '2026-03-05', hasta: '2026-04-09' });
    await user.selectOptions(screen.getByLabelText(/Período/i), 'custom');
    expect(onChange).toHaveBeenCalledWith(
      expect.objectContaining({ desde: '2026-03-05', hasta: '2026-04-09' })
    );
  });

  it('si el elegido no vendió en el período, la opción sigue visible', () => {
    renderFiltros({ preventistaId: 'osvaldo' });
    const select = screen.getByLabelText(/Vendedor/i) as HTMLSelectElement;
    // Sin esta opción el <select> caería a "Todos" mostrando datos filtrados.
    expect(select.value).toBe('osvaldo');
    expect(select).toHaveTextContent('Sin ventas en el período');
  });

  it('no inventa esa opción mientras la lista todavía no cargó', () => {
    mockUseQuery.mockReturnValue({ data: undefined });
    renderFiltros({ preventistaId: 'christian' });
    expect(screen.getByLabelText(/Vendedor/i)).not.toHaveTextContent('Sin ventas en el período');
  });

  it('deja escrito el criterio de qué cuenta como venta', () => {
    renderFiltros();
    expect(screen.getByText(/entregados/i)).toBeInTheDocument();
    expect(screen.getByText(/No cuenta cancelados/i)).toBeInTheDocument();
  });
});
