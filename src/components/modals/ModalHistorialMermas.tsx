/**
 * Historial de mermas, con rango de fechas, valorización y export.
 *
 * QUÉ NÚMERO MUESTRA, Y POR QUÉ NO ES LA SUMA DE TODO
 * --------------------------------------------------
 * El total en plata EXCLUYE los motivos 'promociones' y 'promociones_reversion',
 * igual que el KPI de mermas del reporte gerencial (mig 130): no son pérdida,
 * son la contrapartida de un regalo que ya está contabilizado en el pedido.
 * Sumarlos mostraría ~$2,5M donde el gerencial muestra ~$597.600, y alguien lo
 * reportaría como bug con razón. Se muestran igual en el detalle y en el
 * resumen por motivo, etiquetados como ajuste.
 *
 * DE DÓNDE SALE LA PLATA
 * ----------------------
 * El costo es el CONGELADO al momento de la merma (`costo_unitario`, mig 119).
 * Las filas viejas que no lo tienen caen al costo de hoy y se marcan como
 * estimadas. El precio de venta no tiene histórico en la base, así que es
 * siempre el precio de HOY, y se aclara. Todo eso vive en
 * `utils/valorizacionMermas.ts`, con tests.
 *
 * EL FILTRO DE FECHA VA AL SERVIDOR
 * ---------------------------------
 * Filtrar en el cliente obligaría a traer todo, y PostgREST corta en 1000 filas
 * en silencio. Ver `useMermasQuery`.
 */
import React, { useState, useMemo, useCallback, ChangeEvent } from 'react'
import { X, Package, Calendar, User, FileText, TrendingDown, Download, AlertTriangle, Info } from 'lucide-react'
import type { Producto, Usuario } from '../../types'
import { useMermasQuery, LIMITE_MERMAS } from '../../hooks/queries/useMermasQuery'
import { presetsVentas } from '../../utils/periodosReporte'
import { formatCurrency } from '../../utils/formatters'
import {
  valorizarMerma,
  totalizarMermas,
  resumenPorMotivo,
  type MermaValorizada,
  type ProductoParaValorizar,
} from '../../utils/valorizacionMermas'

export interface ModalHistorialMermasProps {
  productos?: Producto[]
  usuarios?: Usuario[]
  onClose: () => void
}

/**
 * 'promociones_reversion' faltaba: caía al fallback y se renderizaba el string
 * crudo de la base, con guion bajo y todo.
 */
const LABELS_MOTIVO: Record<string, string> = {
  rotura: 'Rotura',
  vencimiento: 'Vencimiento',
  robo: 'Robo/Hurto',
  decomiso: 'Decomiso',
  devolucion: 'Devolución',
  error_inventario: 'Error inventario',
  muestra: 'Muestra',
  promociones: 'Promociones',
  promociones_reversion: 'Reversión de promoción',
  otro: 'Otro',
}

function labelMotivo(motivo: string): string {
  return LABELS_MOTIVO[motivo] ?? motivo
}

function fechaCorta(iso?: string): string {
  if (!iso) return ''
  return new Date(iso).toLocaleDateString('es-AR')
}

