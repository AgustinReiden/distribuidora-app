/**
 * Caracterizacion del estado de CARGA de las vistas de lista y tabla (WP-45,
 * #770: skeletons en lugar del spinner suelto).
 *
 * Fija, por rol ARIA y por texto (nunca por clase), lo que ve el usuario mientras
 * una vista carga:
 *  - hay UN aviso `role="status"` que dice "Cargando...", que es lo que le llega
 *    a un lector de pantalla;
 *  - NO se dibuja el contenido: ni la tabla con sus encabezados ni las tarjetas.
 *    Cada caso monta la vista con datos reales y `loading` en true, y un control
 *    con `loading` en false prueba que esos mismos datos SI se dibujan (si no,
 *    "no aparece" no probaria nada).
 *
 * Lo que distingue al skeleton del spinner y NO se puede ver por rol o texto es la
 * forma de lo que se dibuja; por eso cada caso suma ademas que el aviso es el de
 * `CargandoContenido` (`data-slot="cargando-contenido"`), que el spinner suelto no
 * lleva. No es `aria-busy`: sobre la region viva callaria el aviso.
 *
 * Los skeletons que llevan una `<table>` adentro quedan escondidos del arbol de
 * accesibilidad (`aria-hidden`), asi que `queryByRole('table')` sigue siendo null
 * mientras carga.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { render, screen, within } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { MemoryRouter } from 'react-router-dom';
import type { ReactElement, ReactNode } from 'react';

// Mock de supabase antes de importar las vistas: la cadena de imports pide
// supabaseUrl al cargarse y jsdom tira "supabaseUrl is required".
vi.mock('../../../lib/supabase', () => ({
  supabase: {
    rpc: vi.fn(),
    from: vi.fn(),
    auth: {
      getUser: vi.fn(() => Promise.resolve({ data: { user: null } })),
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(),
}));

vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1, currentSucursalNombre: 'Test' }),
}));

vi.mock('../../../lib/pdfExport', () => ({
  generarReciboPedido: vi.fn(),
}));

import VistaPedidos, { type VistaPedidosProps } from '../VistaPedidos';
import VistaCompras from '../VistaCompras';
import VistaProductos from '../VistaProductos';
import VistaUsuarios from '../VistaUsuarios';
import VistaComisiones from '../VistaComisiones';
import VistaDashboard from '../VistaDashboard';
import VistaBotTelegram, { type VistaBotTelegramProps } from '../VistaBotTelegram';
import { AuthDataProvider } from '../../../contexts/AuthDataContext';
import { NotificationProvider } from '../../../contexts/NotificationContext';
import { EMPTY_PEDIDO_STATS_SUMMARY } from '../../../hooks/queries';
import type { ComisionesResultado } from '../../../hooks/queries/useComisionesQuery';
import type {
  BotAuditEvent,
  BotAuditFilters,
  BotAuditSummary,
  BotDigestEnviado,
  BotVinculado,
} from '../../../hooks/queries/useBotAdmin';
import type { BotDigestConfig } from '../../../hooks/queries/useBotDigestConfig';
import type {
  CompraDBExtended,
  FiltrosPedidosState,
  PerfilDB,
  ProductoDB,
  ProveedorDBExtended,
} from '../../../types';
import { PEDIDOS_FIXTURE } from '../../../../dev/gallery/fixtures/pedidos';
import { authDataDeRol } from '../../../../dev/gallery/fixtures/auth';
import { PRODUCTOS_FIXTURE } from '../../../../dev/gallery/fixtures/catalogo';
import {
  METRICAS_DASHBOARD,
  TOTAL_CLIENTES_DASHBOARD,
  PRODUCTOS_STOCK_BAJO_DASHBOARD,
  AVANCE_METAS_DASHBOARD,
} from '../../../../dev/gallery/fixtures/dashboard';

// Radix y floating-ui piden APIs que jsdom no trae (mismo parche que
// PedidoCard.caracterizacion.test.tsx).
class ObservadorStub {
  observe(): void { /* no-op */ }
  unobserve(): void { /* no-op */ }
  disconnect(): void { /* no-op */ }
  takeRecords(): [] { return []; }
}
globalThis.ResizeObserver = ObservadorStub as unknown as typeof ResizeObserver;
globalThis.IntersectionObserver = ObservadorStub as unknown as typeof IntersectionObserver;
if (!Element.prototype.hasPointerCapture) Element.prototype.hasPointerCapture = (): boolean => false;
if (!Element.prototype.setPointerCapture) Element.prototype.setPointerCapture = (): void => undefined;
if (!Element.prototype.releasePointerCapture) Element.prototype.releasePointerCapture = (): void => undefined;
if (!Element.prototype.scrollIntoView) Element.prototype.scrollIntoView = (): void => undefined;

