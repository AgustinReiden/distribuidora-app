/**
 * ModalCombo
 *
 * Crear/editar un combo (#1191): varios productos que ya existen, comprados
 * juntos, a un precio fijo. No hay un producto "combo". Cada "lugar" es un
 * casillero con una cantidad; varios productos en el mismo lugar son
 * alternativas (como un fardo surtido).
 *
 * Las reglas de validación espejan las de `guardar_combo` (migración de los
 * combos): se muestran acá, antes de guardar, y el server las repite.
 */
import { useMemo, useState } from 'react'
import { z } from 'zod'
import { AlertTriangle, Plus, Search, Trash2, X } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { fechaLocalISO, formatPrecio } from '../../utils/formatters'
import type { ProductoDB } from '../../types'
import type { ComboAdmin, ComboFormInput } from '../../hooks/queries/useCombosQuery'

export interface ModalComboProps {
  combo?: ComboAdmin | null
  productos: ProductoDB[]
  onSave: (input: ComboFormInput) => Promise<void>
  onClose: () => void
  guardando?: boolean
}

const MAX_LUGARES = 20
const MAX_CANTIDAD_LUGAR = 1000
const MIN_UNIDADES_COMBO = 2

const MSG_CANTIDAD = `La cantidad de cada lugar tiene que ser un entero entre 1 y ${MAX_CANTIDAD_LUGAR}`

// Co-locado a propósito (CLAUDE.md): un modal lazy no valida contra un schema de
// un chunk compartido que un bundle viejo del PWA podría tener desincronizado.
// Los ids de producto son strings (llegan como number en runtime: se normalizan
// al armar el valor, antes de validar).
const comboSchema = z
  .object({
    nombre: z.string().trim().min(1, { message: 'Poné un nombre para el combo' }),
    precio: z
      .number({ error: 'Poné el precio del combo (mayor a $0)' })
      .positive({ message: 'El precio del combo tiene que ser mayor a $0' })
      .refine(n => Math.abs(n * 100 - Math.round(n * 100)) < 1e-6, {
        message: 'El precio admite hasta 2 decimales',
      }),
    fechaInicio: z.string().min(1, { message: 'Elegí la fecha de inicio' }),
    fechaFin: z.string().nullable(),
    prioridad: z
      .number({ error: 'La prioridad tiene que ser un número entero' })
      .int({ message: 'La prioridad tiene que ser un número entero' }),
    topeCombos: z
      .number({ error: 'El tope de combos tiene que ser un entero mayor a 0' })
      .int({ message: 'El tope de combos tiene que ser un entero mayor a 0' })
      .positive({ message: 'El tope de combos tiene que ser un entero mayor a 0' })
      .nullable(),
    productoAMoverId: z.string().nullable(),
    componentes: z
      .array(
        z.object({
          cantidad: z
            .number({ error: MSG_CANTIDAD })
            .int({ message: MSG_CANTIDAD })
            .min(1, { message: MSG_CANTIDAD })
            .max(MAX_CANTIDAD_LUGAR, { message: MSG_CANTIDAD }),
          productos: z.array(z.string()).min(1, { message: 'Cada lugar necesita al menos un producto' }),
        })
      )
      .min(1, { message: 'Agregá al menos un lugar al combo' })
      .max(MAX_LUGARES, { message: `Un combo admite hasta ${MAX_LUGARES} lugares` }),
  })
  .superRefine((v, ctx) => {
    if (v.fechaFin && v.fechaInicio && v.fechaFin < v.fechaInicio) {
      ctx.addIssue({ code: 'custom', message: 'La fecha de fin no puede ser anterior a la de inicio' })
    }
    const todos = v.componentes.flatMap(c => c.productos)
    if (new Set(todos).size !== todos.length) {
      ctx.addIssue({ code: 'custom', message: 'Un producto no puede estar dos veces en el combo' })
    }
    const unidades = v.componentes.reduce((acc, c) => acc + (Number.isFinite(c.cantidad) ? c.cantidad : 0), 0)
    if (unidades < MIN_UNIDADES_COMBO && v.componentes.every(c => Number.isFinite(c.cantidad))) {
      ctx.addIssue({
        code: 'custom',
        message: `El combo tiene que sumar al menos ${MIN_UNIDADES_COMBO} unidades en total`,
      })
    }
    if (v.productoAMoverId && !todos.includes(v.productoAMoverId)) {
      ctx.addIssue({ code: 'custom', message: 'El producto a mover tiene que ser uno de los productos del combo' })
    }
  })

