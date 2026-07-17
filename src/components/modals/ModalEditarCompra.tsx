/**
 * ModalEditarCompra
 *
 * Permite al admin editar los items (cantidad, costo, bonificacion y % IVA) de
 * una compra existente, dentro de la ventana de 7 dias desde su creacion.
 *
 * Limitaciones v1 (intencionales):
 *   - La cabecera (proveedor, fecha, factura, tipo_factura, forma_pago, notas)
 *     queda inmutable. Si hace falta cambiar algo de la cabecera, anular y
 *     rehacer la compra.
 *   - NO se pueden agregar items nuevos. Solo modificar o eliminar los
 *     existentes. Si falta cargar un item, anular y rehacer.
 *
 * El RPC actualizar_compra_items revierte el stock viejo, aplica el stock
 * nuevo y solo actualiza productos.costo cuando esta compra es la mas
 * reciente del producto.
 */

import { useState, memo, useMemo, lazy, Suspense } from 'react'
import { Loader2, Trash2, AlertCircle, Building2 } from 'lucide-react'
import ModalBase from './ModalBase'
import NumberInput from '../ui/NumberInput'
import { formatPrecio } from '../../utils/formatters'
import type { CompraDBExtended, ProveedorDBExtended, ProveedorFormInputExtended } from '../../types'
import type { ActualizarCompraItemsInput } from '../../hooks/queries'
import type { CambiarProveedorPayload } from './ModalCambiarProveedor'

const ModalCambiarProveedor = lazy(() => import('./ModalCambiarProveedor'))

/** Item editable dentro del modal. */
interface ItemEdit {
  productoId: string
  nombre: string
  cantidad: number
  costoUnitario: number
  bonificacion: number
  porcentajeIva: number
  impuestosInternos: number
  marcadoParaEliminar: boolean
}

export interface ModalEditarCompraProps {
  compra: CompraDBExtended
  usuarioId: string | null
  onGuardar: (input: ActualizarCompraItemsInput) => Promise<void>
  onClose: () => void
  guardando: boolean
  /** Cambiar proveedor (admin): anula + recrea la compra con otro proveedor. */
  canCambiarProveedor?: boolean
  proveedores?: ProveedorDBExtended[]
  onCambiarProveedor?: (payload: CambiarProveedorPayload) => Promise<void>
  onCrearProveedor?: (data: ProveedorFormInputExtended) => Promise<ProveedorDBExtended>
}

