/**
 * REP-A (#1544): un error del RPC no se muestra como «sin datos».
 *
 * `useReportesFinancieros` avisaba con un toast y devolvía `[]` / totales vacíos: Cuentas por
 * Cobrar decía «No hay cuentas pendientes de cobro» y Rentabilidad mostraba $0, como si no
 * hubiera deuda ni ventas. Acá corre el hook de verdad (sólo el RPC está mockeado) dentro de
 * `VistaReportes`: con el RPC en error se ve el estado de error con «Reintentar», nunca el
 * vacío ni los ceros, y reintentar vuelve a pedir el RPC.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { MemoryRouter } from 'react-router-dom';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

const mockRpc = vi.fn();

vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn() },
}));
vi.mock('../../../hooks/supabase/base', () => ({
  supabase: { rpc: (...args: unknown[]) => mockRpc(...args) },
  notifyError: vi.fn(),
}));
vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}));
// El índice trae decenas de hooks: acá sólo importa el de reportes financieros, el real.
vi.mock('../../../hooks/supabase', async () => {
  const real = await import('../../../hooks/supabase/useReportesFinancieros');
  return { useReportesFinancieros: real.useReportesFinancieros };
});

import VistaReportes from '../VistaReportes';

function renderVista(tab: 'cuentas' | 'rentabilidad'): void {
  render(
    <MemoryRouter initialEntries={[`/reportes?tab=${tab}`]}>
      <VistaReportes
        reportePreventistas={[]}
        reporteInicializado={true}
        loading={false}
        onCalcularReporte={vi.fn(async () => {})}
      />
    </MemoryRouter>
  );
}

const rpcEnError = { data: null, error: { message: 'boom' } };

describe('VistaReportes — el RPC en error no es «sin datos» (REP-A)', () => {
  beforeEach(() => {
    mockRpc.mockReset();
  });

  it('Cuentas por Cobrar: con el RPC en error muestra el error, no «No hay cuentas pendientes», y Reintentar vuelve a pedir', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValue(rpcEnError);
    renderVista('cuentas');

    expect(await screen.findByRole('alert')).toBeInTheDocument();
    expect(screen.queryByText(/No hay cuentas pendientes de cobro/)).not.toBeInTheDocument();
    expect(mockRpc).toHaveBeenCalledTimes(1);

    // El reintento anda: ahora la base contesta sin clientes con deuda y recién ahí es «vacío».
    mockRpc.mockResolvedValue({ data: { clientes: [], consistencia: { clientes_con_desvio: [] } }, error: null });
    await user.click(screen.getByRole('button', { name: 'Reintentar' }));

    await waitFor(() => expect(mockRpc).toHaveBeenCalledTimes(2));
    expect(mockRpc).toHaveBeenLastCalledWith('reporte_cuentas_por_cobrar', { p_sucursal_id: 2 });
    expect(await screen.findByText(/No hay cuentas pendientes de cobro/)).toBeInTheDocument();
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  it('Rentabilidad: con el RPC en error muestra el error, no los totales en $0, y Reintentar vuelve a pedir', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValue(rpcEnError);
    renderVista('rentabilidad');

    expect(await screen.findByRole('alert')).toBeInTheDocument();
    expect(screen.queryByText('Ventas Brutas')).not.toBeInTheDocument();
    expect(screen.queryByText(/No hay datos de rentabilidad/)).not.toBeInTheDocument();
    expect(mockRpc).toHaveBeenCalledTimes(1);

    mockRpc.mockResolvedValue({ data: { productos: [], totales: {} }, error: null });
    await user.click(screen.getByRole('button', { name: 'Reintentar' }));

    await waitFor(() => expect(mockRpc).toHaveBeenCalledTimes(2));
    expect(mockRpc).toHaveBeenLastCalledWith('reporte_rentabilidad', expect.objectContaining({ p_sucursal_id: 2 }));
    expect(await screen.findByText('Ventas Brutas')).toBeInTheDocument();
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });
});
