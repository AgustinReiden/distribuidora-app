/**
 * Componente de estadísticas/resumen de clientes
 *
 * Cálculos in-memory sobre el array completo de clientes (no paginado), que
 * ya está cargado en RAM. Diseño editorial cálido — gemelo a PedidoStats.
 *
 * Gating:
 *  - Si el rol no puede ver saldos (preventista_taco), se ocultan las tarjetas
 *    "Con deuda", "Al día" y "Saldo adeudado".
 */
import React, { memo, useMemo } from 'react';
import { Users, AlertTriangle, Check, DollarSign, MapPin, Tag, type LucideIcon } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import { puedeVerSaldoCliente } from '../../lib/permisos';
import { useAuthData } from '../../contexts/AuthDataContext';
import type { ClienteDB } from '../../types';

export interface ClienteStatsProps {
  clientes: ClienteDB[];
}

interface StatItem {
  key: string;
  label: string;
  icon: LucideIcon;
  count: number;
  detail?: string;
  accentBorder: string;
  accentText: string;
  badgeBg: string;
  badgeIcon: string;
  gradientFrom: string;
  /** Si true y el rol no ve saldos, se oculta la card. */
  requiereSaldo?: boolean;
}

function ClienteStats({ clientes }: ClienteStatsProps): React.ReactElement {
  const { perfil } = useAuthData();
  const verSaldo = puedeVerSaldoCliente(perfil?.rol);

  const summary = useMemo(() => {
    let conDeuda = 0;
    let alDia = 0;
    let saldoTotal = 0;
    let geo = 0;
    const rubrosSet = new Set<string>();

    for (const c of clientes) {
      const saldo = c.saldo_cuenta ?? 0;
      if (saldo > 0) {
        conDeuda += 1;
        saldoTotal += saldo;
      } else {
        alDia += 1;
      }
      if (c.latitud != null && c.longitud != null) geo += 1;
      if (c.rubro) rubrosSet.add(c.rubro);
    }

    return {
      total: clientes.length,
      conDeuda,
      alDia,
      saldoTotal,
      geo,
      rubros: rubrosSet.size,
    };
  }, [clientes]);

  const items: StatItem[] = [
    {
      key: 'total',
      label: 'Total clientes',
      icon: Users,
      count: summary.total,
      accentBorder: 'border-l-stone-400 dark:border-l-stone-500',
      accentText: 'text-stone-800 dark:text-stone-200',
      badgeBg: 'bg-stone-100 dark:bg-stone-500/15',
      badgeIcon: 'text-stone-600 dark:text-stone-300',
      gradientFrom: 'before:from-stone-500/[0.06]',
    },
    {
      key: 'conDeuda',
      label: 'Con deuda',
      icon: AlertTriangle,
      count: summary.conDeuda,
      accentBorder: 'border-l-rose-500',
      accentText: 'text-rose-700 dark:text-rose-300',
      badgeBg: 'bg-rose-100 dark:bg-rose-500/15',
      badgeIcon: 'text-rose-600 dark:text-rose-400',
      gradientFrom: 'before:from-rose-500/[0.07]',
      requiereSaldo: true,
    },
    {
      key: 'alDia',
      label: 'Al día',
      icon: Check,
      count: summary.alDia,
      accentBorder: 'border-l-emerald-500',
      accentText: 'text-emerald-700 dark:text-emerald-300',
      badgeBg: 'bg-emerald-100 dark:bg-emerald-500/15',
      badgeIcon: 'text-emerald-600 dark:text-emerald-400',
      gradientFrom: 'before:from-emerald-500/[0.07]',
      requiereSaldo: true,
    },
    {
      key: 'saldoAdeudado',
      label: 'Saldo adeudado',
      icon: DollarSign,
      count: summary.conDeuda,
      detail: formatPrecio(summary.saldoTotal),
      accentBorder: 'border-l-amber-500',
      accentText: 'text-amber-700 dark:text-amber-300',
      badgeBg: 'bg-amber-100 dark:bg-amber-500/15',
      badgeIcon: 'text-amber-600 dark:text-amber-400',
      gradientFrom: 'before:from-amber-500/[0.07]',
      requiereSaldo: true,
    },
    {
      key: 'geo',
      label: 'Geolocalizados',
      icon: MapPin,
      count: summary.geo,
      accentBorder: 'border-l-blue-500',
      accentText: 'text-blue-700 dark:text-blue-300',
      badgeBg: 'bg-blue-100 dark:bg-blue-500/15',
      badgeIcon: 'text-blue-600 dark:text-blue-400',
      gradientFrom: 'before:from-blue-500/[0.07]',
    },
    {
      key: 'rubros',
      label: 'Rubros',
      icon: Tag,
      count: summary.rubros,
      accentBorder: 'border-l-orange-500',
      accentText: 'text-orange-700 dark:text-orange-300',
      badgeBg: 'bg-orange-100 dark:bg-orange-500/15',
      badgeIcon: 'text-orange-600 dark:text-orange-400',
      gradientFrom: 'before:from-orange-500/[0.07]',
    },
  ];

  const visibleItems = items.filter(i => verSaldo || !i.requiereSaldo);

  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
      {visibleItems.map((item, idx) => {
        const IconComponent = item.icon;
        // Para la card "Saldo adeudado" mostramos el monto como número grande
        // (con peso 800) y el count de clientes como detail.
        const showMontoAsMain = item.key === 'saldoAdeudado';
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
                {showMontoAsMain ? (
                  <>
                    <p
                      className={`text-xl tabular-nums leading-tight mt-0.5 ${item.accentText}`}
                      style={{ fontWeight: 800, letterSpacing: '-0.025em' }}
                    >
                      {item.detail}
                    </p>
                    <p className="text-xs tabular-nums text-stone-500 dark:text-stone-400 mt-0.5 truncate">
                      {item.count} {item.count === 1 ? 'cliente' : 'clientes'}
                    </p>
                  </>
                ) : (
                  <p
                    className={`text-2xl tabular-nums leading-tight mt-0.5 ${item.accentText}`}
                    style={{ fontWeight: 800, letterSpacing: '-0.025em' }}
                  >
                    {item.count.toLocaleString('es-AR')}
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

export default memo(ClienteStats);
