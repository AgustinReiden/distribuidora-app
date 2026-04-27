/**
 * VistaBotTelegram — Vista admin de observabilidad del bot Telegram (Phase 4 task 4.2).
 *
 * Layout:
 *   - Header con icono Send + título + botón refresh.
 *   - 4 stats cards (mensajes hoy / errores 24h / usuarios activos / digests del mes).
 *   - Sección 1: usuarios vinculados con toggle activo.
 *   - Sección 2: digests recientes (último mes) paginados.
 *   - Sección 3: audit log con filtros (fecha, tipo, perfil), paginado, modal de detalle.
 *
 * Gating: si !isAdmin → Navigate a /dashboard. La RPC también gatea por rol
 * desde la migración 019, así que es defensa en profundidad.
 */
import { useMemo, useState, type ChangeEvent, type ComponentType, type ReactElement, type ReactNode } from 'react';
import { Navigate } from 'react-router-dom';
import {
  Send,
  RefreshCw,
  Users,
  AlertTriangle,
  MessageSquare,
  Mail,
  ChevronLeft,
  ChevronRight,
  X,
} from 'lucide-react';
import { useAuthData } from '../../contexts/AuthDataContext';
import { formatDateTime, formatFecha } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';
import type {
  BotAuditEvent,
  BotAuditFilters,
  BotAuditSummary,
  BotDigestEnviado,
  BotToggleUsuarioInput,
  BotToggleUsuarioResult,
  BotVinculado,
} from '../../hooks/queries/useBotAdmin';

const TIPO_OPCIONES: Array<{ value: string; label: string }> = [
  { value: '', label: 'Todos los tipos' },
  { value: 'mensaje', label: 'Mensaje' },
  { value: 'comando', label: 'Comando' },
  { value: 'tool_call', label: 'Tool call' },
  { value: 'respuesta', label: 'Respuesta' },
  { value: 'error', label: 'Error' },
];

const TIPO_BADGE: Record<string, string> = {
  mensaje: 'bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300',
  comando: 'bg-purple-100 dark:bg-purple-900/30 text-purple-700 dark:text-purple-300',
  tool_call: 'bg-amber-100 dark:bg-amber-900/30 text-amber-700 dark:text-amber-300',
  respuesta: 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-300',
  error: 'bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-300',
};

const PAGE_SIZE_DIGESTS = 20;
const PAGE_SIZE_AUDIT = 50;

export interface VistaBotTelegramProps {
  // Datos
  vinculados: BotVinculado[];
  digests: BotDigestEnviado[];
  auditEvents: BotAuditEvent[];
  auditSummary: BotAuditSummary | null;

  // Filtros + paginación
  filters: BotAuditFilters;
  onFiltersChange: (next: BotAuditFilters) => void;
  auditPage: number;
  onAuditPageChange: (next: number) => void;
  digestsPage: number;
  onDigestsPageChange: (next: number) => void;

  // Loading flags
  loadingVinculados: boolean;
  loadingDigests: boolean;
  loadingAudit: boolean;
  loadingSummary: boolean;

  // Acciones
  onRefresh: () => void;
  onToggleUsuario: (input: BotToggleUsuarioInput) => Promise<BotToggleUsuarioResult>;
}