function Proveedores({ children }: { children: ReactNode }): ReactElement {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
  return (
    <MemoryRouter>
      <QueryClientProvider client={qc}>
        <NotificationProvider>
          <AuthDataProvider value={authDataDeRol('admin')}>{children}</AuthDataProvider>
        </NotificationProvider>
      </QueryClientProvider>
    </MemoryRouter>
  );
}

function montar(ui: ReactElement) {
  return render(ui, { wrapper: Proveedores });
}

/**
 * El aviso de carga. Rol y texto son los mismos para el spinner suelto y para el
 * skeleton; `data-slot` es lo que dice que lo que hay es un skeleton: lo pone
 * `CargandoContenido` y `LoadingSpinner` no.
 */
function avisoDeCarga(scope: { getByRole: typeof screen.getByRole } = screen): HTMLElement {
  const aviso = scope.getByRole('status');
  expect(aviso).toHaveTextContent('Cargando...');
  expect(aviso).toHaveAttribute('data-slot', 'cargando-contenido');
  return aviso;
}

// =============================================================================
// VistaPedidos
// =============================================================================

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

const pedidoEjemplo = PEDIDOS_FIXTURE[0].pedido;
const nombreClientePedido = pedidoEjemplo.cliente?.nombre_fantasia as string;

function propsPedidos(overrides: Partial<VistaPedidosProps> = {}): VistaPedidosProps {
  return {
    pedidos: [pedidoEjemplo],
    totalCount: 1,
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
    onVerHistorial: vi.fn(),
    onEditarPedido: vi.fn(),
    onMarcarEnPreparacion: vi.fn(),
    onVolverAPendiente: vi.fn(),
    onMarcarEntregado: vi.fn(),
    onDesmarcarEntregado: vi.fn(),
    ...overrides,
  };
}

