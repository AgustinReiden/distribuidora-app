/**
 * useMediaQuery
 *
 * `true` mientras la media query coincide, y se actualiza sola cuando deja de
 * coincidir (o empieza): se suscribe al evento `change` del `MediaQueryList`
 * con `useSyncExternalStore`, así que el valor del primer render ya es el
 * correcto —no hay un render en `false` y otro en `true`— y nunca queda
 * desfasado entre dos componentes que miran la misma query.
 *
 * Sin `window.matchMedia` (render en servidor, o un jsdom sin el mock) devuelve
 * `false`. Por eso conviene escribir la query de modo que `false` sea el caso
 * por defecto: el alta de pedido pregunta "¿es celular?" y no "¿es escritorio?",
 * para que en los tests que no saben nada del ancho siga saliendo el diálogo de
 * escritorio de siempre.
 *
 * El criterio de ancho es el de `PedidoFilters`: el corte `sm:` de Tailwind,
 * 640 px. "Celular" es su complemento exacto, `not all and (min-width: 640px)`
 * —lo mismo que genera el `max-sm:` de Tailwind—, y no un `max-width: 639px`
 * que dejaría sin dueño a los anchos fraccionarios entre 639 y 640.
 */
import { useCallback, useSyncExternalStore } from 'react';

/** Debajo del corte `sm:` de Tailwind (640 px): celular. */
export const CONSULTA_CELULAR = 'not all and (min-width: 640px)';

function hayMatchMedia(): boolean {
  return typeof window !== 'undefined' && typeof window.matchMedia === 'function';
}

const sinMatchMedia = (): boolean => false;

export function useMediaQuery(query: string): boolean {
  const suscribir = useCallback(
    (onCambio: () => void): (() => void) => {
      if (!hayMatchMedia()) return () => {};
      const lista = window.matchMedia(query);
      lista.addEventListener?.('change', onCambio);
      return () => lista.removeEventListener?.('change', onCambio);
    },
    [query],
  );

  const coincide = useCallback(
    (): boolean => hayMatchMedia() && window.matchMedia(query).matches,
    [query],
  );

  return useSyncExternalStore(suscribir, coincide, sinMatchMedia);
}

export default useMediaQuery;
