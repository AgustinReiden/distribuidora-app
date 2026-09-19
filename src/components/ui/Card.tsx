/**
 * La tarjeta, única.
 *
 * En el árbol hay 92 combinaciones de "tarjeta" repartidas en 58 archivos, casi
 * todas la misma superficie escrita a mano con una variante de borde o de
 * padding. Este primitivo es esa superficie una sola vez, con tres formas:
 *
 *  - `section`: el panel grande (un bloque de la vista).
 *  - `stat`: el KPI compacto, con un acento de color opcional a la izquierda.
 *  - `row`: la fila de una lista, que puede reaccionar al hover.
 *
 * Acá NO se migra ningún consumidor: eso viene después.
 *
 * El `padding` por defecto lo decide la variante; pasar `padding` explícito lo
 * pisa, y `className` del consumidor pisa a los dos, porque `cn()` resuelve los
 * conflictos de Tailwind por orden.
 */
import React from 'react';
import { cn } from '../../lib/utils';

/**
 * Semántica de color compartida.
 *
 * TODO(#704): cuando exista `src/lib/estadoTones` —lo escribe otro paquete— este
 * tipo se importa de ahí y se borra de acá. Se declara local a propósito para no
 * tocar un archivo que no es de este paquete.
 */
export type Tone = 'neutral' | 'brand' | 'success' | 'warning' | 'danger';

export type CardVariant = 'section' | 'stat' | 'row';
export type CardPadding = 'none' | 'sm' | 'md';
export type CardTag = 'div' | 'section' | 'article' | 'li';

export interface CardProps extends React.HTMLAttributes<HTMLElement> {
  /** Forma de la tarjeta. Por defecto `section`. */
  variant?: CardVariant;
  /** Pisa el padding por defecto de la variante. */
  padding?: CardPadding;
  /** Borde izquierdo de 4px con el color del tono. */
  accent?: Tone;
  /** La tarjeta responde al hover (fila clickeable). */
  interactive?: boolean;
  /** Etiqueta HTML a renderizar. Por defecto `div`. */
  as?: CardTag;
  className?: string;
  children?: React.ReactNode;
}

/** La superficie: es la misma para las tres variantes, cambia el padding. */
const SUPERFICIE =
  'bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 shadow-warm';

const PADDING_POR_VARIANTE: Record<CardVariant, string> = {
  section: 'p-4',
  stat: 'p-3',
  /* 12 vertical x 14 horizontal: la fila respira a los costados sin engordar
     la lista a lo alto. */
  row: 'py-3 px-3.5',
};

const PADDING: Record<CardPadding, string> = {
  none: '',
  sm: 'p-3',
  md: 'p-4',
};

/* `border-l-*` gana sobre el `border` de la superficie sin pelearse con él:
   Tailwind emite las utilidades por lado DESPUÉS de las de los cuatro lados,
   así que el ancho y el color de la izquierda quedan arriba. */
const ACENTO: Record<Tone, string> = {
  neutral: 'border-l-4 border-l-gray-300 dark:border-l-gray-600',
  brand: 'border-l-4 border-l-blue-600 dark:border-l-blue-400',
  success: 'border-l-4 border-l-green-600 dark:border-l-green-400',
  warning: 'border-l-4 border-l-amber-500 dark:border-l-amber-400',
  danger: 'border-l-4 border-l-red-600 dark:border-l-red-400',
};

const INTERACTIVA = 'transition-shadow hover:shadow-warm-md';

export default function Card({
  variant = 'section',
  padding,
  accent,
  interactive = false,
  as: etiqueta = 'div',
  className,
  children,
  ...resto
}: CardProps): React.ReactElement {
  // Se pasa por ElementType porque el JSX con una etiqueta variable no resuelve
  // bien la unión de props de cuatro intrínsecos distintos.
  const Etiqueta: React.ElementType = etiqueta;

  return (
    <Etiqueta
      className={cn(
        SUPERFICIE,
        padding ? PADDING[padding] : PADDING_POR_VARIANTE[variant],
        accent && ACENTO[accent],
        interactive && INTERACTIVA,
        className,
      )}
      {...resto}
    >
      {children}
    </Etiqueta>
  );
}