describe('VistaPedidos cargando', () => {
  it('control: con loading=false dibuja la tarjeta del pedido y no hay aviso de carga', () => {
    montar(<VistaPedidos {...propsPedidos()} />);
    expect(screen.getAllByText(nombreClientePedido).length).toBeGreaterThan(0);
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('con loading=true avisa "Cargando..." y no dibuja las tarjetas ni el vacio', () => {
    montar(<VistaPedidos {...propsPedidos({ loading: true })} />);
    const aviso = avisoDeCarga();
    expect(screen.queryByText(nombreClientePedido)).not.toBeInTheDocument();
    expect(screen.queryByText('No hay pedidos')).not.toBeInTheDocument();
    expect(aviso).toBeInTheDocument();
  });
});

// =============================================================================
// VistaCompras
// =============================================================================

const compraEjemplo = {
  id: '501',
  proveedor_id: '9',
  proveedor: { id: '9', nombre: 'Proveedor Fixture SA' },
  proveedor_nombre: 'Proveedor Fixture SA',
  numero_factura: 'A-0001',
  estado: 'recibida',
  total: 50000,
  fecha_compra: '2026-09-20',
  created_at: '2026-09-20T10:00:00Z',
  items: [],
} as unknown as CompraDBExtended;

function propsCompras(loading: boolean) {
  return {
    compras: [compraEjemplo],
    proveedores: [] as ProveedorDBExtended[],
    loading,
    isAdmin: true,
    isEncargado: false,
    onNuevaCompra: vi.fn(),
    onVerDetalle: vi.fn(),
    onAnularCompra: vi.fn(),
  };
}

describe('VistaCompras cargando', () => {
  it('control: con loading=false dibuja la tabla con sus encabezados y la compra', () => {
    montar(<VistaCompras {...propsCompras(false)} />);
    expect(screen.getByRole('table')).toBeInTheDocument();
    expect(screen.getByRole('columnheader', { name: 'Proveedor' })).toBeInTheDocument();
    expect(screen.getAllByText('Proveedor Fixture SA').length).toBeGreaterThan(0);
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('con loading=true avisa "Cargando..." y no dibuja la tabla ni las tarjetas', () => {
    montar(<VistaCompras {...propsCompras(true)} />);
    const aviso = avisoDeCarga();
    expect(screen.queryByRole('table')).not.toBeInTheDocument();
    expect(screen.queryByRole('columnheader', { name: 'Proveedor' })).not.toBeInTheDocument();
    expect(screen.queryByText('Proveedor Fixture SA')).not.toBeInTheDocument();
    expect(screen.queryByText('No hay compras registradas')).not.toBeInTheDocument();
    expect(aviso).toBeInTheDocument();
  });
});

// =============================================================================
// VistaProductos
// =============================================================================

const productoEjemplo: ProductoDB = PRODUCTOS_FIXTURE.manaosCola;

function propsProductos(loading: boolean) {
  return {
    productos: [productoEjemplo],
    productosStockBajo: [] as ProductoDB[],
    loading,
    isAdmin: true,
    onNuevoProducto: vi.fn(),
    onEditarProducto: vi.fn(),
    onEliminarProducto: vi.fn(),
  };
}

describe('VistaProductos cargando', () => {
  it('control: con loading=false dibuja la tabla con sus encabezados y el producto', () => {
    montar(<VistaProductos {...propsProductos(false)} />);
    expect(screen.getByRole('table')).toBeInTheDocument();
    expect(screen.getByRole('columnheader', { name: 'Producto' })).toBeInTheDocument();
    expect(screen.getAllByText(productoEjemplo.nombre).length).toBeGreaterThan(0);
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('con loading=true avisa "Cargando..." y no dibuja la tabla ni las tarjetas', () => {
    montar(<VistaProductos {...propsProductos(true)} />);
    const aviso = avisoDeCarga();
    expect(screen.queryByRole('table')).not.toBeInTheDocument();
    expect(screen.queryByRole('columnheader', { name: 'Producto' })).not.toBeInTheDocument();
    expect(screen.queryByText(productoEjemplo.nombre)).not.toBeInTheDocument();
    expect(screen.queryByText('No hay productos')).not.toBeInTheDocument();
    expect(aviso).toBeInTheDocument();
  });
});

// =============================================================================
// VistaUsuarios
// =============================================================================

const usuarioEjemplo = {
  id: 'u-1',
  nombre: 'Usuario Fixture',
  email: 'fixture@distribuidora.test',
  rol: 'preventista',
  activo: true,
} as unknown as PerfilDB;

describe('VistaUsuarios cargando', () => {
  it('control: con loading=false dibuja la tabla con sus encabezados y el usuario', () => {
    montar(<VistaUsuarios usuarios={[usuarioEjemplo]} loading={false} onEditarUsuario={vi.fn()} />);
    expect(screen.getByRole('table')).toBeInTheDocument();
    expect(screen.getByRole('columnheader', { name: 'Email' })).toBeInTheDocument();
    expect(screen.getByText('Usuario Fixture')).toBeInTheDocument();
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('con loading=true avisa "Cargando..." y no dibuja la tabla', () => {
    montar(<VistaUsuarios usuarios={[usuarioEjemplo]} loading onEditarUsuario={vi.fn()} />);
    const aviso = avisoDeCarga();
    expect(screen.queryByRole('table')).not.toBeInTheDocument();
    expect(screen.queryByRole('columnheader', { name: 'Email' })).not.toBeInTheDocument();
    expect(screen.queryByText('Usuario Fixture')).not.toBeInTheDocument();
    expect(screen.queryByText('No hay usuarios')).not.toBeInTheDocument();
    expect(aviso).toBeInTheDocument();
  });
});

// =============================================================================
// VistaComisiones
// =============================================================================

const resultadoComisiones: ComisionesResultado = {
  desde: '2026-07-01',
  hasta: '2026-07-27',
  comision_default: 2,
  preventistas: [
    {
      id: 'u1',
      nombre: 'Ana Fixture',
      email: 'ana@x.com',
      base: 100000,
      comision: 2000,
      items: 10,
      items_sin_desglose: 0,
      base_sin_desglose: 0,
      por_origen: [],
    },
  ],
  totales: { base: 100000, comision: 2000, items: 10, items_sin_desglose: 0, base_sin_desglose: 0 },
};

function propsComisiones(loading: boolean) {
  return {
    resultado: resultadoComisiones,
    loading,
    fechaDesde: '2026-07-01',
    fechaHasta: '2026-07-27',
    onFiltrar: vi.fn(),
  };
}

describe('VistaComisiones cargando', () => {
  it('control: con loading=false dibuja la tabla con sus encabezados y al vendedor', () => {
    montar(<VistaComisiones {...propsComisiones(false)} />);
    expect(screen.getByRole('table')).toBeInTheDocument();
    expect(screen.getByRole('columnheader', { name: 'Vendedor' })).toBeInTheDocument();
    expect(screen.getAllByText(/Ana Fixture/).length).toBeGreaterThan(0);
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('con loading=true avisa "Cargando..." y no dibuja la tabla', () => {
    montar(<VistaComisiones {...propsComisiones(true)} />);
    const aviso = avisoDeCarga();
    expect(screen.queryByRole('table')).not.toBeInTheDocument();
    expect(screen.queryByRole('columnheader', { name: 'Vendedor' })).not.toBeInTheDocument();
    expect(screen.queryByText(/Ana Fixture/)).not.toBeInTheDocument();
    expect(screen.queryByText('No hay datos para el periodo seleccionado')).not.toBeInTheDocument();
    expect(aviso).toBeInTheDocument();
  });
});

// =============================================================================
// VistaDashboard
// =============================================================================

function montarDashboard(loading: boolean) {
  return montar(
    <VistaDashboard
      metricas={METRICAS_DASHBOARD}
      loading={loading}
      filtroPeriodo="mes"
      onCambiarPeriodo={vi.fn()}
      onRefetch={vi.fn()}
      onDescargarBackup={vi.fn(async () => {})}
      exportando={false}
      productosStockBajo={PRODUCTOS_STOCK_BAJO_DASHBOARD}
      totalClientes={TOTAL_CLIENTES_DASHBOARD}
      avanceMetas={AVANCE_METAS_DASHBOARD}
      isAdmin
    />,
  );
}

describe('VistaDashboard cargando', () => {
  it('control: con loading=false dibuja el titulo y las secciones, sin aviso de carga', () => {
    montarDashboard(false);
    expect(screen.getByRole('heading', { level: 1 })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Estado de pedidos' })).toBeInTheDocument();
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('con loading=true avisa "Cargando..." y no dibuja titulo ni secciones', () => {
    montarDashboard(true);
    const aviso = avisoDeCarga();
    expect(screen.queryByRole('heading', { level: 1 })).not.toBeInTheDocument();
    expect(screen.queryByRole('heading', { name: 'Estado de pedidos' })).not.toBeInTheDocument();
    expect(aviso).toBeInTheDocument();
  });
});

// =============================================================================
// VistaBotTelegram: las 4 tablas, cada una con su propio loading
// =============================================================================

const baseFilters: BotAuditFilters = { desde: '2026-04-01', hasta: '2026-04-27' };

const summary: BotAuditSummary = {
  total_eventos: 10,
  por_tipo: [{ tipo: 'mensaje', count: 7 }],
  por_perfil: [],
  tools_top: [],
  errores_recientes: 0,
};

const vinculado: BotVinculado = {
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

const configDigest: BotDigestConfig = {
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
  es_propio: true,
};

const digestEnviado: BotDigestEnviado = {
  admin_perfil_id: 'perfil-uno',
  perfil_nombre: 'Agustín Reiden',
  sucursal_nombre: 'Central',
  fecha: '2026-04-26',
  sent_at: '2026-04-27T10:00:00Z',
  telegram_user_id: 111,
  status: 'ok',
  error_meta: null,
};

const eventoAudit: BotAuditEvent = {
  id: 1,
  telegram_user_id: 111,
  perfil_id: 'perfil-uno',
  perfil_nombre: 'Agustín Reiden',
  rol: 'admin',
  tipo: 'mensaje',
  tool_name: null,
  parametros: null,
  resultado_meta: null,
  texto_usuario: 'hola bot',
  texto_bot: null,
  created_at: '2026-04-26T18:00:00Z',
};

function propsBot(overrides: Partial<VistaBotTelegramProps> = {}): VistaBotTelegramProps {
  return {
    vinculados: [vinculado],
    configDigest: [configDigest],
    digests: [digestEnviado],
    auditEvents: [eventoAudit],
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
    onToggleUsuario: vi.fn(),
    onGuardarConfigDigest: vi.fn(async () => {}),
    ...overrides,
  };
}

const TABLAS_BOT: Array<{
  region: string;
  flag: keyof VistaBotTelegramProps;
  encabezado: string;
  vacio: string;
}> = [
  { region: 'Usuarios vinculados', flag: 'loadingVinculados', encabezado: 'Sucursal', vacio: 'No hay usuarios vinculados.' },
  { region: 'Digests recientes (último mes)', flag: 'loadingDigests', encabezado: 'Status', vacio: 'Aún no se enviaron digests en el último mes.' },
  { region: 'Audit log', flag: 'loadingAudit', encabezado: 'Tool', vacio: 'No hay eventos en el rango seleccionado.' },
];

describe('VistaBotTelegram cargando', () => {
  it('control: sin ningun loading dibuja las 4 tablas y ningun aviso de carga', () => {
    montar(<VistaBotTelegram {...propsBot()} />);
    expect(screen.getAllByRole('table')).toHaveLength(3);
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('Mensajes automáticos: con loadingConfigDigest=true avisa "Cargando..." y no dibuja tarjetas', () => {
    montar(<VistaBotTelegram {...propsBot({ loadingConfigDigest: true })} />);
    const seccion = screen.getByRole('region', { name: 'Mensajes automáticos' });

    expect(avisoDeCarga(within(seccion))).toBeInTheDocument();
    expect(within(seccion).queryByRole('article')).not.toBeInTheDocument();
    expect(within(seccion).queryByText('Tu resumen')).not.toBeInTheDocument();
    expect(screen.getAllByRole('status')).toHaveLength(1);
  });

  it.each(TABLAS_BOT)(
    '$region: con $flag=true avisa "Cargando..." y esa tabla no se dibuja',
    ({ region, flag, encabezado, vacio }) => {
      montar(<VistaBotTelegram {...propsBot({ [flag]: true })} />);
      const seccion = screen.getByRole('region', { name: region });

      const aviso = avisoDeCarga(within(seccion));
      expect(within(seccion).queryByRole('table')).not.toBeInTheDocument();
      expect(within(seccion).queryByRole('columnheader', { name: encabezado })).not.toBeInTheDocument();
      expect(within(seccion).queryByText(vacio)).not.toBeInTheDocument();
      expect(aviso).toBeInTheDocument();

      // Las otras dos siguen dibujadas: cada tabla carga por su cuenta.
      expect(screen.getAllByRole('table')).toHaveLength(2);
      expect(screen.getAllByRole('status')).toHaveLength(1);
    },
  );
});