interface LugarForm {
  /** Clave estable para React (el índice cambia al quitar un lugar). */
  key: number
  cantidad: string
  productos: string[]
}

/** Número de un campo de texto, "" => NaN. El precio acepta "1.234,56" y "12,5". */
function aNumero(raw: string): number {
  const t = raw.trim()
  if (t === '') return NaN
  const normalizado = t.includes(',') ? t.replace(/\./g, '').replace(',', '.') : t
  return /^-?\d*\.?\d+$/.test(normalizado) ? Number(normalizado) : NaN
}

const inputCls =
  'w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none text-sm'
const labelCls = 'block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1'
const ayudaCls = 'text-xs text-gray-500 dark:text-gray-400 mt-1'

export default function ModalCombo({
  combo = null,
  productos,
  onSave,
  onClose,
  guardando = false,
}: ModalComboProps) {
  const isEditing = !!combo

  const [nombre, setNombre] = useState(combo?.nombre ?? '')
  const [precio, setPrecio] = useState(combo ? String(combo.precio).replace('.', ',') : '')
  const [fechaInicio, setFechaInicio] = useState(combo?.fechaInicio ?? fechaLocalISO())
  const [fechaFin, setFechaFin] = useState(combo?.fechaFin ?? '')
  const [combinaEscalas, setCombinaEscalas] = useState(combo?.combinaEscalas ?? false)
  const [prioridad, setPrioridad] = useState(String(combo?.prioridad ?? 0))
  const [topeCombos, setTopeCombos] = useState(combo?.topeCombos != null ? String(combo.topeCombos) : '')
  const [productoAMoverId, setProductoAMoverId] = useState(combo?.productoAMoverId ?? '')
  const [lugares, setLugares] = useState<LugarForm[]>(() =>
    combo && combo.componentes.length > 0
      ? combo.componentes.map((c, i) => ({ key: i, cantidad: String(c.cantidad), productos: [...c.productos] }))
      : [{ key: 0, cantidad: '1', productos: [] }]
  )
  const [siguienteKey, setSiguienteKey] = useState(() => Math.max(1, combo?.componentes.length ?? 0))
  const [busquedas, setBusquedas] = useState<Record<number, string>>({})
  const [errores, setErrores] = useState<string[]>([])
  const [errorServidor, setErrorServidor] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  const productoPorId = useMemo(() => {
    const m = new Map<string, ProductoDB>()
    productos.forEach(p => m.set(String(p.id), p))
    return m
  }, [productos])

  const nombreDe = (id: string): string => productoPorId.get(id)?.nombre ?? `Producto #${id}`

  // Dónde está cada producto elegido, para avisar el que se repite entre lugares.
  const usos = useMemo(() => {
    const m = new Map<string, number>()
    lugares.forEach(l => l.productos.forEach(id => m.set(id, (m.get(id) ?? 0) + 1)))
    return m
  }, [lugares])

  // Productos del combo (sin repetir), para elegir el "producto a mover".
  const productosDelCombo = useMemo(() => Array.from(usos.keys()), [usos])

  // Vista previa: "sin combo" es lo que costarían las mismas unidades comprando
  // en cada lugar el producto más caro (el mejor caso para el cliente que elige
  // la alternativa cara; si el combo le gana a eso, le gana siempre).
  const sinCombo = useMemo(() => {
    let total = 0
    for (const l of lugares) {
      const cant = aNumero(l.cantidad)
      if (!Number.isFinite(cant) || cant <= 0 || l.productos.length === 0) continue
      const masCaro = Math.max(...l.productos.map(id => Number(productoPorId.get(id)?.precio ?? 0)))
      total += cant * masCaro
    }
    return total
  }, [lugares, productoPorId])

  const precioNum = aNumero(precio)
  const hayPrecio = Number.isFinite(precioNum) && precioNum > 0
  const noConviene = hayPrecio && sinCombo > 0 && precioNum >= sinCombo
  const descuentoPct = hayPrecio && sinCombo > 0 && !noConviene ? (1 - precioNum / sinCombo) * 100 : null

  const actualizarLugar = (key: number, cambio: Partial<LugarForm>) =>
    setLugares(prev => prev.map(l => (l.key === key ? { ...l, ...cambio } : l)))

  const agregarLugar = () => {
    setLugares(prev => [...prev, { key: siguienteKey, cantidad: '1', productos: [] }])
    setSiguienteKey(k => k + 1)
  }

  const quitarLugar = (key: number) => setLugares(prev => prev.filter(l => l.key !== key))

  const agregarProducto = (key: number, id: string) => {
    const lugar = lugares.find(l => l.key === key)
    if (!lugar || lugar.productos.includes(id)) return
    actualizarLugar(key, { productos: [...lugar.productos, id] })
    setBusquedas(prev => ({ ...prev, [key]: '' }))
  }

  const quitarProducto = (key: number, id: string) => {
    const lugar = lugares.find(l => l.key === key)
    if (!lugar) return
    actualizarLugar(key, { productos: lugar.productos.filter(p => p !== id) })
  }

  const resultadosDe = (key: number): ProductoDB[] => {
    const q = (busquedas[key] ?? '').trim().toLowerCase()
    if (!q) return []
    const lugar = lugares.find(l => l.key === key)
    return productos
      .filter(p => p.activo !== false)
      .filter(p => !lugar?.productos.includes(String(p.id)))
      .filter(p => p.nombre.toLowerCase().includes(q) || (p.codigo ?? '').toLowerCase().includes(q))
      .slice(0, 30)
  }

  const handleSubmit = async () => {
    setErrorServidor(null)
    const tope = topeCombos.trim() === '' ? null : aNumero(topeCombos)
    const candidato = {
      nombre,
      precio: precioNum,
      fechaInicio,
      fechaFin: fechaFin || null,
      prioridad: aNumero(prioridad),
      topeCombos: tope,
      productoAMoverId: productoAMoverId || null,
      componentes: lugares.map(l => ({ cantidad: aNumero(l.cantidad), productos: l.productos })),
    }
    const r = comboSchema.safeParse(candidato)
    if (!r.success) {
      setErrores(Array.from(new Set(r.error.issues.map(i => i.message))))
      return
    }
    setErrores([])

    const v = r.data
    const input: ComboFormInput = {
      id: combo?.id,
      nombre: v.nombre,
      precio: v.precio,
      fechaInicio: v.fechaInicio,
      fechaFin: v.fechaFin,
      // Editar no reactiva ni desactiva: eso es del botón de la tarjeta.
      activo: combo?.activo ?? true,
      combinaEscalas,
      prioridad: v.prioridad,
      topeCombos: v.topeCombos,
      productoAMoverId: v.productoAMoverId,
      componentes: v.componentes.map(c => ({ cantidad: c.cantidad, productos: c.productos })),
    }
    setSaving(true)
    try {
      await onSave(input)
    } catch (err) {
      setErrorServidor(err instanceof Error ? err.message : 'No se pudo guardar el combo')
    } finally {
      setSaving(false)
    }
  }

  const ocupado = saving || guardando

  return (
    <ModalBase
      onClose={onClose}
      title={isEditing ? 'Editar combo' : 'Nuevo combo'}
      description="Varios productos comprados juntos a un precio fijo"
      maxWidth="max-w-2xl"
    >
      <div className="px-5 py-4 space-y-5">
        {/* Nombre */}
        <div>
          <label htmlFor="combo-nombre" className={labelCls}>Nombre</label>
          <input
            id="combo-nombre"
            type="text"
            value={nombre}
            onChange={e => setNombre(e.target.value)}
            placeholder="Ej: Combo 2 Coca + Fernet"
            className={inputCls}
          />
        </div>

        {/* Precio y vigencia */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <div>
            <label htmlFor="combo-precio" className={labelCls}>Precio del combo</label>
            <input
              id="combo-precio"
              type="text"
              inputMode="decimal"
              value={precio}
              onChange={e => setPrecio(e.target.value)}
              placeholder="Ej: 15000"
              className={inputCls}
            />
          </div>
          <div>
            <label htmlFor="combo-fecha-inicio" className={labelCls}>Fecha inicio</label>
            <input
              id="combo-fecha-inicio"
              type="date"
              value={fechaInicio}
              onChange={e => setFechaInicio(e.target.value)}
              className={inputCls}
            />
          </div>
          <div>
            <label htmlFor="combo-fecha-fin" className={labelCls}>Fecha fin (opcional)</label>
            <input
              id="combo-fecha-fin"
              type="date"
              value={fechaFin}
              onChange={e => setFechaFin(e.target.value)}
              className={inputCls}
            />
          </div>
        </div>

        {/* Lugares */}
        <div>
          <div className="flex items-center justify-between mb-1">
            <h3 className="text-sm font-semibold text-gray-800 dark:text-gray-200">
              Lugares del combo ({lugares.length})
            </h3>
            <Button
              type="button"
              variant="secondary"
              size="sm"
              onClick={agregarLugar}
              disabled={lugares.length >= MAX_LUGARES}
            >
              <Plus className="w-4 h-4" />
              Agregar lugar
            </Button>
          </div>
          <p className={`${ayudaCls} mb-3`}>
            Un lugar es un casillero con una cantidad. Si ponés varios productos en el mismo lugar son
            alternativas: el cliente puede elegir cualquiera (ej: «cualquier Coca 2,25»), como en un fardo surtido.
          </p>

          <div className="space-y-3">
            {lugares.map((lugar, idx) => {
              const resultados = resultadosDe(lugar.key)
              const busqueda = (busquedas[lugar.key] ?? '').trim()
              return (
                <div
                  key={lugar.key}
                  className="p-3 border rounded-lg dark:border-gray-600 bg-gray-50 dark:bg-gray-900/30 space-y-2"
                >
                  <div className="flex items-end gap-3">
                    <div className="w-28">
                      <label htmlFor={`combo-cantidad-${lugar.key}`} className="block text-xs font-medium text-gray-600 dark:text-gray-400 mb-1">
                        Cantidad (lugar {idx + 1})
                      </label>
                      <input
                        id={`combo-cantidad-${lugar.key}`}
                        type="text"
                        inputMode="numeric"
                        value={lugar.cantidad}
                        onChange={e => actualizarLugar(lugar.key, { cantidad: e.target.value })}
                        className={inputCls}
                      />
                    </div>
                    <div className="relative flex-1">
                      <Search className="absolute left-3 top-2.5 w-4 h-4 text-gray-400" />
                      <input
                        type="text"
                        value={busquedas[lugar.key] ?? ''}
                        onChange={e => setBusquedas(prev => ({ ...prev, [lugar.key]: e.target.value }))}
                        placeholder="Buscar producto para este lugar..."
                        aria-label={`Buscar producto del lugar ${idx + 1}`}
                        className={`${inputCls} pl-9`}
                      />
                    </div>
                    <Button
                      type="button"
                      variant="ghost"
                      size="iconSm"
                      onClick={() => quitarLugar(lugar.key)}
                      aria-label={`Quitar lugar ${idx + 1}`}
                      className="hover:bg-red-50 dark:hover:bg-red-900/20"
                    >
                      <Trash2 className="w-4 h-4 text-red-500" />
                    </Button>
                  </div>

                  {busqueda && (
                    <div className="max-h-40 overflow-y-auto border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700 bg-white dark:bg-gray-700">
                      {resultados.map(prod => (
                        <button
                          key={prod.id}
                          type="button"
                          onClick={() => agregarProducto(lugar.key, String(prod.id))}
                          className="w-full text-left flex items-center gap-2 px-3 py-2 hover:bg-purple-50 dark:hover:bg-purple-900/20 text-sm"
                        >
                          <span className="dark:text-white truncate">{prod.nombre}</span>
                          {usos.has(String(prod.id)) && (
                            <span className="text-[11px] text-amber-600 dark:text-amber-400 shrink-0">ya está en otro lugar</span>
                          )}
                          <span className="text-xs text-gray-400 ml-auto shrink-0">{formatPrecio(prod.precio)}</span>
                        </button>
                      ))}
                      {resultados.length === 0 && (
                        <p className="text-sm text-gray-400 px-3 py-3 text-center">Sin resultados</p>
                      )}
                    </div>
                  )}

                  {lugar.productos.length === 0 ? (
                    <p className="text-xs text-gray-400">Todavía no hay productos en este lugar.</p>
                  ) : (
                    <div className="flex flex-wrap gap-2">
                      {lugar.productos.map(id => {
                        const prod = productoPorId.get(id)
                        const inactivo = prod?.activo === false
                        return (
                          <span
                            key={id}
                            className={`inline-flex items-center gap-1 text-xs pl-2.5 pr-1 py-1 rounded-full ${
                              inactivo
                                ? 'bg-gray-200 text-gray-600 dark:bg-gray-600 dark:text-gray-300'
                                : 'bg-blue-50 text-blue-700 dark:bg-blue-900/20 dark:text-blue-300'
                            }`}
                          >
                            {nombreDe(id)}
                            {inactivo && <span className="italic">(inactivo)</span>}
                            {(usos.get(id) ?? 0) > 1 && (
                              <span className="text-amber-600 dark:text-amber-400">(repetido)</span>
                            )}
                            <button
                              type="button"
                              onClick={() => quitarProducto(lugar.key, id)}
                              aria-label={`Quitar ${nombreDe(id)}`}
                              className="p-0.5 rounded-full hover:bg-black/10 dark:hover:bg-white/10"
                            >
                              <X className="w-3 h-3" />
                            </button>
                          </span>
                        )
                      })}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        </div>

        {/* Vista previa */}
        <div
          className="p-3 rounded-lg border border-purple-200 dark:border-purple-800 bg-purple-50 dark:bg-purple-900/20 space-y-1"
          aria-live="polite"
        >
          <p className="text-sm font-medium text-purple-700 dark:text-purple-300" data-testid="combo-sin-combo">
            Sin combo: {formatPrecio(sinCombo)}
          </p>
          {descuentoPct !== null && (
            <p className="text-sm font-medium text-emerald-700 dark:text-emerald-300" data-testid="combo-descuento">
              Descuento: {descuentoPct.toLocaleString('es-AR', { maximumFractionDigits: 1 })}%
            </p>
          )}
          {noConviene && (
            <p
              className="flex items-start gap-1.5 text-sm text-amber-800 dark:text-amber-200"
              data-testid="combo-no-conviene"
            >
              <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
              Con este precio el combo no conviene: no se va a aplicar
            </p>
          )}
          <p className="text-[11px] text-purple-600 dark:text-purple-400">
            «Sin combo» suma, por cada lugar, la cantidad por el precio de lista del producto más caro del lugar.
          </p>
        </div>

        {/* Escalas */}
        <div>
          <label className="flex items-start gap-2 cursor-pointer">
            <input
              type="checkbox"
              checked={combinaEscalas}
              onChange={e => setCombinaEscalas(e.target.checked)}
              className="mt-0.5 rounded border-gray-300 text-purple-600 focus:ring-purple-500"
            />
            <span className="text-sm font-medium text-gray-700 dark:text-gray-300">
              Se combina con escalas mayoristas
            </span>
          </label>
          <p className={`${ayudaCls} ml-6`}>
            Apagado: las unidades del combo no toman precio mayorista ni cuentan para su mínimo. Prendido: cuentan, y
            el descuento del combo se suma al precio mayorista.
          </p>
        </div>

        {/* Opciones */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div>
            <label htmlFor="combo-prioridad" className={labelCls}>Prioridad</label>
            <input
              id="combo-prioridad"
              type="text"
              inputMode="numeric"
              value={prioridad}
              onChange={e => setPrioridad(e.target.value)}
              className={inputCls}
            />
            <p className={ayudaCls}>
              Si dos combos comparten un producto, gana el de mayor prioridad; con la misma prioridad, el que más
              ahorra.
            </p>
          </div>
          <div>
            <label htmlFor="combo-tope" className={labelCls}>Tope de combos (opcional)</label>
            <input
              id="combo-tope"
              type="text"
              inputMode="numeric"
              value={topeCombos}
              onChange={e => setTopeCombos(e.target.value)}
              placeholder="Sin tope"
              className={inputCls}
            />
            <p className={ayudaCls}>Máximo de combos que se venden en total: sirve para liquidar una cantidad.</p>
          </div>
        </div>

        <div>
          <label htmlFor="combo-a-mover" className={labelCls}>Producto a mover (opcional)</label>
          <select
            id="combo-a-mover"
            value={productoAMoverId}
            onChange={e => setProductoAMoverId(e.target.value)}
            className={inputCls}
          >
            <option value="">Ninguno</option>
            {productosDelCombo.map(id => (
              <option key={id} value={id}>{nombreDe(id)}</option>
            ))}
            {productoAMoverId && !productosDelCombo.includes(productoAMoverId) && (
              <option value={productoAMoverId}>{nombreDe(productoAMoverId)} (ya no está en el combo)</option>
            )}
          </select>
          <p className={ayudaCls}>El producto que el combo quiere hacer rotar (se usa después en el análisis de rotación).</p>
        </div>

        {errores.length > 0 && (
          <div role="alert" className="p-3 bg-red-50 dark:bg-red-900/20 text-red-600 dark:text-red-400 text-sm rounded-lg">
            <ul className="space-y-0.5">
              {errores.map(msg => (
                <li key={msg}>{msg}</li>
              ))}
            </ul>
          </div>
        )}
        {errorServidor && (
          <div role="alert" className="p-3 bg-red-50 dark:bg-red-900/20 text-red-600 dark:text-red-400 text-sm rounded-lg">
            {errorServidor}
          </div>
        )}

        <div className="flex justify-end gap-2 pt-2 border-t dark:border-gray-700">
          <Button type="button" onClick={onClose} variant="ghost" size="md">
            Cancelar
          </Button>
          <Button type="button" onClick={handleSubmit} variant="primary" size="md" disabled={ocupado}>
            {ocupado ? 'Guardando...' : isEditing ? 'Actualizar' : 'Crear combo'}
          </Button>
        </div>
      </div>
    </ModalBase>
  )
}
