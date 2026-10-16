/**
 * VistaCombos
 *
 * Vista admin para gestionar combos (#1191): productos que ya existen,
 * comprados juntos, a un precio fijo. No se borran: se desactivan, porque
 * un pedido viejo puede haber vendido el combo.
 */
import React, { useMemo, useState } from 'react'
import { Plus, Edit2, ToggleLeft, ToggleRight, Boxes, Filter, Layers, AlertTriangle, AlertCircle } from 'lucide-react'
import { Button } from '../ui/Button'
import { fechaLocalISO, formatPrecio } from '../../utils/formatters'
import type { ComboAdmin } from '../../hooks/queries/useCombosQuery'
import { evaluarCombo, type ProductoParaAlertas, type UmbralesCombo } from '../../utils/comboAlertas'
import { resolverLugares, type ProductoCatalogo } from '../../utils/comboCategorias'
import { combosTapados, ordenableDe } from '../../utils/comboOrden'

type FiltroEstado = 'vigentes' | 'todas' | 'inactivas'

export interface VistaCombosProps {
  combos: ComboAdmin[]
  loading: boolean
  /** Map producto_id -> nombre, para el resumen "2× Coca + 1× Fernet". */
  productoNombres: Map<string, string>
  /** Map categoria_id -> nombre ("Rubro › Subrubro"), para los lugares por categoría (#1213). */
  categoriaNombres?: Map<string, string>
  onNuevoCombo: () => void
  onEditarCombo: (combo: ComboAdmin) => void
  onToggleActivo: (combo: ComboAdmin) => void
  /**
   * Alertas (#1194): los productos con precio (y costo, si el rol los ve), los
   * topes de la sucursal y si se ven los costos. Sin `productos` no se evalúa.
   */
  productos?: ReadonlyMap<string, ProductoParaAlertas>
  umbrales?: UmbralesCombo
  verCostos?: boolean
}

const pct = (n: number): string => `${n.toLocaleString('es-AR', { maximumFractionDigits: 1 })}%`

function formatFecha(fecha: string): string {
  return new Date(fecha + 'T12:00:00').toLocaleDateString('es-AR', { day: '2-digit', month: 'short', year: 'numeric' })
}

function esVigente(combo: ComboAdmin): boolean {
  if (!combo.activo) return false
  const hoy = fechaLocalISO()
  if (combo.fechaInicio > hoy) return false
  if (combo.fechaFin && combo.fechaFin < hoy) return false
  return true
}