const ModalEditarCompra = memo(function ModalEditarCompra({
  compra,
  usuarioId,
  onGuardar,
  onClose,
  guardando,
  canCambiarProveedor = false,
  proveedores,
  onCambiarProveedor,
  onCrearProveedor,
}: ModalEditarCompraProps) {
  const esZZ = compra.tipo_factura === 'ZZ'
  const otrosImpuestos = compra.otros_impuestos ?? 0
  // Percepciones y no gravado (cabecera) no se editan acá: se conservan.
  const percepciones = (compra.percepcion_iva ?? 0) + (compra.percepcion_iibb ?? 0)
  const noGravado = compra.no_gravado ?? 0

  const [items, setItems] = useState<ItemEdit[]>(() =>
    (compra.items ?? []).map((it) => ({
      productoId: it.producto_id,
      nombre: it.producto?.nombre ?? `Producto #${it.producto_id}`,
      cantidad: it.cantidad ?? 0,
      costoUnitario: it.costo_unitario ?? 0,
      bonificacion: it.bonificacion ?? 0,
      // Snapshot de la línea (mig 113); líneas viejas caen a los atributos
      // fiscales actuales del producto y por último a defaults.
      porcentajeIva: esZZ ? 0 : (it.porcentaje_iva ?? it.producto?.porcentaje_iva ?? 21),
      impuestosInternos: esZZ ? 0 : (it.impuestos_internos ?? it.producto?.impuestos_internos ?? 0),
      marcadoParaEliminar: false,
    })),
  )

  const [errorValidacion, setErrorValidacion] = useState<string | null>(null)

  // Items que efectivamente se persisten (los no eliminados).
  const itemsActivos = useMemo(() => items.filter((i) => !i.marcadoParaEliminar), [items])

  // --- Cambiar proveedor (admin): anula + recrea la compra con otro proveedor ---
  const [mostrarCambioProveedor, setMostrarCambioProveedor] = useState(false)
  const [cambiandoProveedor, setCambiandoProveedor] = useState(false)

  // Snapshot inicial de items para detectar ediciones sin guardar: el cambio de
  // proveedor clona los items DE LA BD, no los del modal, así que si hay cambios
  // sin guardar se bloquea para no recrear con datos inconsistentes.
  const itemsIniciales = useMemo(
    () =>
      (compra.items ?? []).map((it) => ({
        productoId: it.producto_id,
        cantidad: it.cantidad ?? 0,
        costoUnitario: it.costo_unitario ?? 0,
        bonificacion: it.bonificacion ?? 0,
        porcentajeIva: esZZ ? 0 : (it.porcentaje_iva ?? it.producto?.porcentaje_iva ?? 21),
        impuestosInternos: esZZ ? 0 : (it.impuestos_internos ?? it.producto?.impuestos_internos ?? 0),
      })),
    [compra.items, esZZ],
  )

  const itemsModificados = useMemo(() => {
    if (items.some((i) => i.marcadoParaEliminar)) return true
    if (items.length !== itemsIniciales.length) return true
    return items.some((it) => {
      const orig = itemsIniciales.find((o) => o.productoId === it.productoId)
      if (!orig) return true
      return (
        orig.cantidad !== it.cantidad ||
        orig.costoUnitario !== it.costoUnitario ||
        orig.bonificacion !== it.bonificacion ||
        orig.porcentajeIva !== it.porcentajeIva ||
        orig.impuestosInternos !== it.impuestosInternos
      )
    })
  }, [items, itemsIniciales])

  const puedeCambiarProveedor = Boolean(
    canCambiarProveedor && onCambiarProveedor && compra.estado !== 'cancelada',
  )

  async function handleConfirmarCambioProveedor(payload: CambiarProveedorPayload) {
    if (!onCambiarProveedor) return
    setCambiandoProveedor(true)
    try {
      await onCambiarProveedor(payload)
      setMostrarCambioProveedor(false) // el container cierra el modal de edición al tener éxito
    } catch {
      // dejar abierto para reintentar; el container ya notificó el error
    } finally {
      setCambiandoProveedor(false)
    }
  }

  // Totales calculados (incluye imp. internos por línea; percepciones y no
  // gravado de la cabecera se conservan tal cual).
  const totales = useMemo(() => {
    let subtotal = 0
    let iva = 0
    let impuestosInternos = 0
    for (const it of itemsActivos) {
      const netoUnitario = it.costoUnitario * (1 - it.bonificacion / 100)
      const subtotalItem = it.cantidad * netoUnitario
      subtotal += subtotalItem
      if (!esZZ) {
        iva += subtotalItem * (it.porcentajeIva / 100)
        impuestosInternos += subtotalItem * ((it.impuestosInternos || 0) / 100)
      }
    }
    const total = subtotal + iva + impuestosInternos + percepciones + noGravado + otrosImpuestos
    return { subtotal, iva, impuestosInternos, total }
  }, [itemsActivos, esZZ, otrosImpuestos, percepciones, noGravado])

  function updateItem<K extends keyof ItemEdit>(productoId: string, field: K, value: ItemEdit[K]) {
    setItems((prev) =>
      prev.map((it) => (it.productoId === productoId ? { ...it, [field]: value } : it)),
    )
  }

  function toggleEliminar(productoId: string) {
    setItems((prev) =>
      prev.map((it) =>
        it.productoId === productoId ? { ...it, marcadoParaEliminar: !it.marcadoParaEliminar } : it,
      ),
    )
  }

  function validar(): string | null {
    if (itemsActivos.length === 0) {
      return 'La compra debe tener al menos un item. Si querés vaciarla, anulala desde la lista.'
    }
    for (const it of itemsActivos) {
      if (!Number.isFinite(it.cantidad) || it.cantidad <= 0) {
        return `Cantidad invalida en "${it.nombre}". Debe ser mayor a 0.`
      }
      if (!Number.isFinite(it.costoUnitario) || it.costoUnitario < 0) {
        return `Costo invalido en "${it.nombre}".`
      }
      if (it.bonificacion < 0 || it.bonificacion >= 100) {
        return `Bonificacion fuera de rango en "${it.nombre}" (0 a 99,99).`
      }
      if (!esZZ && (it.porcentajeIva < 0 || it.porcentajeIva > 100)) {
        return `% IVA fuera de rango en "${it.nombre}".`
      }
    }
    return null
  }

  async function handleGuardar() {
    const err = validar()
    if (err) {
      setErrorValidacion(err)
      return
    }
    setErrorValidacion(null)

    const itemsPayload = itemsActivos.map((it) => {
      const neto = it.costoUnitario * (1 - it.bonificacion / 100)
      const subtotalItem = it.cantidad * neto
      return {
        productoId: it.productoId,
        cantidad: it.cantidad,
        costoUnitario: it.costoUnitario,
        subtotal: subtotalItem,
        bonificacion: it.bonificacion,
        porcentajeIva: esZZ ? 0 : it.porcentajeIva,
        impuestosInternos: it.impuestosInternos,
      }
    })

    await onGuardar({
      compraId: compra.id,
      usuarioId,
      subtotal: totales.subtotal,
      iva: totales.iva,
      total: totales.total,
      impuestosInternos: totales.impuestosInternos,
      items: itemsPayload,
    })
  }

  const fechaCompra = compra.fecha_compra ?? '—'
  const proveedor = compra.proveedor?.nombre ?? compra.proveedor_nombre ?? '—'
  const factura = compra.numero_factura ?? '—'

  return (
    <ModalBase title={`Editar Compra #${compra.id}`} onClose={onClose} maxWidth="max-w-4xl">
      <div className="p-4 space-y-4 max-h-[75vh] overflow-y-auto">
        {/* Cabecera readonly */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3 text-sm">
          <div>
            <p className="text-xs text-gray-500 dark:text-gray-400">Proveedor</p>
            <p className="font-medium dark:text-gray-200">{proveedor}</p>
          </div>
          <div>
            <p className="text-xs text-gray-500 dark:text-gray-400">Factura</p>
            <p className="font-medium dark:text-gray-200">{factura}</p>
          </div>
          <div>
            <p className="text-xs text-gray-500 dark:text-gray-400">Fecha</p>
            <p className="font-medium dark:text-gray-200">{fechaCompra}</p>
          </div>
          <div>
            <p className="text-xs text-gray-500 dark:text-gray-400">Tipo</p>
            <p className="font-medium dark:text-gray-200">{compra.tipo_factura ?? 'FC'}</p>
          </div>
        </div>

        <div className="bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg p-3 text-xs text-amber-800 dark:text-amber-300 flex items-start gap-2">
          <AlertCircle className="w-4 h-4 mt-0.5 shrink-0" />
          <span>
            Solo se editan items. La cabecera (fecha, factura, tipo) queda inmutable. Para corregir
            el <strong>proveedor</strong> usá el botón de abajo; para el resto, anulá la compra y
            volvé a cargarla. No se pueden agregar items nuevos: anulá y rehacé si falta cargar uno.
          </span>
        </div>

        {puedeCambiarProveedor && (
          <div className="flex flex-wrap items-center gap-2">
            <button
              type="button"
              onClick={() => setMostrarCambioProveedor(true)}
              disabled={itemsModificados || cambiandoProveedor}
              title={
                itemsModificados
                  ? 'Guardá o descartá los cambios de items primero'
                  : 'Anular y recrear la compra con otro proveedor'
              }
              className="inline-flex items-center gap-2 px-3 py-2 text-sm rounded-lg border border-amber-300 dark:border-amber-700 text-amber-800 dark:text-amber-300 hover:bg-amber-50 dark:hover:bg-amber-900/30 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <Building2 className="w-4 h-4" />
              Cambiar proveedor
            </button>
            {itemsModificados && (
              <span className="text-xs text-gray-500 dark:text-gray-400">
                Guardá los cambios de items primero.
              </span>
            )}
          </div>
        )}

        {/* Tabla de items */}
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-xs text-gray-500 dark:text-gray-400 border-b dark:border-gray-700">
                <th className="text-left py-2 pr-2">Producto</th>
                <th className="text-right py-2 px-2 w-24">Cantidad</th>
                <th className="text-right py-2 px-2 w-32">Costo unit.</th>
                <th className="text-right py-2 px-2 w-24">Bonif. %</th>
                {!esZZ && <th className="text-right py-2 px-2 w-20">IVA %</th>}
                <th className="text-right py-2 px-2 w-32">Subtotal</th>
                <th className="py-2 pl-2 w-12"></th>
              </tr>
            </thead>
            <tbody>
              {items.map((it) => {
                const neto = it.costoUnitario * (1 - it.bonificacion / 100)
                const subtotalItem = it.cantidad * neto
                const rowClass = it.marcadoParaEliminar
                  ? 'opacity-40 line-through'
                  : ''
                return (
                  <tr key={it.productoId} className={`border-b dark:border-gray-700 ${rowClass}`}>
                    <td className="py-2 pr-2 dark:text-gray-200">{it.nombre}</td>
                    <td className="py-2 px-2">
                      <NumberInput
                        integer
                        min={1}
                        emptyValue={1}
                        value={it.cantidad}
                        onChange={(n) => updateItem(it.productoId, 'cantidad', n)}
                        commitOnChange
                        disabled={it.marcadoParaEliminar}
                        className="w-full px-2 py-1 text-right border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-50"
                      />
                    </td>
                    <td className="py-2 px-2">
                      <NumberInput
                        min={0}
                        emptyValue={0}
                        value={it.costoUnitario}
                        onChange={(n) => updateItem(it.productoId, 'costoUnitario', n)}
                        commitOnChange
                        disabled={it.marcadoParaEliminar}
                        className="w-full px-2 py-1 text-right border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-50"
                      />
                    </td>
                    <td className="py-2 px-2">
                      <NumberInput
                        min={0}
                        max={99.99}
                        emptyValue={0}
                        value={it.bonificacion}
                        onChange={(n) => updateItem(it.productoId, 'bonificacion', n)}
                        commitOnChange
                        disabled={it.marcadoParaEliminar}
                        className="w-full px-2 py-1 text-right border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-50"
                      />
                    </td>
                    {!esZZ && (
                      <td className="py-2 px-2">
                        <NumberInput
                          min={0}
                          max={100}
                          emptyValue={0}
                          value={it.porcentajeIva}
                          onChange={(n) => updateItem(it.productoId, 'porcentajeIva', n)}
                          commitOnChange
                          disabled={it.marcadoParaEliminar}
                          className="w-full px-2 py-1 text-right border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-50"
                        />
                      </td>
                    )}
                    <td className="py-2 px-2 text-right tabular-nums dark:text-gray-200">
                      {formatPrecio(subtotalItem)}
                    </td>
                    <td className="py-2 pl-2 text-right">
                      <button
                        type="button"
                        onClick={() => toggleEliminar(it.productoId)}
                        title={it.marcadoParaEliminar ? 'Restaurar item' : 'Eliminar item'}
                        className="text-red-600 hover:text-red-800 dark:text-red-400 dark:hover:text-red-300"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>

        {/* Totales */}
        <div className="border-t dark:border-gray-700 pt-3 space-y-1 text-sm">
          <div className="flex justify-between dark:text-gray-300">
            <span>Subtotal</span>
            <span className="tabular-nums">{formatPrecio(totales.subtotal)}</span>
          </div>
          <div className="flex justify-between dark:text-gray-300">
            <span>IVA{esZZ ? ' (ZZ → 0)' : ''}</span>
            <span className="tabular-nums">{formatPrecio(totales.iva)}</span>
          </div>
          {totales.impuestosInternos > 0 && (
            <div className="flex justify-between dark:text-gray-300">
              <span>Impuestos internos</span>
              <span className="tabular-nums">{formatPrecio(totales.impuestosInternos)}</span>
            </div>
          )}
          {percepciones > 0 && (
            <div className="flex justify-between dark:text-gray-300">
              <span>Percepciones (sin cambio)</span>
              <span className="tabular-nums">{formatPrecio(percepciones)}</span>
            </div>
          )}
          {noGravado > 0 && (
            <div className="flex justify-between dark:text-gray-300">
              <span>No gravado (sin cambio)</span>
              <span className="tabular-nums">{formatPrecio(noGravado)}</span>
            </div>
          )}
          {otrosImpuestos > 0 && (
            <div className="flex justify-between dark:text-gray-300">
              <span>Otros impuestos (sin cambio)</span>
              <span className="tabular-nums">{formatPrecio(otrosImpuestos)}</span>
            </div>
          )}
          <div className="flex justify-between font-semibold text-base dark:text-white pt-2 border-t dark:border-gray-700">
            <span>Total</span>
            <span className="tabular-nums">{formatPrecio(totales.total)}</span>
          </div>
        </div>

        {errorValidacion && (
          <div className="flex items-start gap-2 text-sm text-red-700 dark:text-red-400 bg-red-50 dark:bg-red-900/20 px-3 py-2 rounded-lg">
            <AlertCircle className="w-4 h-4 mt-0.5 shrink-0" />
            <span>{errorValidacion}</span>
          </div>
        )}

        {/* Acciones */}
        <div className="flex justify-end gap-2 pt-2 border-t dark:border-gray-700">
          <button
            type="button"
            onClick={onClose}
            disabled={guardando}
            className="px-4 py-2 text-sm rounded-lg border dark:border-gray-600 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700 disabled:opacity-50"
          >
            Cancelar
          </button>
          <button
            type="button"
            onClick={handleGuardar}
            disabled={guardando}
            className="px-4 py-2 text-sm rounded-lg bg-blue-600 text-white hover:bg-blue-700 disabled:bg-blue-400 inline-flex items-center gap-2"
          >
            {guardando ? <Loader2 className="w-4 h-4 animate-spin" /> : null}
            Guardar cambios
          </button>
        </div>
      </div>

      {/* Cambiar proveedor (anidado): anula + recrea la compra con otro proveedor */}
      {mostrarCambioProveedor && puedeCambiarProveedor && (
        <Suspense fallback={null}>
          <ModalCambiarProveedor
            compra={compra}
            proveedores={proveedores ?? []}
            onConfirmar={handleConfirmarCambioProveedor}
            onClose={() => setMostrarCambioProveedor(false)}
            guardando={cambiandoProveedor}
            onCrearProveedor={onCrearProveedor}
          />
        </Suspense>
      )}
    </ModalBase>
  )
})

export default ModalEditarCompra
