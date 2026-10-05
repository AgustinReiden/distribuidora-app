import React, { useState, useMemo } from 'react'
import { X, FileText, AlertTriangle } from 'lucide-react'
import { Button } from '../ui/Button'
import NumberInput from '../ui/NumberInput'
import { formatPrecio } from '../../utils/formatters'
import type { CondicionIva, NotaCreditoDB, NotaCreditoFormInput } from '../../types'
import {
  calcularIINotaCredito,
  calcularTotalesNotaCredito,
  totalesAjusteNotaCredito,
} from '../../utils/notaCredito'

interface CompraItem {
  /** `compra_items.id`: la clave de la línea. Ver `LineaCompraNC`. */
  id: string
  producto_id: string
  producto?: { id: string; nombre: string } | null
  cantidad: number
  costo_unitario: number
  bonificacion?: number
  /** Snapshots fiscales de la línea original (mig 113/177) */
  porcentaje_iva?: number | null
  condicion_iva?: CondicionIva | null
  /** Neto bonificado de la línea: base del reparto del II (mig 280). */
  subtotal?: number | string | null
  /** Tasa efectiva de II de la línea, en % (mig 280). */
  impuestos_internos?: number | string | null
}

/** Devolución de mercadería (baja stock) o ajuste sin mercadería (mig 280). */
type ModoNota = 'devolucion' | 'ajuste'

export interface ModalNotaCreditoProps {
  compra: {
    id: string
    items: CompraItem[]
    proveedor_nombre?: string
    proveedor?: { nombre: string } | null
    numero_factura?: string
    /** ZZ: no hay crédito fiscal; un ajuste es sólo un total. */
    tipo_factura?: string | null
    /** II que liquidó la factura: se reparte entre lo devuelto. */
    impuestos_internos?: number | string | null
  }
  notasExistentes: NotaCreditoDB[]
  onSave: (data: NotaCreditoFormInput) => Promise<void>
  onClose: () => void
}