export default function VistaBotTelegram(props: VistaBotTelegramProps): ReactElement {
  const { isAdmin } = useAuthData();

  const {
    vinculados,
    digests,
    auditEvents,
    auditSummary,
    filters,
    onFiltersChange,
    auditPage,
    onAuditPageChange,
    digestsPage,
    onDigestsPageChange,
    loadingVinculados,
    loadingDigests,
    loadingAudit,
    loadingSummary,
    onRefresh,
    onToggleUsuario,
  } = props;

  // Modal con detalle de evento (JSON pretty).
  const [eventoDetalle, setEventoDetalle] = useState<BotAuditEvent | null>(null);
  // Toggle en curso (para deshabilitar el badge mientras corre la mutation).
  const [togglingId, setTogglingId] = useState<number | null>(null);

  // ============================================================================
  // Paginación local — hooks ANTES del early return para respetar rules-of-hooks.
  // ============================================================================
  const digestsPaginados = useMemo(() => {
    const start = digestsPage * PAGE_SIZE_DIGESTS;
    return digests.slice(start, start + PAGE_SIZE_DIGESTS);
  }, [digests, digestsPage]);

  const auditPaginados = useMemo(() => {
    const start = auditPage * PAGE_SIZE_AUDIT;
    return auditEvents.slice(start, start + PAGE_SIZE_AUDIT);
  }, [auditEvents, auditPage]);

  if (!isAdmin) {
    return <Navigate to="/dashboard" replace />;
  }

  // ============================================================================
  // Stats cards
  // ============================================================================
  const usuariosActivos = vinculados.filter((u) => u.activo).length;
  const erroresUltimas24h = auditSummary?.errores_recientes ?? 0;
  // "Mensajes hoy": tomamos el count del tipo `mensaje` del summary del rango
  // actual. Si el filtro abarca solo hoy, refleja el día; si abarca más, queda
  // claro porque el rango lo dibuja arriba el componente.
  const mensajesEnRango =
    auditSummary?.por_tipo?.find((t) => t.tipo === 'mensaje')?.count ?? 0;
  const digestsEnviados = digests.length;

  const digestsTotalPages = Math.max(1, Math.ceil(digests.length / PAGE_SIZE_DIGESTS));
  const auditTotalPages = Math.max(1, Math.ceil(auditEvents.length / PAGE_SIZE_AUDIT));

  // ============================================================================
  // Handlers
  // ============================================================================
  const handleToggleUsuario = async (u: BotVinculado): Promise<void> => {
    const accion = u.activo ? 'desactivar' : 'reactivar';
    const ok = window.confirm(
      `¿${accion === 'desactivar' ? 'Desactivar' : 'Reactivar'} a ${u.perfil_nombre ?? u.telegram_username ?? 'este usuario'}?`,
    );
    if (!ok) return;
    setTogglingId(u.telegram_user_id);
    try {
      await onToggleUsuario({ telegram_user_id: u.telegram_user_id, activo: !u.activo });
    } finally {
      setTogglingId(null);
    }
  };

  const handleFilterTipo = (e: ChangeEvent<HTMLSelectElement>): void => {
    const value = e.target.value;
    onFiltersChange({ ...filters, tipo: value === '' ? undefined : value });
    onAuditPageChange(0);
  };

  const handleFilterPerfil = (e: ChangeEvent<HTMLSelectElement>): void => {
    const value = e.target.value;
    onFiltersChange({ ...filters, perfil_id: value === '' ? undefined : value });
    onAuditPageChange(0);
  };

  const handleFilterDesde = (e: ChangeEvent<HTMLInputElement>): void => {
    onFiltersChange({ ...filters, desde: e.target.value });
    onAuditPageChange(0);
  };

  const handleFilterHasta = (e: ChangeEvent<HTMLInputElement>): void => {
    onFiltersChange({ ...filters, hasta: e.target.value });
    onAuditPageChange(0);
  };

  // ============================================================================
  // Render
  // ============================================================================
  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="p-2 bg-blue-600 rounded-lg">
            <Send className="w-5 h-5 text-white" aria-hidden="true" />
          </div>
          <div>
            <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Bot Telegram</h1>
            <p className="text-gray-600 dark:text-gray-400 text-sm">
              Observabilidad: usuarios vinculados, digests y eventos del agente.
            </p>
          </div>
        </div>
        <button
          onClick={onRefresh}
          className="flex items-center gap-2 px-3 py-2 rounded-lg border border-gray-300 dark:border-gray-700 text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
          aria-label="Refrescar datos"
        >
          <RefreshCw className="w-4 h-4" aria-hidden="true" />
          <span className="text-sm font-medium">Refrescar</span>
        </button>
      </div>

      {/* Stats cards */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <StatsCard
          label="Mensajes hoy"
          value={mensajesEnRango}
          loading={loadingSummary}
          icon={MessageSquare}
          tone="blue"
        />
        <StatsCard
          label="Errores 24h"
          value={erroresUltimas24h}
          loading={loadingSummary}
          icon={AlertTriangle}
          tone={erroresUltimas24h > 0 ? 'red' : 'gray'}
        />
        <StatsCard
          label="Usuarios activos"
          value={usuariosActivos}
          loading={loadingVinculados}
          icon={Users}
          tone="green"
        />
        <StatsCard
          label="Digests enviados (mes)"
          value={digestsEnviados}
          loading={loadingDigests}
          icon={Mail}
          tone="purple"
        />
      </div>

      {/* Sección 1: usuarios vinculados */}
      <section
        aria-labelledby="bot-vinculados-h"
        className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm"
      >
        <div className="px-4 py-3 border-b dark:border-gray-700 flex items-center justify-between">
          <h2 id="bot-vinculados-h" className="text-lg font-semibold text-gray-800 dark:text-white">
            Usuarios vinculados
          </h2>
          <span className="text-sm text-gray-500 dark:text-gray-400">
            {vinculados.length} total — {usuariosActivos} activos
          </span>
        </div>
        {loadingVinculados ? (
          <LoadingSpinner />
        ) : vinculados.length === 0 ? (
          <div className="text-center py-8 text-gray-500 dark:text-gray-400">
            <Users className="w-10 h-10 mx-auto mb-2 opacity-50" aria-hidden="true" />
            <p>No hay usuarios vinculados.</p>
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full" role="table">
              <thead className="bg-gray-50 dark:bg-gray-700/50">
                <tr>
                  <Th>Nombre</Th>
                  <Th>Email</Th>
                  <Th>Rol</Th>
                  <Th>Sucursal</Th>
                  <Th>Vinculado</Th>
                  <Th>Último uso</Th>
                  <Th>Activo</Th>
                </tr>
              </thead>
              <tbody className="divide-y dark:divide-gray-700">
                {vinculados.map((u) => (
                  <tr
                    key={u.telegram_user_id}
                    className="hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors"
                  >
                    <td className="px-4 py-3 font-medium text-gray-800 dark:text-white">
                      {u.perfil_nombre ?? '(sin nombre)'}
                      {u.telegram_username && (
                        <div className="text-xs text-gray-500 dark:text-gray-400">
                          @{u.telegram_username}
                        </div>
                      )}
                    </td>
                    <td className="px-4 py-3 text-gray-600 dark:text-gray-400">
                      {u.perfil_email ?? '—'}
                    </td>
                    <td className="px-4 py-3 text-gray-600 dark:text-gray-400">{u.rol}</td>
                    <td className="px-4 py-3 text-gray-600 dark:text-gray-400">
                      {u.sucursal_nombre ?? '—'}
                    </td>
                    <td className="px-4 py-3 text-gray-600 dark:text-gray-400 text-sm">
                      {formatFecha(u.vinculado_at)}
                    </td>
                    <td className="px-4 py-3 text-gray-600 dark:text-gray-400 text-sm">
                      {u.ultimo_uso_at ? formatDateTime(u.ultimo_uso_at) : '—'}
                    </td>
                    <td className="px-4 py-3">
                      <button
                        type="button"
                        onClick={() => handleToggleUsuario(u)}
                        disabled={togglingId === u.telegram_user_id}
                        className={`px-3 py-1 rounded-full text-xs font-medium transition-colors disabled:opacity-50 disabled:cursor-not-allowed ${
                          u.activo
                            ? 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-300 hover:bg-green-200 dark:hover:bg-green-900/50'
                            : 'bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-300 hover:bg-red-200 dark:hover:bg-red-900/50'
                        }`}
                        aria-label={u.activo ? `Desactivar ${u.perfil_nombre ?? ''}` : `Reactivar ${u.perfil_nombre ?? ''}`}
                      >
                        {u.activo ? 'Activo' : 'Inactivo'}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* Sección 2: digests recientes */}
      <section
        aria-labelledby="bot-digests-h"
        className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm"
      >
        <div className="px-4 py-3 border-b dark:border-gray-700 flex items-center justify-between">
          <h2 id="bot-digests-h" className="text-lg font-semibold text-gray-800 dark:text-white">
            Digests recientes (último mes)
          </h2>
          <span className="text-sm text-gray-500 dark:text-gray-400">{digests.length} envíos</span>
        </div>
        {loadingDigests ? (
          <LoadingSpinner />
        ) : digests.length === 0 ? (
          <div className="text-center py-8 text-gray-500 dark:text-gray-400">
            <Mail className="w-10 h-10 mx-auto mb-2 opacity-50" aria-hidden="true" />
            <p>Aún no se enviaron digests en el último mes.</p>
          </div>
        ) : (
          <>
            <div className="overflow-x-auto">
              <table className="w-full" role="table">
                <thead className="bg-gray-50 dark:bg-gray-700/50">
                  <tr>
                    <Th>Fecha</Th>
                    <Th>Admin</Th>
                    <Th>Sucursal</Th>
                    <Th>Status</Th>
                    <Th>Detalle / Error</Th>
                  </tr>
                </thead>
                <tbody className="divide-y dark:divide-gray-700">
                  {digestsPaginados.map((d) => (
                    <tr
                      key={`${d.admin_perfil_id}_${d.fecha}_${d.sent_at}`}
                      className="hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors"
                    >
                      <td className="px-4 py-3 text-gray-700 dark:text-gray-200">
                        <div className="font-medium">{formatFecha(d.fecha)}</div>
                        <div className="text-xs text-gray-500 dark:text-gray-400">
                          {formatDateTime(d.sent_at)}
                        </div>
                      </td>
                      <td className="px-4 py-3 text-gray-600 dark:text-gray-400">
                        {d.perfil_nombre ?? '—'}
                      </td>
                      <td className="px-4 py-3 text-gray-600 dark:text-gray-400">
                        {d.sucursal_nombre ?? '—'}
                      </td>
                      <td className="px-4 py-3">
                        <span
                          className={`px-2 py-1 rounded-full text-xs font-medium ${
                            d.status === 'ok'
                              ? 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-300'
                              : d.status === 'error'
                                ? 'bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-300'
                                : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300'
                          }`}
                        >
                          {d.status}
                        </span>
                      </td>
                      <td className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400 max-w-xs truncate">
                        {resumirErrorMeta(d.error_meta)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {digestsTotalPages > 1 && (
              <Paginacion
                page={digestsPage}
                totalPages={digestsTotalPages}
                onChange={onDigestsPageChange}
              />
            )}
          </>
        )}
      </section>

      {/* Sección 3: audit log */}
      <section
        aria-labelledby="bot-audit-h"
        className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm"
      >
        <div className="px-4 py-3 border-b dark:border-gray-700 flex items-center justify-between">
          <h2 id="bot-audit-h" className="text-lg font-semibold text-gray-800 dark:text-white">
            Audit log
          </h2>
          <span className="text-sm text-gray-500 dark:text-gray-400">
            {auditEvents.length} eventos
          </span>
        </div>

        {/* Filtros */}
        <div className="px-4 py-3 border-b dark:border-gray-700 grid grid-cols-2 md:grid-cols-4 gap-2">
          <label className="flex flex-col text-xs text-gray-600 dark:text-gray-400">
            Desde
            <input
              type="date"
              value={filters.desde}
              onChange={handleFilterDesde}
              className="mt-1 px-2 py-1 border border-gray-300 dark:border-gray-600 dark:bg-gray-700 dark:text-white rounded text-sm"
              aria-label="Fecha desde"
            />
          </label>
          <label className="flex flex-col text-xs text-gray-600 dark:text-gray-400">
            Hasta
            <input
              type="date"
              value={filters.hasta}
              onChange={handleFilterHasta}
              className="mt-1 px-2 py-1 border border-gray-300 dark:border-gray-600 dark:bg-gray-700 dark:text-white rounded text-sm"
              aria-label="Fecha hasta"
            />
          </label>
          <label className="flex flex-col text-xs text-gray-600 dark:text-gray-400">
            Tipo
            <select
              value={filters.tipo ?? ''}
              onChange={handleFilterTipo}
              className="mt-1 px-2 py-1 border border-gray-300 dark:border-gray-600 dark:bg-gray-700 dark:text-white rounded text-sm"
              aria-label="Filtrar por tipo"
            >
              {TIPO_OPCIONES.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </label>
          <label className="flex flex-col text-xs text-gray-600 dark:text-gray-400">
            Perfil
            <select
              value={filters.perfil_id ?? ''}
              onChange={handleFilterPerfil}
              className="mt-1 px-2 py-1 border border-gray-300 dark:border-gray-600 dark:bg-gray-700 dark:text-white rounded text-sm"
              aria-label="Filtrar por perfil"
            >
              <option value="">Todos los perfiles</option>
              {vinculados.map((u) => (
                <option key={u.perfil_id} value={u.perfil_id}>
                  {u.perfil_nombre ?? u.perfil_email ?? u.perfil_id}
                </option>
              ))}
            </select>
          </label>
        </div>

        {loadingAudit ? (
          <LoadingSpinner />
        ) : auditEvents.length === 0 ? (
          <div className="text-center py-8 text-gray-500 dark:text-gray-400">
            <MessageSquare className="w-10 h-10 mx-auto mb-2 opacity-50" aria-hidden="true" />
            <p>No hay eventos en el rango seleccionado.</p>
          </div>
        ) : (
          <>
            <div className="overflow-x-auto">
              <table className="w-full" role="table">
                <thead className="bg-gray-50 dark:bg-gray-700/50">
                  <tr>
                    <Th>Fecha</Th>
                    <Th>Perfil</Th>
                    <Th>Rol</Th>
                    <Th>Tipo</Th>
                    <Th>Tool</Th>
                    <Th>Resumen</Th>
                    <Th>Detalle</Th>
                  </tr>
                </thead>
                <tbody className="divide-y dark:divide-gray-700">
                  {auditPaginados.map((ev) => {
                    const badge = TIPO_BADGE[ev.tipo] ?? 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300';
                    return (
                      <tr key={ev.id} className="hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors">
                        <td className="px-4 py-3 text-xs text-gray-600 dark:text-gray-400 whitespace-nowrap">
                          {formatDateTime(ev.created_at)}
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-700 dark:text-gray-200">
                          {ev.perfil_nombre ?? '—'}
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-400">
                          {ev.rol ?? '—'}
                        </td>
                        <td className="px-4 py-3">
                          <span className={`px-2 py-1 rounded-full text-xs font-medium ${badge}`}>
                            {ev.tipo}
                          </span>
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-400">
                          {ev.tool_name ?? '—'}
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-400 max-w-xs truncate">
                          {resumirEvento(ev)}
                        </td>
                        <td className="px-4 py-3 text-right">
                          <button
                            type="button"
                            onClick={() => setEventoDetalle(ev)}
                            className="text-xs text-blue-600 dark:text-blue-400 hover:underline"
                          >
                            ver
                          </button>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            {auditTotalPages > 1 && (
              <Paginacion
                page={auditPage}
                totalPages={auditTotalPages}
                onChange={onAuditPageChange}
              />
            )}
          </>
        )}
      </section>

      {/* Modal detalle de evento */}
      {eventoDetalle && (
        <DetalleEventoModal
          evento={eventoDetalle}
          onClose={() => setEventoDetalle(null)}
        />
      )}
    </div>
  );
}

// =============================================================================
// SUBCOMPONENTS
// =============================================================================

function Th({ children }: { children: ReactNode }): ReactElement {
  return (
    <th
      scope="col"
      className="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider"
    >
      {children}
    </th>
  );
}

interface StatsCardProps {
  label: string;
  value: number;
  loading: boolean;
  icon: ComponentType<{ className?: string; 'aria-hidden'?: boolean }>;
  tone: 'blue' | 'green' | 'red' | 'purple' | 'gray';
}

function StatsCard({ label, value, loading, icon: Icon, tone }: StatsCardProps): ReactElement {
  const toneClasses: Record<StatsCardProps['tone'], string> = {
    blue: 'bg-blue-100 dark:bg-blue-900/30 text-blue-600 dark:text-blue-400',
    green: 'bg-green-100 dark:bg-green-900/30 text-green-600 dark:text-green-400',
    red: 'bg-red-100 dark:bg-red-900/30 text-red-600 dark:text-red-400',
    purple: 'bg-purple-100 dark:bg-purple-900/30 text-purple-600 dark:text-purple-400',
    gray: 'bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-400',
  };
  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm p-4 flex items-center gap-3">
      <div className={`p-2 rounded-lg ${toneClasses[tone]}`}>
        <Icon className="w-5 h-5" aria-hidden />
      </div>
      <div>
        <p className="text-xs text-gray-500 dark:text-gray-400 uppercase tracking-wider">
          {label}
        </p>
        <p className="text-2xl font-bold text-gray-800 dark:text-white">
          {loading ? '…' : value}
        </p>
      </div>
    </div>
  );
}

interface PaginacionProps {
  page: number;
  totalPages: number;
  onChange: (next: number) => void;
}

function Paginacion({ page, totalPages, onChange }: PaginacionProps): ReactElement {
  return (
    <div className="px-4 py-3 border-t dark:border-gray-700 flex items-center justify-between">
      <span className="text-sm text-gray-600 dark:text-gray-400">
        Página {page + 1} de {totalPages}
      </span>
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={() => onChange(Math.max(0, page - 1))}
          disabled={page === 0}
          className="p-1 rounded border border-gray-300 dark:border-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-30 disabled:cursor-not-allowed"
          aria-label="Página anterior"
        >
          <ChevronLeft className="w-4 h-4" aria-hidden="true" />
        </button>
        <button
          type="button"
          onClick={() => onChange(Math.min(totalPages - 1, page + 1))}
          disabled={page >= totalPages - 1}
          className="p-1 rounded border border-gray-300 dark:border-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-30 disabled:cursor-not-allowed"
          aria-label="Página siguiente"
        >
          <ChevronRight className="w-4 h-4" aria-hidden="true" />
        </button>
      </div>
    </div>
  );
}

interface DetalleEventoModalProps {
  evento: BotAuditEvent;
  onClose: () => void;
}

function DetalleEventoModal({ evento, onClose }: DetalleEventoModalProps): ReactElement {
  const json = JSON.stringify(
    {
      id: evento.id,
      created_at: evento.created_at,
      tipo: evento.tipo,
      tool_name: evento.tool_name,
      perfil_id: evento.perfil_id,
      perfil_nombre: evento.perfil_nombre,
      rol: evento.rol,
      telegram_user_id: evento.telegram_user_id,
      texto_usuario: evento.texto_usuario,
      texto_bot: evento.texto_bot,
      parametros: evento.parametros,
      resultado_meta: evento.resultado_meta,
    },
    null,
    2,
  );

  return (
    <div
      className="fixed inset-0 bg-black/50 z-50 flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="evento-detalle-h"
      onClick={onClose}
    >
      <div
        className="bg-white dark:bg-gray-800 rounded-lg shadow-xl max-w-3xl w-full max-h-[80vh] overflow-hidden flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="px-4 py-3 border-b dark:border-gray-700 flex items-center justify-between">
          <h3 id="evento-detalle-h" className="font-semibold text-gray-800 dark:text-white">
            Evento #{evento.id} — {evento.tipo}
          </h3>
          <button
            type="button"
            onClick={onClose}
            className="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-700"
            aria-label="Cerrar detalle"
          >
            <X className="w-4 h-4" aria-hidden="true" />
          </button>
        </div>
        <pre className="overflow-auto p-4 text-xs text-gray-700 dark:text-gray-200 bg-gray-50 dark:bg-gray-900 flex-1">
          {json}
        </pre>
      </div>
    </div>
  );
}

// =============================================================================
// HELPERS
// =============================================================================

function resumirEvento(ev: BotAuditEvent): string {
  if (ev.texto_usuario) return ev.texto_usuario;
  if (ev.tool_name) return `tool: ${ev.tool_name}`;
  if (ev.texto_bot) return ev.texto_bot;
  return '—';
}

function resumirErrorMeta(meta: unknown): string {
  if (!meta) return '—';
  if (typeof meta === 'string') return meta;
  try {
    const stringified = JSON.stringify(meta);
    return stringified.length > 80 ? `${stringified.slice(0, 80)}…` : stringified;
  } catch {
    return '—';
  }
}
