/**
 * Test de render para el estado de error de la campanita (DbNotificationBell).
 *
 * Antes de este fix, isError se ignoraba y una query fallida caía al mismo
 * "Sin notificaciones" que una lista vacía — el usuario no se enteraba de
 * que la campanita no pudo cargar nada.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';

const refetch = vi.fn();

vi.mock('../../../hooks/queries', () => ({
  useNotificacionesQuery: vi.fn(() => ({
    data: [],
    isLoading: false,
    isError: true,
    refetch,
  })),
  useMarcarNotificacionLeidaMutation: () => ({ mutate: vi.fn() }),
  useMarcarTodasNotificacionesLeidasMutation: () => ({ mutate: vi.fn() }),
}));

import DbNotificationBell from '../DbNotificationBell';

describe('DbNotificationBell', () => {
  it('en error, muestra el estado de error y no "Sin notificaciones"', async () => {
    render(
      <MemoryRouter>
        <DbNotificationBell />
      </MemoryRouter>,
    );

    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: /notificaciones/i }));

    expect(screen.getByText('No se pudo cargar.')).toBeInTheDocument();
    expect(screen.queryByText('Sin notificaciones')).not.toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: /reintentar/i }));
    expect(refetch).toHaveBeenCalledTimes(1);
  });
});