export default function ModalNotaCredito({
  compra,
  notasExistentes,
  onSave,
  onClose,
}: ModalNotaCreditoProps): React.ReactElement {
  const [saving, setSaving] = useState(false)
  const [modo, setModo] = useState<ModoNota>('devolucion')
  const [motivo, setMotivo] = useState('')
  const [numeroNota, setNumeroNota] = useState('')
  const esZZ = compra.tipo_factura === 'ZZ'
  // Ajuste sin mercadería. El IVA sigue al 21% del neto hasta que se lo toca.
  const [ajNeto, setAjNeto] = useState(0)
  const [ajIva, setAjIva] = useState(0)
  const [ajIvaTocado, setAjIvaTocado] = useState(false)
  const [ajII, setAjII] = useState(0)
  const [ajTotalZZ, setAjTotalZZ] = useState(0)
  // Todo lo que indexa las líneas va por `compra_items.id` y no por
  // `producto_id`: la misma factura puede traer el mismo producto en dos
  // renglones, y con el producto como clave las dos filas compartían cantidad
  // —tipear 3 en una ponía 3 en la otra y la nota acreditaba 6—.
  const [cantidades, setCantidades] = useState<Record<string, number>>(() => {
    const initial: Record<string, number> = {}
    for (const item of compra.items) {
      initial[item.id] = 0
    }
    return initial
  })

  // Lo ya acreditado sale de las notas existentes, que hablan de PRODUCTO:
  // `nota_credito_items` no guarda de qué línea salió cada unidad.
  const yaAcreditado = useMemo(() => {
    const acreditado: Record<string, number> = {}
    for (const nota of notasExistentes) {
      for (const ncItem of nota.items || []) {
        acreditado[ncItem.producto_id] = (acreditado[ncItem.producto_id] || 0) + ncItem.cantidad
      }
    }
    return acreditado
  }, [notasExistentes])

  /**
   * Cuánto queda por acreditar en CADA línea, y cuánto de lo ya acreditado le
   * toca a cada una.
   *
   * Lo acreditado viene por producto y hay que bajarlo a las líneas: se consume
   * en el orden de la factura, llenando una línea antes de pasar a la siguiente.
   * El reparto es una convención —la base no sabe de qué renglón salió cada
   * unidad— pero conserva el total: la suma de los máximos por línea sigue siendo
   * lo comprado menos lo acreditado. Repetir el número del producto en las dos
   * filas, en cambio, habilitaba acreditar el doble.
   */
  const { maxCreditable, yaAcreditadoPorLinea } = useMemo(() => {
    const max: Record<string, number> = {}
    const yaPorLinea: Record<string, number> = {}
    const pendiente = { ...yaAcreditado }
    for (const item of compra.items) {
      const consumido = Math.min(pendiente[item.producto_id] || 0, item.cantidad)
      pendiente[item.producto_id] = (pendiente[item.producto_id] || 0) - consumido
      yaPorLinea[item.id] = consumido
      max[item.id] = item.cantidad - consumido
    }
    return { maxCreditable: max, yaAcreditadoPorLinea: yaPorLinea }
  }, [compra.items, yaAcreditado])

  // Calculate subtotal from credited items
  const { subtotal, iva, itemsConCantidad } = useMemo(
    () => calcularTotalesNotaCredito(compra.items, cantidades),
    [cantidades, compra.items],
  )

  // II de lo devuelto: vista previa. La base lo recalcula con la misma regla
  // (`ii_nota_credito_compra`, mig 280) y es la que guarda.
  const iiDevolucion = useMemo(() => {
    const porProducto: Record<string, number> = {}
    for (const it of itemsConCantidad) {
      porProducto[it.productoId] = (porProducto[it.productoId] || 0) + it.cantidad
    }
    return calcularIINotaCredito(compra, porProducto)
  }, [compra, itemsConCantidad])

  const ajuste = useMemo(() => totalesAjusteNotaCredito({
    tipoFactura: esZZ ? 'ZZ' : 'FC',
    neto: ajNeto,
    iva: ajIvaTocado ? ajIva : Math.round(ajNeto * 21) / 100,
    impuestosInternos: ajII,
    totalZZ: ajTotalZZ,
  }), [esZZ, ajNeto, ajIva, ajIvaTocado, ajII, ajTotalZZ])

  const totalDevolucion = subtotal + iva + iiDevolucion
  const puedeGuardar = modo === 'devolucion'
    ? itemsConCantidad.length > 0
    : ajuste.total > 0 && motivo.trim() !== ''

  const handleCantidadChange = (lineaId: string, value: string) => {
    const num = parseInt(value, 10)
    const max = maxCreditable[lineaId] || 0
    if (isNaN(num) || num < 0) {
      setCantidades(prev => ({ ...prev, [lineaId]: 0 }))
    } else {
      setCantidades(prev => ({ ...prev, [lineaId]: Math.min(num, max) }))
    }
  }

  const handleGuardar = async () => {
    if (!puedeGuardar) return
    setSaving(true)
    try {
      const data: NotaCreditoFormInput = modo === 'devolucion'
        ? {
            compraId: compra.id,
            numeroNota: numeroNota || null,
            motivo: motivo || null,
            subtotal,
            iva,
            total: totalDevolucion,
            impuestosInternos: iiDevolucion,
            items: itemsConCantidad,
          }
        : {
            compraId: compra.id,
            numeroNota: numeroNota || null,
            motivo: motivo.trim(),
            subtotal: ajuste.subtotal,
            iva: ajuste.iva,
            total: ajuste.total,
            impuestosInternos: ajuste.impuestosInternos,
            items: [],
          }
      await onSave(data)
    } finally {
      setSaving(false)
    }
  }

  const referencia = compra.numero_factura
    ? `Factura ${compra.numero_factura}`
    : compra.proveedor?.nombre || compra.proveedor_nombre || `Compra #${compra.id}`

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-3xl max-h-[90vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-blue-100 dark:bg-blue-900/30 rounded-lg">
              <FileText className="w-5 h-5 text-blue-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">
                Nota de Credito
              </h2>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                {referencia}
              </p>
            </div>
          </div>
          <Button onClick={onClose} variant="ghost" size="iconSm" aria-label="Cerrar">
            <X className="w-5 h-5 text-gray-500" />
          </Button>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          <div role="group" aria-label="Tipo de nota de crédito" className="grid grid-cols-2 gap-2">
            <Button
              type="button"
              variant={modo === 'devolucion' ? 'primary' : 'secondary'}
              size="md"
              aria-pressed={modo === 'devolucion'}
              onClick={() => setModo('devolucion')}
            >
              Devolución de mercadería
            </Button>
            <Button
              type="button"
              variant={modo === 'ajuste' ? 'primary' : 'secondary'}
              size="md"
              aria-pressed={modo === 'ajuste'}
              onClick={() => setModo('ajuste')}
            >
              Ajuste sin mercadería
            </Button>
          </div>

          {modo === 'ajuste' ? (
            <AjusteSinMercaderia
              esZZ={esZZ}
              neto={ajNeto}
              iva={ajuste.iva}
              ii={ajII}
              totalZZ={ajTotalZZ}
              onNeto={setAjNeto}
              onIva={(n) => { setAjIva(n); setAjIvaTocado(true) }}
              onII={setAjII}
              onTotalZZ={setAjTotalZZ}
            />
          ) : (<>
          {/* Warning if all items fully credited */}
          {compra.items.every(item => (maxCreditable[item.id] || 0) <= 0) && (
            <div className="flex items-center gap-2 p-3 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg">
              <AlertTriangle className="w-5 h-5 text-yellow-600 flex-shrink-0" />
              <p className="text-sm text-yellow-700 dark:text-yellow-400">
                Todos los items de esta compra ya fueron acreditados en su totalidad.
              </p>
            </div>
          )}

          {/* Items table */}
          <div className="bg-gray-50 dark:bg-gray-900 rounded-lg overflow-hidden">
            <table className="w-full text-sm">
              <thead className="bg-gray-100 dark:bg-gray-800">
                <tr>
                  <th className="text-left px-4 py-2 text-gray-600 dark:text-gray-400">Producto</th>
                  <th className="text-center px-4 py-2 text-gray-600 dark:text-gray-400">Cant. Original</th>
                  <th className="text-center px-4 py-2 text-gray-600 dark:text-gray-400">Ya Acreditado</th>
                  <th className="text-center px-4 py-2 text-gray-600 dark:text-gray-400">A Acreditar</th>
                  <th className="text-right px-4 py-2 text-gray-600 dark:text-gray-400">Subtotal</th>
                </tr>
              </thead>
              <tbody className="divide-y dark:divide-gray-700">
                {compra.items.map((item) => {
                  const ya = yaAcreditadoPorLinea[item.id] || 0
                  const max = maxCreditable[item.id] || 0
                  const cant = cantidades[item.id] || 0
                  const itemSubtotal = cant * item.costo_unitario

                  return (
                    <tr key={item.id}>
                      <td className="px-4 py-3">
                        <p className="font-medium text-gray-800 dark:text-white">
                          {item.producto?.nombre || 'Producto'}
                        </p>
                        <p className="text-xs text-gray-500 dark:text-gray-400">
                          {formatPrecio(item.costo_unitario)} c/u
                        </p>
                      </td>
                      <td className="px-4 py-3 text-center text-gray-800 dark:text-white">
                        {item.cantidad}
                      </td>
                      <td className="px-4 py-3 text-center">
                        <span className={ya > 0 ? 'text-orange-600 dark:text-orange-400 font-medium' : 'text-gray-400 dark:text-gray-500'}>
                          {ya}
                        </span>
                      </td>
                      <td className="px-4 py-3 text-center">
                        <NumberInput
                          integer
                          min={0}
                          max={max}
                          emptyValue={0}
                          commitOnChange
                          value={cant}
                          aria-label={`Cantidad a acreditar de ${item.producto?.nombre || 'Producto'}`}
                          onChange={(n) => handleCantidadChange(item.id, String(n))}
                          disabled={max <= 0}
                          className="w-20 px-2 py-1 text-center border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-800 dark:text-white disabled:opacity-50 disabled:cursor-not-allowed focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                        />
                        {max > 0 && (
                          <p className="text-xs text-gray-400 dark:text-gray-500 mt-1">max: {max}</p>
                        )}
                      </td>
                      <td className="px-4 py-3 text-right font-medium text-gray-800 dark:text-white">
                        {cant > 0 ? formatPrecio(itemSubtotal) : '-'}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
          </>)}

          {/* Motivo */}
          <div>
            <label htmlFor="nc-motivo" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              {modo === 'ajuste' ? 'Motivo (obligatorio)' : 'Motivo'}
            </label>
            <textarea
              id="nc-motivo"
              value={motivo}
              onChange={(e) => setMotivo(e.target.value)}
              placeholder={modo === 'ajuste'
                ? 'Ej: descuento por volumen, diferencia de precio, impuesto interno mal liquidado'
                : 'Motivo de la nota de credito...'}
              rows={3}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-800 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:ring-2 focus:ring-blue-500 focus:border-blue-500 resize-none"
            />
          </div>

          {/* Numero de nota */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Numero de nota (opcional)
            </label>
            <input
              type="text"
              value={numeroNota}
              onChange={(e) => setNumeroNota(e.target.value)}
              placeholder="Ej: NC-0001"
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-800 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>

          {/* Totals */}
          <div className="bg-blue-50 dark:bg-blue-900/20 rounded-lg p-4">
            {modo === 'devolucion' ? (
            <div className="space-y-2">
              <div className="flex justify-between text-sm">
                <span className="text-gray-600 dark:text-gray-400">Subtotal:</span>
                <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(subtotal)}</span>
              </div>
              <div className="flex justify-between text-sm">
                {/* Ya no es un 21% fijo: sale de la alícuota de cada línea. */}
                <span className="text-gray-600 dark:text-gray-400">IVA:</span>
                <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(iva)}</span>
              </div>
              {iiDevolucion > 0 && (
                <div className="flex justify-between text-sm">
                  <span className="text-gray-600 dark:text-gray-400">Impuestos internos:</span>
                  <span className="font-medium text-gray-800 dark:text-white" data-testid="nc-ii">{formatPrecio(iiDevolucion)}</span>
                </div>
              )}
              <div className="flex justify-between text-lg font-bold pt-2 border-t border-blue-200 dark:border-blue-800">
                <span className="text-gray-800 dark:text-white">Total:</span>
                <span className="text-blue-600" data-testid="nc-total">{formatPrecio(totalDevolucion)}</span>
              </div>
            </div>
            ) : (
            <div className="space-y-2">
              <p className="text-xs text-gray-600 dark:text-gray-400">
                No mueve stock ni costos: en el reporte gerencial suma a &quot;Descuentos de proveedores&quot; en el mes de la nota.
              </p>
              <div className="flex justify-between text-lg font-bold pt-2 border-t border-blue-200 dark:border-blue-800">
                <span className="text-gray-800 dark:text-white">Total:</span>
                <span className="text-blue-600" data-testid="nc-total">{formatPrecio(ajuste.total)}</span>
              </div>
            </div>
            )}
          </div>
        </div>

        {/* Footer */}
        <div className="flex gap-3 p-4 border-t dark:border-gray-700">
          <Button variant="secondary" size="md" onClick={onClose} className="flex-1">
            Cancelar
          </Button>
          <Button
            variant="primary"
            size="md"
            onClick={handleGuardar}
            disabled={saving || !puedeGuardar}
            className="flex-1"
          >
            {saving ? 'Guardando...' : 'Guardar'}
          </Button>
        </div>
      </div>
    </div>
  )
}

const inputClase = 'w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-800 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500'

/**
 * Importes de una nota sin mercadería. FC: neto, IVA (21% del neto hasta que
 * se lo cambia) e II. ZZ: sólo el total, porque lo pagado ya es el costo final
 * y no hay crédito fiscal que acreditar.
 */
function AjusteSinMercaderia({ esZZ, neto, iva, ii, totalZZ, onNeto, onIva, onII, onTotalZZ }: {
  esZZ: boolean
  neto: number
  iva: number
  ii: number
  totalZZ: number
  onNeto: (n: number) => void
  onIva: (n: number) => void
  onII: (n: number) => void
  onTotalZZ: (n: number) => void
}): React.ReactElement {
  if (esZZ) {
    return (
      <div>
        <label htmlFor="nc-aj-total" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
          Total que acredita el proveedor
        </label>
        <NumberInput id="nc-aj-total" min={0} emptyValue={0} commitOnChange value={totalZZ} onChange={onTotalZZ} className={inputClase} />
        <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">Compra ZZ: sin IVA ni crédito fiscal.</p>
      </div>
    )
  }
  return (
    <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
      <div>
        <label htmlFor="nc-aj-neto" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Neto</label>
        <NumberInput id="nc-aj-neto" min={0} emptyValue={0} commitOnChange value={neto} onChange={onNeto} className={inputClase} />
      </div>
      <div>
        <label htmlFor="nc-aj-iva" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">IVA</label>
        <NumberInput id="nc-aj-iva" min={0} emptyValue={0} commitOnChange value={iva} onChange={onIva} className={inputClase} />
      </div>
      <div>
        <label htmlFor="nc-aj-ii" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Impuestos internos</label>
        <NumberInput id="nc-aj-ii" min={0} emptyValue={0} commitOnChange value={ii} onChange={onII} className={inputClase} />
      </div>
    </div>
  )
}