export default function VistaCombos({
  combos,
  loading,
  productoNombres,
  onNuevoCombo,
  onEditarCombo,
  onToggleActivo,
  productos,
  categoriaNombres,
  umbrales = { margenMinimoPct: 10, descuentoMaximoPct: 30 },
  verCostos = false,
}: VistaCombosProps): React.ReactElement {
  const [filtro, setFiltro] = useState<FiltroEstado>('vigentes')

  const nombreDe = (id: string): string => productoNombres.get(String(id)) || `Producto #${id}`
  const nombreCategoria = (id: string): string => categoriaNombres?.get(String(id)) ?? 'Categoría eliminada'

  // Cada lugar es "cantidad× alternativa o alternativa", los lugares van con "+".
  // Una categoría va entre corchetes: entra todo lo que tenga.
  const resumen = (combo: ComboAdmin): string =>
    combo.componentes
      .map(c => `${c.cantidad}× ${[...c.categorias.map(id => `[${nombreCategoria(id)}]`), ...c.sueltos.map(nombreDe)].join(' o ')}`)
      .join(' + ')

  // Lo que cada combo vende hoy (#1213): las categorías resueltas contra el
  // catálogo. Sin catálogo no hay resolución ni avisos.
  const catalogo = useMemo(
    () => (productos ? ([...productos.values()] as unknown as ProductoCatalogo[]) : null),
    [productos],
  )
  const resueltosPorCombo = useMemo(
    () => new Map(catalogo ? combos.map(c => [c.id, resolverLugares(c.componentes, catalogo)]) : []),
    [combos, catalogo],
  )
  // El que nunca se arma porque otro de arriba le gana siempre.
  const tapadoPor = useMemo(() => {
    const m = new Map<string, string>()
    if (!catalogo) return m
    for (const t of combosTapados(combos.map(c => ordenableDe(c, catalogo)), fechaLocalISO())) {
      if (!m.has(t.abajo)) m.set(t.abajo, t.arriba)
    }
    return m
  }, [combos, catalogo])
  const nombreCombo = (id: string) => combos.find(c => c.id === id)?.nombre ?? `Combo #${id}`

  const filtrados = useMemo(() => {
    if (filtro === 'todas') return combos
    if (filtro === 'inactivas') return combos.filter(c => !esVigente(c))
    return combos.filter(c => esVigente(c))
  }, [combos, filtro])

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <div className="w-8 h-8 border-4 border-purple-600 border-t-transparent rounded-full animate-spin" />
      </div>
    )
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex justify-between items-center flex-wrap gap-3">
        <div>
          <h1 className="text-2xl font-bold dark:text-white">Combos</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
            Varios productos comprados juntos a un precio fijo
          </p>
        </div>
        <Button onClick={onNuevoCombo} variant="primary" size="md">
          <Plus className="w-4 h-4" />
          Nuevo combo
        </Button>
      </div>

      {/* Filtros de estado */}
      <div className="flex items-center gap-2 flex-wrap">
        <Filter className="w-4 h-4 text-gray-400" />
        {(['vigentes', 'todas', 'inactivas'] as FiltroEstado[]).map(f => (
          <Button
            key={f}
            type="button"
            size="sm"
            variant={filtro === f ? 'primary' : 'secondary'}
            aria-pressed={filtro === f}
            onClick={() => setFiltro(f)}
            className="rounded-full"
          >
            {f === 'vigentes' ? 'Vigentes' : f === 'todas' ? 'Todas' : 'Inactivos / vencidos'}
          </Button>
        ))}
        <span className="text-xs text-gray-500 ml-auto">{filtrados.length} / {combos.length}</span>
      </div>

      {/* Lista */}
      {filtrados.length === 0 ? (
        <div className="text-center py-16 bg-white dark:bg-gray-800 rounded-xl border dark:border-gray-700">
          <Boxes className="w-12 h-12 text-gray-300 mx-auto mb-4" />
          <h3 className="text-lg font-medium text-gray-500 dark:text-gray-400">
            {combos.length === 0 ? 'Sin combos' : 'Ningún combo en este filtro'}
          </h3>
          <p className="text-sm text-gray-400 dark:text-gray-500 mt-1">
            {combos.length === 0
              ? 'Armá un combo para vender varios productos juntos a un precio fijo'
              : 'Probá con otro filtro para ver el resto'}
          </p>
          {combos.length === 0 && (
            <Button onClick={onNuevoCombo} variant="primary" size="md" className="mt-4">
              Nuevo combo
            </Button>
          )}
        </div>
      ) : (
        <div className="grid gap-4">
          {filtrados.map(combo => {
            const vigente = esVigente(combo)
            const lugares = resueltosPorCombo.get(combo.id)
            const ev = productos && lugares
              ? evaluarCombo({ ...combo, componentes: lugares }, productos, umbrales, verCostos)
              : null
            const avisos: string[] = []
            if (lugares?.some(l => l.productos.length === 0)) {
              avisos.push('Un lugar se quedó sin productos activos: el combo no se ofrece en los pedidos')
            }
            if (lugares && combo.productoAMoverId && !lugares.some(l => l.productos.includes(combo.productoAMoverId as string))) {
              avisos.push(`El producto a mover (${nombreDe(combo.productoAMoverId)}) ya no está en el combo`)
            }
            const tapa = tapadoPor.get(combo.id)
            if (tapa) {
              avisos.push(`Nunca se arma: «${nombreCombo(tapa)}» le gana siempre. Cambiá el orden desde Editar`)
            }
            return (
              <div
                key={combo.id}
                className={`bg-white dark:bg-gray-800 rounded-xl border dark:border-gray-700 p-5 ${
                  !combo.activo ? 'opacity-60' : ''
                }`}
              >
                <div className="flex justify-between items-start gap-3">
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <h3 className="text-lg font-semibold dark:text-white">{combo.nombre}</h3>
                      {vigente ? (
                        <span className="text-xs px-2 py-0.5 bg-green-100 text-green-700 rounded-full font-medium">
                          Vigente
                        </span>
                      ) : !combo.activo ? (
                        <span className="text-xs px-2 py-0.5 bg-gray-200 dark:bg-gray-600 text-gray-600 dark:text-gray-300 rounded-full">
                          Inactivo
                        </span>
                      ) : (
                        <span className="text-xs px-2 py-0.5 bg-yellow-100 text-yellow-700 rounded-full">
                          Fuera de rango
                        </span>
                      )}
                      {combo.combinaEscalas && (
                        <span className="inline-flex items-center gap-1 text-xs px-2 py-0.5 bg-purple-100 text-purple-700 dark:bg-purple-900/30 dark:text-purple-300 rounded-full font-medium">
                          <Layers className="w-3 h-3" />
                          Se combina con escalas
                        </span>
                      )}
                      {combo.topeCombos != null && (
                        <span className="text-xs px-2 py-0.5 bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300 rounded-full font-medium">
                          Tope: {combo.topeCombos} {combo.topeCombos === 1 ? 'combo' : 'combos'}
                        </span>
                      )}
                    </div>
                    <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
                      {formatFecha(combo.fechaInicio)}
                      {combo.fechaFin ? ` — ${formatFecha(combo.fechaFin)}` : ' — Sin fecha fin'}
                    </p>
                  </div>
                  <div className="flex items-center gap-1 shrink-0">
                    <Button
                      onClick={() => onToggleActivo(combo)}
                      variant="ghost"
                      size="iconSm"
                      title={combo.activo ? 'Desactivar' : 'Activar'}
                      aria-label={`${combo.activo ? 'Desactivar' : 'Activar'} ${combo.nombre}`}
                    >
                      {combo.activo ? (
                        <ToggleRight className="w-5 h-5 text-green-600" />
                      ) : (
                        <ToggleLeft className="w-5 h-5 text-gray-400" />
                      )}
                    </Button>
                    <Button
                      onClick={() => onEditarCombo(combo)}
                      variant="ghost"
                      size="iconSm"
                      title="Editar"
                      aria-label={`Editar ${combo.nombre}`}
                    >
                      <Edit2 className="w-4 h-4 text-blue-600" />
                    </Button>
                  </div>
                </div>

                <div className="mt-3 px-3 py-2 bg-purple-50 dark:bg-purple-900/20 border border-purple-200 dark:border-purple-800 rounded-lg flex items-center justify-between gap-3 flex-wrap">
                  <p className="text-sm font-medium text-purple-700 dark:text-purple-300">{resumen(combo)}</p>
                  <p className="text-sm font-bold text-purple-800 dark:text-purple-200 tabular-nums">
                    {formatPrecio(combo.precio)}
                  </p>
                </div>

                {avisos.length > 0 && (
                  <div className="mt-2 space-y-1" data-testid={`combo-avisos-${combo.id}`}>
                    {avisos.map(texto => (
                      <p
                        key={texto}
                        className="flex items-start gap-1.5 text-xs px-2 py-1 rounded-lg bg-amber-50 text-amber-800 dark:bg-amber-900/20 dark:text-amber-300"
                      >
                        <AlertTriangle className="w-3.5 h-3.5 mt-px shrink-0" aria-hidden="true" />
                        {texto}
                      </p>
                    ))}
                  </div>
                )}

                {ev && (
                  <div className="mt-2 space-y-1" data-testid={`combo-evaluacion-${combo.id}`}>
                    {(ev.descuentoPct !== null || ev.margenPct !== null) && (
                      <p className="text-xs text-gray-600 dark:text-gray-400">
                        Hoy equivale a{' '}
                        {ev.descuentoPct !== null ? `${pct(ev.descuentoPct)} de descuento` : 'ningún descuento'}
                        {ev.margenPct !== null && <>, margen {pct(ev.margenPct)}</>}
                      </p>
                    )}
                    {ev.alertas.map(a => (
                      <p
                        key={a.tipo}
                        className={`flex items-start gap-1.5 text-xs px-2 py-1 rounded-lg ${
                          a.severidad === 'critical'
                            ? 'bg-red-50 text-red-700 dark:bg-red-900/20 dark:text-red-300'
                            : 'bg-amber-50 text-amber-800 dark:bg-amber-900/20 dark:text-amber-300'
                        }`}
                      >
                        {a.severidad === 'critical'
                          ? <AlertCircle className="w-3.5 h-3.5 mt-px shrink-0" aria-hidden="true" />
                          : <AlertTriangle className="w-3.5 h-3.5 mt-px shrink-0" aria-hidden="true" />}
                        {a.texto}
                      </p>
                    ))}
                  </div>
                )}
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
