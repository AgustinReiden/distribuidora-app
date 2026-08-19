/**
 * PanelPedidosTrabados — el listado que le faltaba al backlog.
 *
 * El pool de "Armar ruta" filtra `pendiente`/`en_preparacion`, así que un pedido
 * que llegó a `asignado` y no se resolvió no aparece en ninguna pantalla. La
 * salida (volver a pendiente) ya existía; lo que faltaba era enterarse.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import React from 'react';

const usePedidosTrabadosQuery = vi.fn();
vi.mock('../../hooks/queries/usePedidosTrabadosQuery', () => ({
  usePedidosTrabadosQuery: (...args: unknown[]) => usePedidosTrabadosQuery(...args),
}));

import PanelPedidosTrabados from './PanelPedidosTrabados';

const trabados = [
  { id: '3001', fecha: '2026-06-24', total: 61600, clienteNombre: 'Kiosco villa amalia', transportistaId: 'chofer-1', diasTrabado: 56 },
  { id: '3002', fecha: '2026-07-02', total: 12000, clienteNombre: 'Despensa Mi angel', transportistaId: null, diasTrabado: 48 },
  { id: '3003', fecha: '2026-07-10', total: 9000, clienteNombre: 'Almacen Don Jose', transportistaId: 'chofer-2', diasTrabado: 40 },
  { id: '3004', fecha: '2026-07-11', total: 5000, clienteNombre: 'Maxikiosco', transportistaId: null, diasTrabado: 39 },
];

beforeEach(() => usePedidosTrabadosQuery.mockReset());

describe('PanelPedidosTrabados', () => {
  it('no se muestra para quien no puede resolverlo', () => {
    usePedidosTrabadosQuery.mockReturnValue({ data: trabados, isLoading: false });
    const { container } = render(<PanelPedidosTrabados enabled={false} onVolverAPendiente={vi.fn()} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('no se muestra si no hay nada trabado', () => {
    usePedidosTrabadosQuery.mockReturnValue({ data: [], isLoading: false });
    const { container } = render(<PanelPedidosTrabados enabled onVolverAPendiente={vi.fn()} />);
    expect(container).toBeEmptyDOMElement();
  });

  // La plata colgada y la antigüedad son el motivo para actuar: sin eso el panel
  // es un aviso más que se ignora.
  it('dice cuántos son, cuánta plata y qué tan viejo es el peor', () => {
    usePedidosTrabadosQuery.mockReturnValue({ data: trabados, isLoading: false });
    render(<PanelPedidosTrabados enabled onVolverAPendiente={vi.fn()} />);

    expect(screen.getByText(/4 pedidos quedaron trabados/)).toBeInTheDocument();
    expect(screen.getByText(/56 días/)).toBeInTheDocument();
    expect(screen.getByText(/no aparecen al armar la ruta/i)).toBeInTheDocument();
  });

  it('rescata el pedido con su transportista, para que se lo desasigne', async () => {
    const onVolverAPendiente = vi.fn();
    usePedidosTrabadosQuery.mockReturnValue({ data: trabados, isLoading: false });
    render(<PanelPedidosTrabados enabled onVolverAPendiente={onVolverAPendiente} />);

    await userEvent.click(screen.getAllByRole('button', { name: /volver a pendiente/i })[0]);

    expect(onVolverAPendiente).toHaveBeenCalledWith({ id: '3001', transportista_id: 'chofer-1' });
  });

  it('muestra 3 y despliega el resto', async () => {
    usePedidosTrabadosQuery.mockReturnValue({ data: trabados, isLoading: false });
    render(<PanelPedidosTrabados enabled onVolverAPendiente={vi.fn()} />);

    expect(screen.queryByText('#3004')).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: /ver 1 más/i }));
    expect(screen.getByText('#3004')).toBeInTheDocument();
  });
});
