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
import type { BotDigestConfig } from '../../../hooks/queries/useBotDigestConfig';

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

/** Config de digest de `vinculadoActivo`, con el default de la base. */
const configDigestActivo: BotDigestConfig = {
  perfil_id: 'perfil-uno',
  perfil_nombre: 'Ana Gómez',
  telegram_user_id: 111,
  sucursal_id: 1,
  sucursal_nombre: 'Central',
  configurado: false,
  activo: true,
  hora_local: 7,
  dias_semana: [1, 2, 3, 4, 5, 6, 7],
  secciones: ['ventas', 'top_clientes', 'stock_critico', 'deuda', 'vencimientos'],
  actualizado_at: null,
  actualizado_por: null,
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
    configDigest: [configDigestActivo],
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
    loadingConfigDigest: false,
    loadingDigests: false,
    loadingAudit: false,
    loadingSummary: false,
    onRefresh: vi.fn(),
    onToggleUsuario,
    onGuardarConfigDigest: vi.fn(async () => {}),
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

  it('con el clamp de 200 filas y un total mayor, muestra "mostrando 200 de 350"', () => {
    // bot_admin_audit_log clampea p_limit a 200 (mig 019): el array que llega
    // nunca dice si hay más eventos que los traídos. auditSummary.total_eventos
    // sí tiene el total real del rango.
    const auditEvents: BotAuditEvent[] = Array.from({ length: 200 }, (_, i) => ({
      id: i + 1,
      telegram_user_id: 111,
      perfil_id: 'perfil-uno',
      perfil_nombre: 'Agustín Reiden',
      rol: 'admin',
      tipo: 'mensaje',
      tool_name: null,
      parametros: null,
      resultado_meta: null,
      texto_usuario: null,
      texto_bot: null,
      created_at: '2026-04-10T10:00:00Z',
    }));
    const props = buildProps({
      auditEvents,
      auditSummary: { ...summary, total_eventos: 350 },
    });

    render(<VistaBotTelegram {...props} />, { wrapper: Wrapper });

    expect(screen.getByText('mostrando 200 de 350 eventos')).toBeInTheDocument();
  });

  it('sin clamp (todos los eventos entraron), muestra sólo el conteo', () => {
    const auditEvents: BotAuditEvent[] = [{
      id: 1,
      telegram_user_id: 111,
      perfil_id: 'perfil-uno',
      perfil_nombre: 'Agustín Reiden',
      rol: 'admin',
      tipo: 'mensaje',
      tool_name: null,
      parametros: null,
      resultado_meta: null,
      texto_usuario: null,
      texto_bot: null,
      created_at: '2026-04-10T10:00:00Z',
    }];
    const props = buildProps({
      auditEvents,
      auditSummary: { ...summary, total_eventos: 1 },
    });

    render(<VistaBotTelegram {...props} />, { wrapper: Wrapper });

    expect(screen.getByText('1 eventos')).toBeInTheDocument();
  });

  describe('sección "Resumen automático"', () => {
    it('muestra cuándo y qué recibe cada admin', () => {
      render(<VistaBotTelegram {...buildProps()} />, { wrapper: Wrapper });

      // La fila resume hora y días en una frase, no en siete casilleros.
      expect(screen.getByText(/07:00 · todos los días/)).toBeInTheDocument();
    });

    it('marca "sin configurar" mientras la persona tenga el default', () => {
      render(<VistaBotTelegram {...buildProps()} />, { wrapper: Wrapper });

      // `configurado: false` — lo que se ve es el default, no una elección, y
      // la diferencia tiene que estar a la vista.
      expect(screen.getByText('sin configurar')).toBeInTheDocument();
    });

    it('un admin que se bajó no muestra horario ni secciones', () => {
      const props = buildProps({
        configDigest: [{ ...configDigestActivo, configurado: true, activo: false }],
      });
      render(<VistaBotTelegram {...props} />, { wrapper: Wrapper });

      expect(screen.queryByText(/07:00 · todos los días/)).not.toBeInTheDocument();
      expect(screen.getByRole('button', { name: /Configurar el resumen de Ana/i })).toBeInTheDocument();
    });

    it('abre el modal de configuración al tocar Configurar', async () => {
      const user = userEvent.setup();
      render(<VistaBotTelegram {...buildProps()} />, { wrapper: Wrapper });

      await user.click(screen.getByRole('button', { name: /Configurar el resumen de Ana/i }));

      expect(await screen.findByText(/Resumen de Ana Gómez/)).toBeInTheDocument();
    });
  });

});
