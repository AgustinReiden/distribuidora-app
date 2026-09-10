/**
 * La línea que declara QUÉ mide una tabla.
 *
 * Generaliza la nota que `FiltrosVentas` ya tenía al pie ("Venta = pedidos
 * entregados, por fecha del pedido…"). Vive en `ui/` y no en `vistas/reportes/`
 * porque la usan las dos pantallas, y ese es justamente el punto.
 *
 * Por qué hace falta: /reportes y /reportes-gerenciales miden lo mismo distinto.
 * "Venta por vendedor" en Reportes suma `pedidos.total` de los NO CANCELADOS sin
 * mirar el canal; en Gerenciales suma los subtotales de los ítems de los
 * ENTREGADOS del canal app. Rentabilidad filtra por `created_at` y el resto por
 * `pedidos.fecha`. Los dos números son defendibles y ninguno está mal, pero un
 * admin que abre las dos pantallas ve dos "ventas por vendedor" distintas y no
 * tiene con qué explicarse la diferencia.
 *
 * Unificar las definiciones es otra tarea (cambia números que la gente ya vio y
 * es migración de SQL). Mientras tanto, que cada tabla diga qué mide convierte
 * una contradicción silenciosa en dos preguntas distintas con dos respuestas.
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
