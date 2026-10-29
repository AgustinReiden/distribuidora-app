/**
 * ProductoUltimaCompra
 *
 * Sección de la ficha que responde "¿de dónde sale este costo?": la compra que
 * fijó el costo de reposición, abierta por unidad en neto, impuesto interno y
 * cada cargo prorrateado (flete, pallets, bonificaciones), hasta el costo final.
 * Es la misma cuenta que "Costo por producto" en la pantalla de la compra; la
 * arma utils/desgloseCostoCompra.
 *
 * Sólo admin y encargado: los costos no se le muestran al resto (#974).
 */
import { useMemo } from 'react'
import { Receipt } from 'lucide-react'
import { useCompraQueFijaCostoQuery } from '../../hooks/queries/useComprasQuery'
import { useAuth } from '../../hooks/supabase/useAuth'
import { desgloseCostoDeCompra } from '../../utils/desgloseCostoCompra'
import { formatPrecio, parseDateSafe } from '../../utils/formatters'

export interface ProductoUltimaCompraProps {
  productoId: string
  /** `productos.costo_real` guardado: si no es el de la compra, se dice. */
  costoFinalFicha: number | null
}

export default function ProductoUltimaCompra({ productoId, costoFinalFicha }: ProductoUltimaCompraProps) {
  const { isAdminOrEncargado } = useAuth()
  const { data: compra } = useCompraQueFijaCostoQuery(productoId, isAdminOrEncargado)
  const desglose = useMemo(
    () => (compra ? desgloseCostoDeCompra(compra, productoId) : null),
    [compra, productoId],
  )
  if (!isAdminOrEncargado || !desglose) return null

  const filas: Array<{ concepto: string; importe: number }> = [
    {
      concepto: desglose.costoEsLoPagado ? 'Lo pagado (IVA e imp. internos adentro)' : 'Neto de factura',
      importe: desglose.netoUnitario,
    },
    ...(desglose.iiUnitario ? [{ concepto: 'Impuesto interno', importe: desglose.iiUnitario }] : []),
    ...desglose.cargos.map(c => ({ concepto: c.concepto, importe: c.unitario })),
    ...(desglose.otrosAjustes
      ? [{
          concepto: desglose.iiUnitario === null ? 'Impuesto interno y cargos' : 'Otros ajustes de la compra',
          importe: desglose.otrosAjustes,
        }]
      : []),
  ]
  const difiere = costoFinalFicha !== null
    && Math.abs(costoFinalFicha - desglose.costoFinalUnitario) >= 0.01
  const origen = [
    [desglose.comprobante, desglose.numeroFactura].filter(Boolean).join(' '),
    desglose.fechaCompra ? parseDateSafe(desglose.fechaCompra).toLocaleDateString('es-AR') : null,
    desglose.proveedor,
  ].filter(Boolean).join(' · ')

  return (
    <section
      aria-label="Costo de la última compra"
      className="mt-3 p-3 rounded-lg border border-blue-200 dark:border-blue-800 bg-blue-50/60 dark:bg-blue-900/20"
    >
      <h4 className="text-xs font-semibold text-blue-900 dark:text-blue-100 flex items-center gap-1.5">
        <Receipt className="w-4 h-4" aria-hidden="true" />
        Costo de la última compra, por unidad
      </h4>
      {origen && <p className="text-xs text-blue-800/80 dark:text-blue-200/80 mt-0.5">{origen}</p>}

      <dl className="mt-2 space-y-0.5 text-sm">
        {filas.map((f, i) => (
          <div key={`${f.concepto}-${i}`} className="flex justify-between gap-3">
            <dt className="text-gray-700 dark:text-gray-300 truncate">{f.concepto}</dt>
            <dd className="tabular-nums text-gray-800 dark:text-gray-100">{formatPrecio(f.importe)}</dd>
          </div>
        ))}
        <div className="flex justify-between gap-3 pt-1 mt-1 border-t border-blue-200 dark:border-blue-800 font-semibold">
          <dt className="text-gray-900 dark:text-white">Costo final</dt>
          <dd className="tabular-nums text-gray-900 dark:text-white">{formatPrecio(desglose.costoFinalUnitario)}</dd>
        </div>
      </dl>

      <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
        {desglose.costoEsLoPagado
          ? 'Es lo que entró al costo promedio y al costo de reposición.'
          : 'Sin IVA (es crédito fiscal). Es lo que entró al costo promedio y al costo de reposición.'}
      </p>
      {difiere && (
        <p className="text-xs text-amber-700 dark:text-amber-300 mt-1">
          El costo de reposición guardado en la ficha es {formatPrecio(costoFinalFicha)}: se cambió después de esta compra.
        </p>
      )}
    </section>
  )
}
