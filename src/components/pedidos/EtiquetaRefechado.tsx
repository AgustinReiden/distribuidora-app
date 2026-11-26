/**
 * La etiqueta «Refechado» (#1697): el pedido no se entregó en su día y la entrega programada
 * pasó sola al día siguiente. Muestra la fecha original. Va en la lista de pedidos, en la
 * ficha (edición) y en el armado de la ruta. La regla de cuándo se muestra vive en
 * `utils/refechado.ts`.
 */
import { CalendarClock } from 'lucide-react';
import { Badge } from '../ui/Badge';
import { etiquetaRefechado, type PedidoRefechable } from '../../utils/refechado';

export interface EtiquetaRefechadoProps {
  pedido: PedidoRefechable | null | undefined;
  className?: string;
}

export default function EtiquetaRefechado({ pedido, className }: EtiquetaRefechadoProps) {
  const etiqueta = etiquetaRefechado(pedido);
  if (!etiqueta) return null;
  return (
    <Badge tone="warning" icon={CalendarClock} title={etiqueta.detalle} className={className}>
      {etiqueta.texto}
      <span className="font-normal"> · antes {etiqueta.original}</span>
      <span className="sr-only">. {etiqueta.detalle}</span>
    </Badge>
  );
}
