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
 *
 * Con `filtros` + `onFiltrosChange` cada tile es un botón que filtra la lista
 * (#715, WP-24): toggle con `aria-pressed`, tocar el activo lo deselecciona, y
 * "Total filtrado" limpia estado y pago. Qué filtra cada uno vive en
 * `utils/kpiFiltroPedidos`. Sin esas dos props los tiles siguen siendo sólo
 * lectura (la galería y cualquier otro consumidor no cambian).
 *
 * El contenido del tile va en `<span>` y no en `<div>`/`<p>`: dentro de un
 * `<button>` sólo vale contenido de frase.
 */
import React, { memo } from 'react';
import { Clock, Package, Truck, Check, DollarSign, ShoppingCart, Filter, LucideIcon } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import type { PedidoStatsSummary } from '../../hooks/queries';
import type { FiltrosPedidosState } from '../../types';
import { mostrarMontosEnStats, type PedidoStatKey } from '../../lib/permisos';
import { hayFiltroQueLimpiar, kpiEstaActivo, togglearKpi, type FiltrosKpi } from '../../utils/kpiFiltroPedidos';

// =============================================================================
// PROPS INTERFACES
// =============================================================================

export interface PedidoStatsProps {
  summary: PedidoStatsSummary;
  isEncargado?: boolean;
  /**
   * Filtros actuales de la lista: marcan qué tile está activo. Hace falta junto
   * con `onFiltrosChange` para que los tiles sean botones.
   */
  filtros?: FiltrosKpi;
  /** Recibe el cambio de filtros que aplica (o quita) el tile tocado. */
  onFiltrosChange?: (cambios: Partial<FiltrosPedidosState>) => void;
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
  /**
   * Anillo del tile activo cuando filtra la lista. `ring-2` sin offset se pinta
   * AFUERA del borde del tile, sobre el fondo de la página, no sobre el blanco
   * del tile: en claro eso es `bg-gray-100` de App (stone-100, #f5f5f4), y ahí
   * se midió el 3:1 (WCAG 1.4.11). Ámbar, naranja y verde van en -700 (4,60,
   * 4,75 y 4,60): el -600 queda en 2,92, 3,26 y 3,02, y contra el borde
   * stone-200 ni eso. Rojo alcanza con -600 (4,43). En oscuro, -500 contra
   * stone-900 (4,65 a 8,14). "Total" no lo lleva: es el botón de limpiar y
   * nunca queda activo.
   */
  ringActivo?: string;
}

// =============================================================================
// COMPONENT
// =============================================================================

function PedidoStats({ summary, isEncargado, filtros, onFiltrosChange }: PedidoStatsProps): React.ReactElement {
  // El rol determina qué montos se muestran: el encargado solo ve los impagos.
  const rol = isEncargado ? 'encargado' : 'admin';
  // Un tile que no sabe si está activo no puede ser un toggle: hacen falta las dos.
  const interactivo = filtros !== undefined && onFiltrosChange !== undefined;
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
      ringActivo: 'ring-amber-700 dark:ring-amber-500',
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
      ringActivo: 'ring-orange-700 dark:ring-orange-500',
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
      // No el -500/-600: el anillo de foco es brand-500, que es ese mismo azul,
      // y "presionado" no se distinguiría de "con el foco".
      ringActivo: 'ring-blue-700 dark:ring-blue-300',
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
      ringActivo: 'ring-emerald-700 dark:ring-emerald-500',
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
      ringActivo: 'ring-rose-600 dark:ring-rose-500',
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
    <div className="flex flex-col gap-2">
      {summary.aproximado && (
        <p className="text-xs text-amber-700 dark:text-amber-300" role="status">
          Totales aproximados: hay más pedidos filtrados de los que se pudieron sumar.
        </p>
      )}
      <div
        className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3"
        role={interactivo ? 'group' : undefined}
        aria-label={interactivo ? 'Filtrar pedidos por estado o pago' : undefined}
      >
      {items.map((item, idx) => {
        const IconComponent = item.icon;
        const showMonto = mostrarMontosEnStats(rol, item.key);
        const claseTile = `group relative overflow-hidden bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 border-l-4 ${item.accentBorder} rounded-xl px-3.5 py-3 shadow-warm hover:shadow-warm-md hover:-translate-y-px transition-[transform,box-shadow] duration-200 before:absolute before:inset-0 before:bg-gradient-to-br ${item.gradientFrom} before:to-transparent before:pointer-events-none`;
        const estilo = { animation: 'card-in 0.35s cubic-bezier(0.22, 1, 0.36, 1) both', animationDelay: `${idx * 35}ms` };
        const activo = interactivo && kpiEstaActivo(item.key, filtros);
        const contenido = (
          <span className="relative flex items-start gap-2.5">
            <span className="relative flex flex-shrink-0">
              <span className={`inline-flex items-center justify-center w-7 h-7 rounded-lg ${item.badgeBg}`}>
                <IconComponent className={`w-3.5 h-3.5 ${item.badgeIcon}`} aria-hidden="true" />
              </span>
              {/* Marca visible del tile activo además del anillo: el modo alto
                  contraste apaga todo box-shadow (y con él el ring), el icono no.
                  Va DEBAJO del badge, en la columna que no tiene texto: en la
                  esquina de arriba compartía renglón con la etiqueta y, con el
                  tile angosto (~148px en lg a 1024), la pisaba. Absoluto para que
                  prenderlo no cambie el alto del tile. Afuera del badge y no
                  adentro: el badge tiene fondo propio, y en alto contraste con
                  el botón en hover el ícono heredaría su negro sobre el negro
                  del botón (ver high-contrast.css). */}
              {activo && (
                <Filter className="absolute top-full left-1/2 -translate-x-1/2 mt-1.5 w-3.5 h-3.5 text-stone-500 dark:text-stone-400" aria-hidden="true" />
              )}
            </span>
            <span className="block min-w-0">
              <span className="block text-[10.5px] font-semibold uppercase tracking-[0.08em] text-stone-500 dark:text-stone-400 leading-tight">
                {item.label}
              </span>
              <span
                className={`block text-2xl tabular-nums leading-tight mt-0.5 ${item.accentText}`}
                style={{ fontWeight: 800, letterSpacing: '-0.025em' }}
              >
                {item.count.toLocaleString('es-AR')}
              </span>
              {showMonto && (
                <span className="block text-xs tabular-nums text-stone-500 dark:text-stone-400 mt-0.5 truncate">
                  {formatPrecio(item.total)}
                </span>
              )}
            </span>
          </span>
        );

        if (!interactivo) {
          return (
            <div key={item.key} className={claseTile} style={estilo}>
              {contenido}
            </div>
          );
        }

        const esLimpiar = item.key === 'total';
        return (
          <button
            key={item.key}
            type="button"
            // "Total" no es un toggle: es el botón de limpiar, nunca queda
            // apretado. Anunciarlo como "no presionado" sería mentir.
            aria-pressed={esLimpiar ? undefined : activo}
            onClick={() => {
              // Sin estado ni pago elegidos "Total" no tiene nada que limpiar:
              // no dispara un cambio que sólo resetearía la página.
              if (esLimpiar && !hayFiltroQueLimpiar(filtros)) return;
              onFiltrosChange(togglearKpi(item.key, filtros));
            }}
            // `flex flex-col`: un <button> centra su contenido en vertical y la
            // grilla estira cada tile al alto de su fila, así que un tile sin
            // monto al lado de uno con monto quedaba con el texto corrido para
            // abajo. En columna flex el contenido vuelve arriba, como en el <div>.
            // `dark:focus-visible:ring-brand-500` repite el color del foco para
            // el modo oscuro: `dark:ring-*` del tile presionado tiene la misma
            // especificidad que `focus-visible:ring-brand-500` y Tailwind la
            // emite después, así que un tile presionado Y con foco mostraba su
            // anillo de estado en vez del de foco. La variante apilada suma
            // especificidad y le gana en los dos temas.
            className={`${claseTile} flex flex-col w-full text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 dark:focus-visible:ring-brand-500 focus-visible:ring-offset-2 dark:focus-visible:ring-offset-gray-900 ${activo ? `ring-2 ${item.ringActivo ?? ''}` : ''}`}
            style={estilo}
          >
            {contenido}
            {/* Lo que hace "Total" no se ve en el tile (no tiene estado
                presionado): se lo dice al lector de pantalla. */}
            {esLimpiar && <span className="sr-only">, quita los filtros de estado y pago</span>}
          </button>
        );
      })}
      </div>
    </div>
  );
}

export default memo(PedidoStats);
