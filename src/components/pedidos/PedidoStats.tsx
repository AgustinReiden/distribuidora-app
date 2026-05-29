/**
 * Componente de estadisticas/resumen de pedidos
 *
 * Recibe los totales ya calculados sobre todos los pedidos filtrados (no sólo
 * la página visible) para que las cards reflejen el estado completo.
 *
 * Diseño editorial cálido:
 *  - Fondo blanco con leve gradient hacia el color semántico (8% opacity).
 *  - Borde sutil stone-200 + franja izquierda con el color del estado.
 *  - Icono dentro de un badge circular (bg-color-100) con el icono color-600.
 *  - Hover: leve lift y sombra cálida más profunda.
 *  - Número grande con tabular-nums y peso 800 para que se sienta "editorial"
 *    en vez de "dato sin alma".
 */
import React, { memo } from 'react';
import { Clock, Package, Truck, Check, DollarSign, ShoppingCart, LucideIcon } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import type { PedidoStatsSummary } from '../../hooks/queries';
import { mostrarMontosEnStats, type PedidoStatKey } from '../../lib/permisos';

// =============================================================================
// PROPS INTERFACES
// =============================================================================

export interface PedidoStatsProps {
  summary: PedidoStatsSummary;
  isEncargado?: boolean;
  isPreventistaTaco?: boolean;
}

interface StatItem {
  key: PedidoStatKey;
  label: string;
  icon: LucideIcon;
  count: number;
  total: number;
  /** Franja izquierda */
  accentBorder: string;
  /** Color del número grande */
  accentText: string;
  /** Fondo del badge del icono */
  badgeBg: string;
  /** Color del icono dentro del badge */
  badgeIcon: string;
  /** Gradient overlay sutil (linear-gradient con el color hacia bg) */
  gradientFrom: string;
}

// =============================================================================
// COMPONENT
// =============================================================================

function PedidoStats({ summary, isEncargado, isPreventistaTaco }: PedidoStatsProps): React.ReactElement {
  // El rol determina qué montos se muestran. preventista_taco no ve ningún monto. (P1-5)
  const rol = isPreventistaTaco ? 'preventista_taco' : isEncargado ? 'encargado' : 'admin';
  const items: StatItem[] = [
    {
      key: 'pendientes',
      label: 'Pendientes',
      icon: Clock,
      count: summary.pendientes.count,
      total: summary.pendientes.monto,
      accentBorder: 'border-l-amber-500',
      accentText: 'text-amber-700 dark:text-amber-300',
      badgeBg: 'bg-amber-100 dark:bg-amber-500/15',
      badgeIcon: 'text-amber-600 dark:text-amber-400',
      gradientFrom: 'before:from-amber-500/[0.07]',
    },
    {
      key: 'enPreparacion',
      label: 'En preparación',
      icon: Package,
      count: summary.enPreparacion.count,
      total: summary.enPreparacion.monto,
      accentBorder: 'border-l-orange-500',
      accentText: 'text-orange-700 dark:text-orange-300',
      badgeBg: 'bg-orange-100 dark:bg-orange-500/15',
      badgeIcon: 'text-orange-600 dark:text-orange-400',
      gradientFrom: 'before:from-orange-500/[0.07]',
    },
    {
      key: 'enCamino',
      label: 'En camino',
      icon: Truck,
      count: summary.enCamino.count,
      total: summary.enCamino.monto,
      accentBorder: 'border-l-blue-500',
      accentText: 'text-blue-700 dark:text-blue-300',
      badgeBg: 'bg-blue-100 dark:bg-blue-500/15',
      badgeIcon: 'text-blue-600 dark:text-blue-400',
      gradientFrom: 'before:from-blue-500/[0.07]',
    },
    {
      key: 'entregados',
      label: 'Entregados',
      icon: Check,
      count: summary.entregados.count,
      total: summary.entregados.monto,
      accentBorder: 'border-l-emerald-500',
      accentText: 'text-emerald-700 dark:text-emerald-300',
      badgeBg: 'bg-emerald-100 dark:bg-emerald-500/15',
      badgeIcon: 'text-emerald-600 dark:text-emerald-400',
      gradientFrom: 'before:from-emerald-500/[0.07]',
    },
    {
      key: 'impagos',
      label: 'Impagos',
      icon: DollarSign,
      count: summary.impagos.count,
      total: summary.impagos.monto,
      accentBorder: 'border-l-rose-500',
      accentText: 'text-rose-700 dark:text-rose-300',
      badgeBg: 'bg-rose-100 dark:bg-rose-500/15',
      badgeIcon: 'text-rose-600 dark:text-rose-400',
      gradientFrom: 'before:from-rose-500/[0.07]',
    },
    {
      key: 'total',
      label: 'Total filtrado',
      icon: ShoppingCart,
      count: summary.total.count,
      total: summary.total.monto,
      accentBorder: 'border-l-stone-400 dark:border-l-stone-500',
      accentText: 'text-stone-800 dark:text-stone-200',
      badgeBg: 'bg-stone-100 dark:bg-stone-500/15',
      badgeIcon: 'text-stone-600 dark:text-stone-300',
      gradientFrom: 'before:from-stone-500/[0.06]',
    },
  ];

  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
      {items.map((item, idx) => {
        const IconComponent = item.icon;
        const showMonto = mostrarMontosEnStats(rol, item.key);
        return (
          <div
            key={item.key}
            className={`group relative overflow-hidden bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 border-l-4 ${item.accentBorder} rounded-xl px-3.5 py-3 shadow-warm hover:shadow-warm-md hover:-translate-y-px transition-[transform,box-shadow] duration-200 before:absolute before:inset-0 before:bg-gradient-to-br ${item.gradientFrom} before:to-transparent before:pointer-events-none`}
            style={{ animation: 'card-in 0.35s cubic-bezier(0.22, 1, 0.36, 1) both', animationDelay: `${idx * 35}ms` }}
          >
            <div className="relative flex items-start gap-2.5">
              <span className={`inline-flex items-center justify-center w-7 h-7 rounded-lg flex-shrink-0 ${item.badgeBg}`}>
                <IconComponent className={`w-3.5 h-3.5 ${item.badgeIcon}`} aria-hidden="true" />
              </span>
              <div className="min-w-0">
                <p className="text-[10.5px] font-semibold uppercase tracking-[0.08em] text-stone-500 dark:text-stone-400 leading-tight">
                  {item.label}
                </p>
                <p
                  className={`text-2xl tabular-nums leading-tight mt-0.5 ${item.accentText}`}
                  style={{ fontWeight: 800, letterSpacing: '-0.025em' }}
                >
                  {item.count.toLocaleString('es-AR')}
                </p>
                {showMonto && (
                  <p className="text-xs tabular-nums text-stone-500 dark:text-stone-400 mt-0.5 truncate">
                    {formatPrecio(item.total)}
                  </p>
                )}
              </div>
            </div>
          </div>
        );
      })}
    </div>
  );
}

export default memo(PedidoStats);
