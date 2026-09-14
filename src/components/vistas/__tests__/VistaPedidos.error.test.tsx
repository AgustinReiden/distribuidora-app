/**
 * Test de render para el estado de error de VistaPedidos.
 *
 * Antes de este fix, `loading` era el único estado que se le pasaba a la
 * vista: una query de pedidos fallida (tras agotar los reintentos de
 * queryClient) caía en el mismo "No hay pedidos" que una sucursal
 * realmente vacía.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

// Mock supabase ANTES de importar el componente: `../../../hooks/queries` (para
// EMPTY_PEDIDO_STATS_SUMMARY) arrastra la cadena de imports hasta el cliente
// real y jsdom tira "supabaseUrl is required" si no se mockea.
vi.mock('../../../lib/supabase', () => ({
  supabase: {
    rpc: vi.fn(),
    from: vi.fn(),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(),
}));

import VistaPedidos, { type VistaPedidosProps } from '../VistaPedidos';
import { EMPTY_PEDIDO_STATS_SUMMARY } from '../../../hooks/queries';
import type { FiltrosPedidosState } from '../../../types';

const filtros: FiltrosPedidosState = {
  fechaDesde: null,
  fechaHasta: null,
  estado: 'todos',
  estadoPago: 'todos',
  transportistaId: 'todos',
  usuarioId: 'todos',
  busqueda: '',
  conSalvedad: 'todos',
};

function buildProps(overrides: Partial<VistaPedidosProps> = {}): VistaPedidosProps {
  return {
    pedidos: [],
    totalCount: 0,
    statsSummary: EMPTY_PEDIDO_STATS_SUMMARY,
    paginaActual: 1,
    totalPaginas: 1,
    busqueda: '',
    filtros,
    isAdmin: true,
    isPreventista: false,
    isTransportista: false,
    userId: 'user-1',
    clientes: [],
    productos: [],
    loading: false,
    exportando: false,
    onBusquedaChange: vi.fn(),
    onFiltrosChange: vi.fn(),
    onPageChange: vi.fn(),
    onNuevoPedido: vi.fn(),
    onOptimizarRuta: vi.fn(),
    onExportarPDF: vi.fn(),
    onExportarExcel: vi.fn(),
    onModalFiltroFecha: vi.fn(),
    onVerHistorial: vi.fn(),
    onEditarPedido: vi.fn(),
    onMarcarEnPreparacion: vi.fn(),
    onVolverAPendiente: vi.fn(),
    onMarcarEntregado: vi.fn(),
    onDesmarcarEntregado: vi.fn(),
    ...overrides,
  };
}

describe('VistaPedidos', () => {
  it('en error, muestra el estado de error y no "No hay pedidos"', async () => {
    const onRetry = vi.fn();
    render(<VistaPedidos {...buildProps({ error: true, onRetry })} />);

    expect(screen.getByText('No se pudo cargar.')).toBeInTheDocument();
    expect(screen.queryByText('No hay pedidos')).not.toBeInTheDocument();

    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: /reintentar/i }));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it('sin error y sin pedidos, sigue mostrando el empty state normal', () => {
    render(<VistaPedidos {...buildProps({ error: false })} />);

    expect(screen.getByText('No hay pedidos')).toBeInTheDocument();
    expect(screen.queryByText('No se pudo cargar.')).not.toBeInTheDocument();
  });
});
