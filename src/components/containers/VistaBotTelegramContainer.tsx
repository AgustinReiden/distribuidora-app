/**
 * VistaBotTelegramContainer
 *
 * Container para la vista admin del bot Telegram (Phase 4 task 4.2).
 * Mantiene el estado de filtros del audit log + páginas locales y orquesta
 * los 5 query hooks + 2 mutations. La vista es presentational.
 */
import { Suspense, useCallback, useMemo, useState, type ReactElement } from 'react';
import { Loader2 } from 'lucide-react';
import { useQueryClient } from '@tanstack/react-query';
import {
  botAdminKeys,
  useBotAuditLogQuery,
  useBotAuditSummaryQuery,
  useBotDigestsEnviadosQuery,
  useBotDigestConfigQuery,
  useBotVinculadosQuery,
  useGuardarBotDigestConfigMutation,
  useToggleBotUsuarioMutation,
} from '../../hooks/queries';
import { useNotification } from '../../contexts/NotificationContext';
import type {
  BotAuditFilters,
  BotToggleUsuarioInput,
  BotToggleUsuarioResult,
} from '../../hooks/queries/useBotAdmin';
import type { GuardarConfigDigestInput } from '../../hooks/queries/useBotDigestConfig';
import { botDigestConfigKeys } from '../../hooks/queries';
import { lazyWithReload } from '../../utils/lazyWithReload';

const VistaBotTelegram = lazyWithReload(() => import('../vistas/VistaBotTelegram'));

function LoadingState(): ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  );
}

/**
 * Construye el rango por defecto: del primer día del mes corriente hasta hoy.
 * Mantiene visibles los digests del último mes y un audit log con buen
 * tamaño sin exceder el límite default de 200 filas.
 */
function rangoDefault(): { desde: string; hasta: string } {
  const hoy = new Date();
  const primero = new Date(hoy.getFullYear(), hoy.getMonth(), 1);
  return {
    desde: toIsoDate(primero),
    hasta: toIsoDate(hoy),
  };
}

function toIsoDate(d: Date): string {
  // YYYY-MM-DD en hora local (no UTC). Coincide con el formato esperado por
  // los inputs <input type="date">.
  const year = d.getFullYear();
  const month = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

export default function VistaBotTelegramContainer(): ReactElement {
  const notify = useNotification();
  const queryClient = useQueryClient();

  // Filtros
  const [filters, setFilters] = useState<BotAuditFilters>(() => {
    const r = rangoDefault();
    return { desde: r.desde, hasta: r.hasta };
  });
  const [auditPage, setAuditPage] = useState(0);
  const [digestsPage, setDigestsPage] = useState(0);

  // Queries
  const vinculadosQuery = useBotVinculadosQuery();
  const auditLogQuery = useBotAuditLogQuery(filters);
  const summaryQuery = useBotAuditSummaryQuery(filters.desde, filters.hasta);
  const digestsQuery = useBotDigestsEnviadosQuery(filters.desde, filters.hasta);
  const configDigestQuery = useBotDigestConfigQuery();

  // Mutations
  const toggleMutation = useToggleBotUsuarioMutation();
  const guardarConfigMutation = useGuardarBotDigestConfigMutation();

  // ============================================================================
  // Handlers
  // ============================================================================
  const handleToggle = useCallback(
    async (input: BotToggleUsuarioInput): Promise<BotToggleUsuarioResult> => {
      try {
        const res = await toggleMutation.mutateAsync(input);
        notify.success(input.activo ? 'Usuario reactivado' : 'Usuario desactivado');
        return res;
      } catch (err) {
        notify.error((err as Error).message || 'No se pudo cambiar el estado del usuario');
        throw err;
      }
    },
    [toggleMutation, notify],
  );

  const handleGuardarConfigDigest = useCallback(
    async (input: GuardarConfigDigestInput): Promise<void> => {
      try {
        await guardarConfigMutation.mutateAsync(input);
        notify.success('Configuración guardada');
      } catch (err) {
        // Se relanza: el modal lo muestra al lado del botón y NO se cierra, así
        // no se pierde lo que el admin acababa de tildar.
        notify.error((err as Error).message || 'No se pudo guardar la configuración');
        throw err;
      }
    },
    [guardarConfigMutation, notify],
  );

  const handleRefresh = useCallback(() => {
    queryClient.invalidateQueries({ queryKey: botAdminKeys.all });
    queryClient.invalidateQueries({ queryKey: botDigestConfigKeys.all });
  }, [queryClient]);

  const handleFiltersChange = useCallback((next: BotAuditFilters) => {
    setFilters(next);
  }, []);

  // Memo defensivo: evita renders innecesarios si el array cambia de identidad
  // pero no de contenido entre invalidations.
  const vinculados = useMemo(() => vinculadosQuery.data ?? [], [vinculadosQuery.data]);
  const audit = useMemo(() => auditLogQuery.data ?? [], [auditLogQuery.data]);
  const digests = useMemo(() => digestsQuery.data ?? [], [digestsQuery.data]);
  const configDigest = useMemo(
    () => configDigestQuery.data ?? [],
    [configDigestQuery.data],
  );

  return (
    <Suspense fallback={<LoadingState />}>
      <VistaBotTelegram
        vinculados={vinculados}
        configDigest={configDigest}
        digests={digests}
        auditEvents={audit}
        auditSummary={summaryQuery.data ?? null}
        filters={filters}
        onFiltersChange={handleFiltersChange}
        auditPage={auditPage}
        onAuditPageChange={setAuditPage}
        digestsPage={digestsPage}
        onDigestsPageChange={setDigestsPage}
        loadingVinculados={vinculadosQuery.isLoading}
        loadingConfigDigest={configDigestQuery.isLoading}
        loadingDigests={digestsQuery.isLoading}
        loadingAudit={auditLogQuery.isLoading}
        loadingSummary={summaryQuery.isLoading}
        onRefresh={handleRefresh}
        onToggleUsuario={handleToggle}
        onGuardarConfigDigest={handleGuardarConfigDigest}
      />
    </Suspense>
  );
}
