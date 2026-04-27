/**
 * Tests para VistaBotTelegram (Phase 4 task 4.2).
 *
 * 3 tests mínimos:
 *   1) Render: con 2 vinculados, ambos aparecen en la tabla.
 *   2) Toggle: click en el badge dispara onToggleUsuario({telegram_user_id, activo:false})
 *      luego de window.confirm.
 *   3) Filtro: cambiar el select de tipo invoca onFiltersChange con el tipo nuevo.
 *
 * Mocks:
 *   - `useAuthData` para simular `isAdmin: true` (sin Provider).
 *   - `supabase` para evitar networking en la cadena de imports.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import type { ReactElement, ReactNode } from 'react';

// Mock supabase ANTES de importar el componente, mismo patrón que otros tests
// (la cadena de imports tira "supabaseUrl is required" en jsdom si no se mockea).
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

// Mock useAuthData: el componente solo lo usa para `isAdmin`. Forzamos true
// para que no haga el Navigate de redirección.
vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: true }),
}));

import VistaBotTelegram, { type VistaBotTelegramProps } from '../VistaBotTelegram';
import type {
  BotAuditEvent,
  BotAuditFilters,
  BotAuditSummary,
  BotDigestEnviado,
  BotToggleUsuarioResult,
  BotVinculado,
} from '../../../hooks/queries/useBotAdmin';

function Wrapper({ children }: { children: ReactNode }): ReactElement {
  return <MemoryRouter>{children}</MemoryRouter>;
}

const baseFilters: BotAuditFilters = {
  desde: '2026-04-01',
  hasta: '2026-04-27',
};

const summary: BotAuditSummary = {
  total_eventos: 10,
  por_tipo: [{ tipo: 'mensaje', count: 7 }],
  por_perfil: [],
  tools_top: [],
  errores_recientes: 0,
};

const vinculadoActivo: BotVinculado = {
  telegram_user_id: 111,
  telegram_username: 'agus',
  perfil_id: 'perfil-uno',
  perfil_nombre: 'Agustín Reiden',
  perfil_email: 'agus@example.com',
  rol: 'admin',
  sucursal_id: 1,
  sucursal_nombre: 'Central',
  vinculado_at: '2026-04-10T10:00:00Z',
  ultimo_uso_at: '2026-04-26T18:00:00Z',
  activo: true,
};

const vinculadoInactivo: BotVinculado = {
  telegram_user_id: 222,
  telegram_username: 'lucia',
  perfil_id: 'perfil-dos',
  perfil_nombre: 'Lucía Pereyra',
  perfil_email: 'lu@example.com',
  rol: 'preventista',
  sucursal_id: 2,
  sucursal_nombre: 'Zona Sur',
  vinculado_at: '2026-03-15T08:00:00Z',
  ultimo_uso_at: null,
  activo: false,
};

function buildProps(overrides: Partial<VistaBotTelegramProps> = {}): VistaBotTelegramProps {
  const onToggleUsuario = vi.fn(
    async (input: { telegram_user_id: number; activo: boolean }): Promise<BotToggleUsuarioResult> => ({
      success: true,
      telegram_user_id: input.telegram_user_id,
      activo: input.activo,
    }),
  );
  return {
    vinculados: [vinculadoActivo, vinculadoInactivo],
    digests: [] as BotDigestEnviado[],
    auditEvents: [] as BotAuditEvent[],
    auditSummary: summary,
    filters: baseFilters,
    onFiltersChange: vi.fn(),
    auditPage: 0,
    onAuditPageChange: vi.fn(),
    digestsPage: 0,
    onDigestsPageChange: vi.fn(),
    loadingVinculados: false,
    loadingDigests: false,
    loadingAudit: false,
    loadingSummary: false,
    onRefresh: vi.fn(),
    onToggleUsuario,
    ...overrides,
  };
}

describe('VistaBotTelegram', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('renderiza ambos vinculados en la tabla', () => {
    const props = buildProps();
    render(<VistaBotTelegram {...props} />, { wrapper: Wrapper });

    // Los nombres aparecen en la tabla (y también en el <option> del filtro
    // de perfil). Usamos getAllByText para no fallar por la duplicación.
    expect(screen.getAllByText('Agustín Reiden').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Lucía Pereyra').length).toBeGreaterThan(0);

    // El badge muestra Activo / Inactivo según el flag — único por aria-label.
    expect(screen.getByRole('button', { name: /desactivar agustín/i })).toHaveTextContent('Activo');
    expect(screen.getByRole('button', { name: /reactivar lucía/i })).toHaveTextContent('Inactivo');
  });

  it('al hacer click en el toggle de un activo, dispara la mutation con activo:false', async () => {
    const onToggleUsuario = vi.fn(
      async (input: { telegram_user_id: number; activo: boolean }): Promise<BotToggleUsuarioResult> => ({
        success: true,
        telegram_user_id: input.telegram_user_id,
        activo: input.activo,
      }),
    );
    const props = buildProps({ onToggleUsuario });

    // window.confirm devuelve true para que el toggle proceda.
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true);

    render(<VistaBotTelegram {...props} />, { wrapper: Wrapper });

    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: /desactivar agustín/i }));

    expect(confirmSpy).toHaveBeenCalled();
    expect(onToggleUsuario).toHaveBeenCalledTimes(1);
    expect(onToggleUsuario).toHaveBeenCalledWith({
      telegram_user_id: 111,
      activo: false,
    });
  });

  it('al cambiar el filtro de tipo, dispara onFiltersChange con el tipo nuevo', async () => {
    const onFiltersChange = vi.fn();
    const onAuditPageChange = vi.fn();
    const props = buildProps({ onFiltersChange, onAuditPageChange });

    render(<VistaBotTelegram {...props} />, { wrapper: Wrapper });

    const user = userEvent.setup();
    const select = screen.getByRole('combobox', { name: /filtrar por tipo/i });
    await user.selectOptions(select, 'error');

    expect(onFiltersChange).toHaveBeenCalledTimes(1);
    expect(onFiltersChange).toHaveBeenCalledWith({
      ...baseFilters,
      tipo: 'error',
    });
    // Cambiar el filtro también resetea la paginación del audit log.
    expect(onAuditPageChange).toHaveBeenCalledWith(0);
  });
});
