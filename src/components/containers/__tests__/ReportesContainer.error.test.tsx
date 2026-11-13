/**
 * REP-A (#1544): la solapa «Por Preventista» ante un error de su consulta.
 *
 * `ReportesContainer` sólo avisaba con un toast y la tabla quedaba vacía («No hay datos para
 * mostrar»). Ahora, con la consulta en error, la solapa muestra el estado de error con
 * «Reintentar», que vuelve a pedir la consulta (`refetch`).
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeAll, beforeEach } from 'vitest';
import { MemoryRouter } from 'react-router-dom';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

const { consultaPreventistas, refetch } = vi.hoisted(() => ({
  consultaPreventistas: { error: null as Error | null, data: undefined as unknown[] | undefined },
  refetch: vi.fn(),
}));

vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn() },
}));
vi.mock('../../../hooks/queries', () => ({
  useClienteQuery: () => ({ data: undefined }),
  useClientesQuery: () => ({ data: [] }),
  useReportePreventistasQuery: () => ({
    data: consultaPreventistas.data,
    isLoading: false,
    error: consultaPreventistas.error,
    refetch,
  }),
}));
vi.mock('../../../hooks/supabase', () => ({
  useReportesFinancieros: () => ({
    loading: false,
    errorCuentas: false,
    errorRentabilidad: false,
    generarReporteCuentasPorCobrar: vi.fn(async () => []),
    generarReporteRentabilidad: vi.fn(async () => ({ productos: [], totales: {} })),
  }),
}));
vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}));
vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}));

import ReportesContainer from '../ReportesContainer';

// #1580: `ReportesContainer` carga `VistaReportes` con lazy. Con la PC cargada esa importación
// tardaba más que los 5 s del primer caso, y lo que quedaba en pantalla era el spinner del
// Suspense. Se importa antes, con su propio margen: los casos miden la solapa, no la carga.
beforeAll(async () => {
  await import('../../vistas/VistaReportes');
}, 60_000);

beforeEach(() => {
  refetch.mockClear();
  consultaPreventistas.error = null;
  consultaPreventistas.data = undefined;
});

describe('ReportesContainer — Por Preventista con la consulta en error (REP-A)', () => {
  it('muestra el error en vez de «No hay datos para mostrar», y Reintentar vuelve a pedir la consulta', async () => {
    consultaPreventistas.error = new Error('boom');
    const user = userEvent.setup();
    render(
      <MemoryRouter initialEntries={['/reportes']}>
        <ReportesContainer />
      </MemoryRouter>
    );

    expect(await screen.findByRole('alert', {}, { timeout: 5000 })).toBeInTheDocument();
    expect(screen.queryByText(/No hay datos para mostrar/)).not.toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Reintentar' }));
    expect(refetch).toHaveBeenCalledTimes(1);
  });

  it('sin error y sin datos sigue diciendo «No hay datos para mostrar»', async () => {
    render(
      <MemoryRouter initialEntries={['/reportes']}>
        <ReportesContainer />
      </MemoryRouter>
    );

    expect(await screen.findByText(/No hay datos para mostrar/, {}, { timeout: 5000 })).toBeInTheDocument();
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });
});
