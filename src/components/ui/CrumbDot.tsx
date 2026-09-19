import React from 'react';

/**
 * Separador decorativo entre items del crumb de un `PageHeader`: un puntito
 * amber sutil que rompe la monotonía sin gritar.
 *
 * Estaba copiado textualmente en los cuatro headers de vista. Es puramente
 * decorativo: va `aria-hidden` para que no se cuele en el nombre accesible ni
 * lo lea un lector de pantalla entre crumb y crumb.
 */
export default function CrumbDot(): React.ReactElement {
  return (
    <span
      className="inline-block w-1 h-1 rounded-full bg-amber-500/70 align-middle mx-2.5"
      aria-hidden="true"
    />
  );
}
