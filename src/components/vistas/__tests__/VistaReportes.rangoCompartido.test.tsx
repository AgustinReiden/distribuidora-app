/**
 * Desde/Hasta son los mismos inputs para Preventistas y Rentabilidad, pero
 * "Generar" recarga sólo la pestaña activa (#1263). Rentabilidad cargaba al
 * volver sólo si estaba vacía: abierta con un período, cambiado el rango desde
 * Preventistas, al volver mostraba el período viejo debajo de un filtro que
 * decía otro. Y al revés con Preventistas.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { MemoryRouter } from 'react-router-dom';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

const mockRentabilidad = vi.fn(async (_d: string | null, _h: string | null, _c?: string) => ({
  // Con datos: el código de antes recargaba sólo si la lista estaba vacía.
  productos: [{ producto_id: '1' }],
  totales: {},
}));

vi.mock('../../../hooks/supabase', () => ({
  useReportesFinancieros: () => ({
    loading: false,
    generarReporteCuentasPorCobrar: vi.fn(async () => []),
    generarReporteRentabilidad: mockRentabilidad,
  }),
}));

vi.mock('../reportes', () => ({
  ReportePreventistas: () => <p>[contenido preventistas]</p>,
  ReporteCuentasPorCobrar: () => <p>[contenido cuentas]</p>,
  ReporteRentabilidadSection: () => <p>[contenido rentabilidad]</p>,
  ReporteVentasClientes: () => <p>[contenido clientes]</p>,
  ReporteVentasZonas: () => <p>[contenido zonas]</p>,
  ReporteValuacionInventario: () => <p>[contenido valuacion]</p>,
  ReporteStockRed: () => <p>[contenido stock-red]</p>,
  ReporteMermas: () => <p>[contenido mermas]</p>,
  ReporteRechazos: () => <p>[contenido rechazos]</p>,
  FiltrosVentas: () => <p>[filtros de ventas]</p>,
  filtrosVentasIniciales: () => ({ desde: '2026-10-01', hasta: '2026-10-31', presetId: 'este-mes', preventistaId: null }),
}));

import VistaReportes from '../VistaReportes';

function renderVista(entrada: string, onCalcularReporte = vi.fn(async () => {})): void {
  render(
    <MemoryRouter initialEntries={[entrada]}>
      <VistaReportes
        reportePreventistas={[]}
        reporteInicializado={true}
        loading={false}
        onCalcularReporte={onCalcularReporte}
      />
    </MemoryRouter>
  );
}

async function ponerRango(user: ReturnType<typeof userEvent.setup>, desde: string, hasta: string): Promise<void> {
  await user.clear(screen.getByLabelText('Desde'));
  await user.type(screen.getByLabelText('Desde'), desde);
  await user.clear(screen.getByLabelText('Hasta'));
  await user.type(screen.getByLabelText('Hasta'), hasta);
}

describe('VistaReportes — el rango es compartido entre pestañas', () => {
  beforeEach(() => {
    mockRentabilidad.mockClear();
  });

  it('Rentabilidad recarga con el rango nuevo al volver, aunque ya tuviera datos', async () => {
    const user = userEvent.setup();
    renderVista('/reportes?tab=rentabilidad&desde=2026-01-01&hasta=2026-03-31');
    expect(mockRentabilidad).toHaveBeenLastCalledWith('2026-01-01', '2026-03-31', 'incluir');

    await user.click(screen.getByRole('tab', { name: 'Por Preventista' }));
    await ponerRango(user, '2026-04-01', '2026-06-30');
    await user.click(screen.getByRole('button', { name: /Generar/ }));
    await user.click(screen.getByRole('tab', { name: 'Rentabilidad' }));

    expect(mockRentabilidad).toHaveBeenLastCalledWith('2026-04-01', '2026-06-30', 'incluir');
  });

  it('Rentabilidad no recarga al volver si el rango no cambió', async () => {
    const user = userEvent.setup();
    renderVista('/reportes?tab=rentabilidad&desde=2026-01-01&hasta=2026-03-31');

    await user.click(screen.getByRole('tab', { name: 'Por Preventista' }));
    await user.click(screen.getByRole('tab', { name: 'Rentabilidad' }));

    expect(mockRentabilidad).toHaveBeenCalledTimes(1);
  });

  it('Preventistas se pide con el rango que se generó desde Rentabilidad', async () => {
    const user = userEvent.setup();
    const onCalcularReporte = vi.fn(async () => {});
    renderVista('/reportes?tab=rentabilidad', onCalcularReporte);

    await ponerRango(user, '2026-04-01', '2026-06-30');
    await user.click(screen.getByRole('button', { name: /Generar/ }));
    await user.click(screen.getByRole('tab', { name: 'Por Preventista' }));

    expect(onCalcularReporte).toHaveBeenLastCalledWith('2026-04-01', '2026-06-30');
  });
});
