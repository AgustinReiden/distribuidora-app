import type { ReactNode } from 'react';

export interface CargandoContenidoProps {
  /** El skeleton que ocupa el lugar del contenido. Es decorativo: va `aria-hidden`. */
  children: ReactNode;
  /** Lo que anuncia un lector de pantalla. Igual que `LoadingSpinner`. */
  texto?: string;
}

/**
 * Envoltorio accesible de un skeleton de carga.
 *
 * Los `Skeleton` de `ui/Skeleton.tsx` son cajas grises sin texto ni rol: un lector
 * de pantalla no se entera de que la vista esta cargando. `LoadingSpinner` si lo
 * decia (`role="status"`, `aria-live="polite"`, "Cargando..."); este envoltorio le
 * devuelve ese aviso al skeleton.
 *
 * Sin `aria-busy` a proposito: sobre una region viva le dice al lector que espere
 * a que termine de cambiar antes de anunciarla, y como este bloque se desmonta al
 * terminar la carga, "Cargando..." no se leeria nunca. Lo que lo distingue del
 * spinner suelto en los tests es `data-slot`.
 *
 * El skeleton adentro va `aria-hidden`: una `<table>` de relleno no tiene que
 * leerse como una tabla vacia. El texto es `sr-only` para no duplicar lo que ya
 * se ve como placeholder.
 */
export default function CargandoContenido({ children, texto = 'Cargando...' }: CargandoContenidoProps) {
  return (
    <div role="status" aria-live="polite" data-slot="cargando-contenido">
      <span className="sr-only">{texto}</span>
      <div aria-hidden="true">{children}</div>
    </div>
  );
}
