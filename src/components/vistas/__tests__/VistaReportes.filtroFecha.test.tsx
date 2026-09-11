/**
 * El panel "Filtrar por Fecha" de /reportes.
 *
 * El rango vive en la query string, y `escribirRango` descarta el rango entero
 * si le falta una punta. Como los dos inputs escriben de a uno, la primera
 * fecha que el usuario elegía se borraba sola y "Generar" salía sin filtro.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { MemoryRouter } from 'react-router-dom';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn() },
}));

const mockRentabilidad = vi.fn(async (_d: string | null, _h: string | null) => ({
  productos: [],
  totales: {},
}));

vi.mock('../../../hooks/supabase', () => ({
  useReportesFinancieros: () => ({
    loading: false,
    generarReporteCuentasPorCobrar: vi.fn(async () => []),
    generarReporteRentabilidad: mockRentabilidad,
  }),
}));

import VistaReportes from '../VistaReportes';

function renderVista(entrada = '/reportes?tab=rentabilidad'): void {
  render(
    <MemoryRouter initialEntries={[entrada]}>
      <VistaReportes
        reportePreventistas={[]}
        reporteInicializado={true}
        loading={false}
        onCalcularReporte={vi.fn(async () => {})}
      />
    </MemoryRouter>
  );
}

describe('VistaReportes — filtro de fecha', () => {
  beforeEach(() => {
    mockRentabilidad.mockClear();
  });

  it('conserva "Desde" después de elegirlo, aunque "Hasta" siga vacío', async () => {
    const user = userEvent.setup();
    renderVista();

    const desde = screen.getByLabelText('Desde') as HTMLInputElement;
    await user.type(desde, '2026-08-01');

    expect(desde.value).toBe('2026-08-01');
  });

  it('manda el rango completo al RPC de rentabilidad', async () => {
    const user = userEvent.setup();
    renderVista();

    await user.type(screen.getByLabelText('Desde'), '2026-08-01');
    await user.type(screen.getByLabelText('Hasta'), '2026-08-31');
    await user.click(screen.getByRole('button', { name: /Generar/ }));

    expect(mockRentabilidad).toHaveBeenLastCalledWith('2026-08-01', '2026-08-31');
  });
  it('manda un rango abierto: sólo "Desde" y hasta hoy', async () => {
    const user = userEvent.setup();
    renderVista();

    await user.type(screen.getByLabelText('Desde'), '2026-08-01');
    await user.click(screen.getByRole('button', { name: /Generar/ }));

    expect(mockRentabilidad).toHaveBeenLastCalledWith('2026-08-01', null);
  });

  it('siembra los inputs desde un deep link del gerencial', () => {
    renderVista('/reportes?tab=rentabilidad&desde=2026-08-01&hasta=2026-08-31');

    expect((screen.getByLabelText('Desde') as HTMLInputElement).value).toBe('2026-08-01');
    expect((screen.getByLabelText('Hasta') as HTMLInputElement).value).toBe('2026-08-31');
    expect(mockRentabilidad).toHaveBeenLastCalledWith('2026-08-01', '2026-08-31');
  });

  it('"Limpiar" recarga la pestaña que se está mirando, sin filtro', async () => {
    const user = userEvent.setup();
    renderVista('/reportes?tab=rentabilidad&desde=2026-08-01&hasta=2026-08-31');

    await user.click(screen.getByRole('button', { name: 'Limpiar filtros' }));

    expect(mockRentabilidad).toHaveBeenLastCalledWith(null, null);
    expect((screen.getByLabelText('Desde') as HTMLInputElement).value).toBe('');
    expect((screen.getByLabelText('Hasta') as HTMLInputElement).value).toBe('');
  });
});