export default function ModalHistorialMermas({
  productos = [],
  usuarios = [],
  onClose,
}: ModalHistorialMermasProps): React.ReactElement {
  const presets = useMemo(() => presetsVentas(), [])
  const [presetId, setPresetId] = useState<string>(presets[0].id)
  const [desde, setDesde] = useState<string>(presets[0].desde)
  const [hasta, setHasta] = useState<string>(presets[0].hasta)
  const [filtroProducto, setFiltroProducto] = useState<string>('')
  const [filtroMotivo, setFiltroMotivo] = useState<string>('')
  const [exportando, setExportando] = useState(false)

  const { data: mermas = [], isLoading } = useMermasQuery({ desde, hasta })

  const elegirPreset = useCallback((id: string) => {
    setPresetId(id)
    const p = presets.find(x => x.id === id)
    if (p) {
      setDesde(p.desde)
      setHasta(p.hasta)
    }
  }, [presets])

  const productosPorId = useMemo(() => {
    const m = new Map<string, ProductoParaValorizar>()
    for (const p of productos) m.set(String(p.id), p as unknown as ProductoParaValorizar)
    return m
  }, [productos])

  const getUsuarioNombre = useCallback((usuarioId: string | null | undefined): string => {
    // "Sin registrar" y no "desconocido": hasta este cambio toda merma manual
    // entraba con usuario_id NULL, así que no es que no sepamos quién es — es
    // que no se guardó (invariante MERMA-I, mig 105).
    if (!usuarioId) return 'Sin registrar'
    return usuarios.find(u => u.id === usuarioId)?.nombre || 'Usuario desconocido'
  }, [usuarios])

  // TODO lo demás —totales, resumen y Excel— se calcula sobre ESTE array: si no,
  // los totales contradicen a la lista.
  const filas: MermaValorizada[] = useMemo(() => {
    return mermas
      .filter(m => {
        if (filtroProducto && String(m.producto_id) !== filtroProducto) return false
        if (filtroMotivo && m.motivo !== filtroMotivo) return false
        return true
      })
      .map(m => valorizarMerma(m, productosPorId.get(String(m.producto_id))))
  }, [mermas, filtroProducto, filtroMotivo, productosPorId])

  const totales = useMemo(() => totalizarMermas(filas), [filas])
  const resumen = useMemo(() => resumenPorMotivo(filas), [filas])
  const motivosUnicos = useMemo(
    () => [...new Set(mermas.map(m => m.motivo))].sort(),
    [mermas],
  )
  const truncado = mermas.length >= LIMITE_MERMAS

  const handleExportar = useCallback(async () => {
    if (filas.length === 0) return
    setExportando(true)
    try {
      const detalle = filas.map(f => ({
        Fecha: fechaCorta(f.created_at),
        Producto: f.productoNombre,
        Código: f.productoCodigo,
        Motivo: labelMotivo(f.motivo),
        Tipo: f.esAjustePromocion ? 'Ajuste de promoción' : 'Pérdida',
        Cantidad: f.cantidad,
        'Costo unitario': f.costoUnitario,
        'Costo total': f.costoTotal,
        'Precio unitario (hoy)': f.precioUnitario,
        'Precio total (hoy)': f.precioTotal,
        'Origen del costo': f.sinCosto
          ? 'Sin costo cargado'
          : f.costoEstimado
            ? 'Estimado al valor actual'
            : 'Congelado al momento',
        Usuario: getUsuarioNombre(f.usuario_id),
        'Stock antes': f.stock_anterior ?? '',
        'Stock después': f.stock_nuevo ?? '',
        Observaciones: f.observaciones || '',
      }))

      const porMotivo = resumen.map(r => ({
        Motivo: labelMotivo(r.motivo),
        Tipo: r.esAjustePromocion ? 'Ajuste de promoción' : 'Pérdida',
        Registros: r.registros,
        Unidades: r.unidades,
        Costo: r.costo,
        'Precio (hoy)': r.precio,
      }))

      // Las aclaraciones viajan en el Excel: sin ellas, el archivo sale del
      // sistema y nadie puede saber por qué el total no es la suma de la
      // columna Costo.
      porMotivo.push(
        { Motivo: '', Tipo: '', Registros: '' as never, Unidades: '' as never, Costo: '' as never, 'Precio (hoy)': '' as never },
        {
          Motivo: 'TOTAL PÉRDIDA (sin ajustes de promoción)',
          Tipo: '',
          Registros: totales.registros - totales.registrosAjustePromocion,
          Unidades: totales.unidades,
          Costo: totales.costoTotal,
          'Precio (hoy)': totales.precioTotal,
        },
        {
          Motivo: 'Ajustes de promoción (no son pérdida)',
          Tipo: '',
          Registros: totales.registrosAjustePromocion,
          Unidades: totales.unidadesAjustePromocion,
          Costo: totales.costoAjustePromocion,
          'Precio (hoy)': '' as never,
        },
      )

      const { createMultiSheetExcel } = await import('../../utils/excel')
      await createMultiSheetExcel(
        [
          { name: 'Detalle', data: detalle, columnWidths: [11, 32, 12, 20, 20, 10, 14, 14, 18, 18, 24, 20, 12, 13, 40] },
          { name: 'Resumen por motivo', data: porMotivo, columnWidths: [38, 20, 11, 11, 14, 14] },
        ],
        `mermas-${desde}_a_${hasta}`,
      )
    } finally {
      setExportando(false)
    }
  }, [filas, resumen, totales, desde, hasta, getUsuarioNombre])

  const inputCls =
    'w-full px-3 py-2 border dark:border-gray-600 rounded-lg text-sm dark:bg-gray-700 dark:text-white'

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-5xl max-h-[90vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-red-100 dark:bg-red-900/30 rounded-lg">
              <TrendingDown className="w-5 h-5 text-red-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">Historial de Mermas</h2>
              <p className="text-sm text-gray-500">Registro de bajas de stock</p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => void handleExportar()}
              disabled={exportando || filas.length === 0}
              className="inline-flex items-center gap-1.5 px-3 py-2 rounded-lg border dark:border-gray-600 text-sm font-medium disabled:opacity-50 dark:text-gray-200"
            >
              <Download className="w-4 h-4" aria-hidden="true" />
              {exportando ? 'Exportando…' : 'Exportar a Excel'}
            </button>
            <button onClick={onClose} aria-label="Cerrar" className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
              <X className="w-5 h-5" />
            </button>
          </div>
        </div>

        {/* Filtros */}
        <div className="p-4 border-b dark:border-gray-700 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
          <div>
            <label htmlFor="mermas-periodo" className="block text-xs font-medium text-gray-500 mb-1">
              <Calendar className="w-3 h-3 inline mr-1" />
              Período
            </label>
            <select
              id="mermas-periodo"
              value={presetId}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => elegirPreset(e.target.value)}
              className={inputCls}
            >
              {presets.map(p => (
                <option key={p.id} value={p.id}>{p.label}</option>
              ))}
              <option value="custom">Personalizado…</option>
            </select>
          </div>

          {presetId === 'custom' && (
            <>
              <div>
                <label htmlFor="mermas-desde" className="block text-xs font-medium text-gray-500 mb-1">Desde</label>
                <input
                  id="mermas-desde"
                  type="date"
                  value={desde}
                  max={hasta}
                  onChange={(e) => setDesde(e.target.value)}
                  className={inputCls}
                />
              </div>
              <div>
                <label htmlFor="mermas-hasta" className="block text-xs font-medium text-gray-500 mb-1">Hasta</label>
                <input
                  id="mermas-hasta"
                  type="date"
                  value={hasta}
                  min={desde}
                  onChange={(e) => setHasta(e.target.value)}
                  className={inputCls}
                />
              </div>
            </>
          )}

          <div>
            <label htmlFor="mermas-producto" className="block text-xs font-medium text-gray-500 mb-1">Producto</label>
            <select
              id="mermas-producto"
              value={filtroProducto}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => setFiltroProducto(e.target.value)}
              className={inputCls}
            >
              <option value="">Todos los productos</option>
              {productos.map(p => (
                <option key={p.id} value={String(p.id)}>{p.nombre}</option>
              ))}
            </select>
          </div>

          <div>
            <label htmlFor="mermas-motivo" className="block text-xs font-medium text-gray-500 mb-1">Motivo</label>
            <select
              id="mermas-motivo"
              value={filtroMotivo}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => setFiltroMotivo(e.target.value)}
              className={inputCls}
            >
              <option value="">Todos los motivos</option>
              {motivosUnicos.map(m => (
                <option key={m} value={m}>{labelMotivo(m)}</option>
              ))}
            </select>
          </div>
        </div>

        {/* Resumen en plata */}
        <div className="p-4 bg-gray-50 dark:bg-gray-900 border-b dark:border-gray-700">
          <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
            <div className="text-center">
              <p className="text-2xl font-bold text-red-600 tabular-nums">{totales.unidades}</p>
              <p className="text-xs text-gray-500">Unidades perdidas</p>
            </div>
            <div className="text-center">
              <p className="text-2xl font-bold text-red-600 tabular-nums">{formatCurrency(totales.costoTotal)}</p>
              <p className="text-xs text-gray-500">Pérdida a costo</p>
            </div>
            <div className="text-center">
              <p className="text-2xl font-bold text-amber-600 tabular-nums">{formatCurrency(totales.precioTotal)}</p>
              <p className="text-xs text-gray-500">A precio de venta de hoy</p>
            </div>
            <div className="text-center">
              <p className="text-2xl font-bold text-gray-600 tabular-nums">{totales.registros}</p>
              <p className="text-xs text-gray-500">Registros</p>
            </div>
          </div>

          <div className="mt-3 space-y-1.5 text-xs">
            {totales.registrosAjustePromocion > 0 && (
              <p className="flex items-start gap-1.5 text-gray-600 dark:text-gray-400">
                <Info className="w-3.5 h-3.5 mt-0.5 shrink-0" aria-hidden="true" />
                <span>
                  {totales.registrosAjustePromocion} registros son{' '}
                  <strong>ajustes de promoción</strong> por {formatCurrency(totales.costoAjustePromocion)} y
                  quedan fuera del total: no son pérdida, son la contrapartida de un regalo ya
                  contabilizado en el pedido. Es el mismo criterio del reporte gerencial.
                </span>
              </p>
            )}
            <p className="flex items-start gap-1.5 text-gray-500">
              <Info className="w-3.5 h-3.5 mt-0.5 shrink-0" aria-hidden="true" />
              <span>
                El precio de venta es el de <strong>hoy</strong>: la base no guarda a cuánto se
                vendía el día de la merma.
              </span>
            </p>
            {totales.filasCostoEstimado > 0 && (
              <p className="flex items-start gap-1.5 text-amber-700 dark:text-amber-400">
                <AlertTriangle className="w-3.5 h-3.5 mt-0.5 shrink-0" aria-hidden="true" />
                <span>
                  {totales.filasCostoEstimado} registros son anteriores a que se guardara el costo
                  del momento: van valuados al <strong>costo actual</strong>.
                </span>
              </p>
            )}
            {totales.filasSinCosto > 0 && (
              <p className="flex items-start gap-1.5 text-amber-700 dark:text-amber-400">
                <AlertTriangle className="w-3.5 h-3.5 mt-0.5 shrink-0" aria-hidden="true" />
                <span>
                  {totales.filasSinCosto} registros son de productos <strong>sin costo cargado</strong>:
                  no suman al total. No es que valgan $0, es que no se sabe.
                </span>
              </p>
            )}
            {truncado && (
              <p className="flex items-start gap-1.5 text-amber-700 dark:text-amber-400">
                <AlertTriangle className="w-3.5 h-3.5 mt-0.5 shrink-0" aria-hidden="true" />
                <span>
                  El período tiene más de {LIMITE_MERMAS} registros y se muestran los{' '}
                  {LIMITE_MERMAS} más recientes. Achicá el rango de fechas para verlos todos.
                </span>
              </p>
            )}
          </div>
        </div>

        {/* Lista */}
        <div className="flex-1 overflow-y-auto p-4">
          {isLoading ? (
            <p className="text-center py-8 text-gray-500">Cargando…</p>
          ) : filas.length === 0 ? (
            <div className="text-center py-8 text-gray-500">
              <Package className="w-12 h-12 mx-auto mb-3 opacity-50" />
              <p>No hay mermas en el período seleccionado</p>
            </div>
          ) : (
            <div className="space-y-3">
              {filas.map(f => (
                <div
                  key={f.id}
                  className="p-4 bg-gray-50 dark:bg-gray-900 rounded-lg border dark:border-gray-700"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="font-medium text-gray-800 dark:text-white truncate">
                        {f.productoNombre}
                      </p>
                      <div className="flex flex-wrap items-center gap-3 mt-1 text-sm text-gray-500">
                        <span className="flex items-center gap-1">
                          <Calendar className="w-3 h-3" />
                          {fechaCorta(f.created_at)}
                        </span>
                        <span className="flex items-center gap-1">
                          <User className="w-3 h-3" />
                          {getUsuarioNombre(f.usuario_id)}
                        </span>
                      </div>
                      {f.observaciones && (
                        <p className="mt-2 text-sm text-gray-600 dark:text-gray-400 flex items-start gap-1">
                          <FileText className="w-3 h-3 mt-0.5 flex-shrink-0" />
                          {f.observaciones}
                        </p>
                      )}
                      <div className="mt-2 flex flex-wrap gap-1.5">
                        {f.esAjustePromocion && (
                          <span className="text-[11px] px-1.5 py-0.5 rounded bg-sky-100 text-sky-800 dark:bg-sky-900/40 dark:text-sky-200">
                            Ajuste de promoción · fuera del total
                          </span>
                        )}
                        {f.costoEstimado && (
                          <span className="text-[11px] px-1.5 py-0.5 rounded bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200">
                            Costo estimado al valor actual
                          </span>
                        )}
                        {f.sinCosto && (
                          <span className="text-[11px] px-1.5 py-0.5 rounded bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200">
                            Sin costo cargado
                          </span>
                        )}
                      </div>
                    </div>

                    <div className="text-right shrink-0">
                      {/* Las reversiones vienen con cantidad NEGATIVA: el signo
                          ya está en el número, ponerle otro imprimía "--3". */}
                      <p className={`text-lg font-bold tabular-nums ${f.cantidad < 0 ? 'text-emerald-600' : 'text-red-600'}`}>
                        {f.cantidad > 0 ? `-${f.cantidad}` : `+${Math.abs(f.cantidad)}`}
                      </p>
                      <p className="text-xs text-gray-500">{labelMotivo(f.motivo)}</p>
                      <p className="text-sm font-medium text-gray-700 dark:text-gray-300 tabular-nums mt-1">
                        {f.sinCosto ? 's/costo' : formatCurrency(f.costoTotal)}
                      </p>
                      {!f.sinPrecio && (
                        <p className="text-xs text-gray-400 tabular-nums">
                          {formatCurrency(f.precioTotal)} a precio
                        </p>
                      )}
                      <p className="text-xs text-gray-400 mt-1">
                        {f.stock_anterior} -&gt; {f.stock_nuevo}
                      </p>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="p-4 border-t dark:border-gray-700">
          <button
            onClick={onClose}
            className="w-full px-4 py-2 bg-gray-100 dark:bg-gray-700 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-lg transition-colors dark:text-gray-200"
          >
            Cerrar
          </button>
        </div>
      </div>
    </div>
  )
}
