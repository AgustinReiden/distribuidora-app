/**
 * La línea que declara QUÉ mide una tabla.
 *
 * Generaliza la nota que `FiltrosVentas` ya tenía al pie ("Venta = pedidos
 * entregados, por fecha del pedido…"). Vive en `ui/` y no en `vistas/reportes/`
 * porque la usan las dos pantallas, y ese es justamente el punto.
 *
 * Por qué nació: /reportes y /reportes-gerenciales medían lo mismo distinto.
 * "Venta por vendedor" en Reportes sumaba `pedidos.total` de los NO CANCELADOS
 * sin mirar el canal; en Gerenciales, los subtotales de los ítems de los
 * ENTREGADOS del canal app. Rentabilidad filtraba por `created_at` y el resto
 * por `pedidos.fecha`. Ninguno estaba mal, pero un admin que abría las dos
 * pantallas veía dos "ventas por vendedor" y no tenía con qué explicarse la
 * diferencia; que cada tabla dijera qué mide convertía una contradicción
 * silenciosa en dos preguntas con respuesta.
 *
 * La mig 241 unificó las definiciones (#568, #569): venta = pedidos
 * `entregado`, cualquier canal de venta, por `pedidos.fecha`. Así que estos
 * carteles ya no explican una divergencia — la declaran, que es lo que los hace
 * verificables: `ventaCanonica.criterio.test.tsx` los lee para que nadie mueva
 * el SQL sin mover lo que la pantalla promete.
 *
 * Va SÓLO donde hay divergencia real o un criterio no obvio. Si se pone en cada
 * tabla del sistema se vuelve ruido gris que nadie lee, y entonces no sirve
 * donde sí importa.
 */
import React from 'react';
import { Info } from 'lucide-react';

export interface CriterioProps {
  children: React.ReactNode;
  className?: string;
}

export function Criterio({ children, className = '' }: CriterioProps): React.ReactElement {
  return (
    <p
      role="note"
      className={`flex items-start gap-1.5 text-xs text-gray-500 dark:text-gray-400 ${className}`}
    >
      <Info className="w-3.5 h-3.5 flex-shrink-0 mt-0.5 opacity-70" aria-hidden="true" />
      <span>{children}</span>
    </p>
  );
}

export default Criterio;
