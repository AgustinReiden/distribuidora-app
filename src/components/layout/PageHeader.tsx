/**
 * Encabezado de vista, único.
 *
 * Estructura visual (editorial cálido):
 *
 *   OPERACIONES  ·  MARTES 21 DE ABRIL  ·  649 RESULTADOS
 *
 *   Pedidos del día                         [acciones]
 *   ───
 *
 * Es el primitivo que reemplaza a los cuatro headers de vista copiados
 * (PedidosViewHeader, ClientesViewHeader, ProductosViewHeader,
 * DashboardViewHeader). Acá NO se migra ninguno: eso es WP-19.
 *
 * Contrato que los tests de caracterización de esos cuatro fijan y que este
 * componente respeta:
 *  - el nombre accesible del `<h1>` es "titulo periodo" (el período va en un
 *    `<em>` hermano, separado por un espacio de texto real);
 *  - con `loading`, el ÚLTIMO crumb —y sólo ése— se reemplaza por
 *    "ACTUALIZANDO…" y late con `animate-pulse`;
 *  - sin período no hay `<em>`.
 *
 * El `key={periodo}` del `<em>` es deliberado: fuerza el re-mount cuando el
 * período cambia, que es lo que dispara `animate-[fadeSlideIn_300ms_ease-out]`.
 * Sin él la animación corre una sola vez, al montar.
 */
import React from 'react';
import { cn } from '../../lib/utils';
import CrumbDot from '../ui/CrumbDot';

export interface PageHeaderProps {
  /** Verbo del título, en el `<h1>`. Ej: "Pedidos", "Clientes", "Resumen". */
  titulo: string;
  /** Sufijo en cursiva liviana. Ej: "del día", "con deuda". Opcional. */
  periodo?: string | null;
  /** Items del crumb, en orden. El último es el que tapa `loading`. */
  crumbs: React.ReactNode[];
  /** Slot derecha (típicamente una toolbar). */
  acciones?: React.ReactNode;
  /** Mientras carga, el último crumb dice "ACTUALIZANDO…". */
  loading?: boolean;
  /** Clases extra para el `<header>`. */
  className?: string;
}

const CRUMB_CARGANDO = 'ACTUALIZANDO…';

export default function PageHeader({
  titulo,
  periodo,
  crumbs,
  acciones,
  loading = false,
  className,
}: PageHeaderProps): React.ReactElement {
  // Con `loading`, el último crumb (el conteo / el período) no se sabe todavía.
  // Los de antes —sección y fecha— no dependen de la consulta y se quedan.
  const items: React.ReactNode[] = loading
    ? [...crumbs.slice(0, -1), CRUMB_CARGANDO]
    : crumbs;
  const ultimo = items.length - 1;

  return (
    <header
      className={cn(
        'flex flex-col sm:flex-row sm:items-end sm:justify-between gap-4 pb-1',
        className,
      )}
    >
      <div className="min-w-0 flex-1">
        {/* Crumb editorial: eyebrow monoespaciada, en mayúsculas, con
            separadores decorativos entre item e item. */}
        <p className="text-[10.5px] sm:text-xs font-mono font-semibold tracking-[0.18em] text-stone-500 dark:text-stone-400 uppercase flex items-center flex-wrap">
          {items.map((item, i) => (
            <React.Fragment key={i}>
              {i > 0 && <CrumbDot />}
              <span className={loading && i === ultimo ? 'animate-pulse' : undefined}>
                {item}
              </span>
            </React.Fragment>
          ))}
        </p>

        {/* Título editorial con período en cursiva. El espacio entre el verbo y
            el `<em>` es un nodo de texto real: es lo que hace que el nombre
            accesible del h1 sea "titulo periodo" y no "tituloperiodo". */}
        <h1
          className="mt-2 font-display text-[32px] font-semibold text-stone-900 dark:text-white leading-[1.05]"
          style={{ letterSpacing: '-0.035em' }}
        >
          <span className="bg-clip-text text-transparent bg-gradient-to-br from-stone-900 to-stone-700 dark:from-white dark:to-stone-300">
            {titulo}
          </span>
          {periodo && (
            <>
              {' '}
              <em
                key={periodo}
                className="font-light italic text-stone-500 dark:text-stone-400 inline-block animate-[fadeSlideIn_300ms_ease-out]"
                style={{ letterSpacing: '-0.02em' }}
              >
                {periodo}
              </em>
            </>
          )}
        </h1>

        {/* Acento decorativo: subrayado editorial de 2px que se desvanece. */}
        <div
          className="mt-3 h-[2px] w-12 rounded-full bg-gradient-to-r from-blue-600 via-blue-500 to-transparent dark:from-blue-400 dark:via-blue-500"
          aria-hidden="true"
        />
      </div>

      {acciones && (
        <div className="flex-shrink-0 sm:max-w-[62%]">
          {acciones}
        </div>
      )}
    </header>
  );
}
