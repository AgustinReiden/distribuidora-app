import { AlertTriangle, Info } from 'lucide-react';
import { LEYENDA_CUPO, type AvisoCupo } from '../../utils/cupoPromo';

/**
 * El cupo de las promos con límite de las que el pedido lleva regalo (#1283). No
 * bloquea el guardado: el conteo puede tener unos segundos, y el que decide es
 * el trigger del server.
 */
export function AvisoCupoPromo({ avisos }: { avisos: AvisoCupo[] }) {
  return (
    <>
      {avisos.map(aviso => (
        <div
          key={aviso.promocionId}
          role={aviso.alcanza ? undefined : 'alert'}
          className={`flex items-start gap-2 p-3 text-xs ${
            aviso.alcanza
              ? 'text-blue-800 bg-blue-50 dark:text-blue-200 dark:bg-blue-900/20'
              : 'text-amber-800 bg-amber-50 dark:text-amber-200 dark:bg-amber-900/20'
          }`}
        >
          {aviso.alcanza
            ? <Info className="w-4 h-4 flex-shrink-0" />
            : <AlertTriangle className="w-4 h-4 flex-shrink-0" />}
          <p>
            La promo «{aviso.promoNombre}» tiene un límite de {aviso.limite} unidades de regalo: quedan{' '}
            {aviso.quedan} y este pedido lleva {aviso.lleva}. {LEYENDA_CUPO}
            {!aviso.alcanza && ' Sacá o achicá el regalo, o pedile al admin que suba el límite: si no, se rechaza al guardar.'}
          </p>
        </div>
      ))}
    </>
  );
}
