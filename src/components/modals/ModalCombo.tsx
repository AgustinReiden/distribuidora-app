/**
 * ModalCombo
 *
 * Crear/editar un combo (#1191): varios productos que ya existen, comprados
 * juntos, a un precio fijo. No hay un producto "combo". Cada "lugar" es un
 * casillero con una cantidad; varios productos en el mismo lugar son
 * alternativas (como un fardo surtido).
 *
 * Desde #1213 un lugar se arma con una lista de casillas, y puede llevar
 * categorías o subcategorías enteras además de productos sueltos. La categoría
 * es viva: lo que el combo vende es lo que la categoría tiene hoy. Y la
 * prioridad ya no es un número: el formulario muestra con qué combos compite
 * éste y en qué orden, y se mueve con flechas (`src/utils/comboOrden.ts`).
 *
 * Las reglas de validación espejan las de `guardar_combo`: se muestran acá,
 * antes de guardar, y el server las repite.
 */
import { useMemo, useState } from 'react'
import { z } from 'zod'
import { AlertTriangle, ArrowDown, ArrowUp, Check, Plus, Search, Tag, Trash2, X } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { fechaLocalISO, formatPrecio } from '../../utils/formatters'
import type { ProductoDB } from '../../types'
import type { ComboAdmin, ComboFormInput } from '../../hooks/queries/useCombosQuery'
import type { CategoriaDB } from '../../hooks/queries/useCategoriasQuery'
import { evaluarCombo, type ProductoParaAlertas, type UmbralesCombo } from '../../utils/comboAlertas'
import {
  productosDeCategoria,
  productosEnVariosLugares,
  resolverLugares,
  type LugarCombo,
} from '../../utils/comboCategorias'
import {
  ID_NUEVO,
  combosTapados,
  competidoresDirectos,
  moverEnOrden,
  ordenDelGrupo,
  ordenParaGuardar,
  ordenableDe,
  type ComboConLugares,
} from '../../utils/comboOrden'

export interface ModalComboProps {
  combo?: ComboAdmin | null
  productos: ProductoDB[]
  /** Rubros y subrubros de la sucursal (#1213). */
  categorias?: CategoriaDB[]
  /** Todos los combos de la sucursal, para el orden entre los que compiten (#1213). */
  combos?: ComboAdmin[]
  onSave: (input: ComboFormInput) => Promise<void>
  onClose: () => void
  guardando?: boolean
  /** Topes de las alertas de la sucursal (#1194). */
  umbrales?: UmbralesCombo
  /** Si el rol ve costos (admin, encargado): sin eso no hay margen. */
  verCostos?: boolean
}

const MAX_LUGARES = 20
const MAX_CANTIDAD_LUGAR = 1000
const MIN_UNIDADES_COMBO = 2
const MAX_FILAS_LISTA = 60

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
          sueltos: z.array(z.string()),
          categorias: z.array(z.string()),
        }).refine(l => l.sueltos.length + l.categorias.length > 0, {
          message: 'Cada lugar necesita al menos un producto o una categoría',
        })
      )
      .min(1, { message: 'Agregá al menos un lugar al combo' })
      .max(MAX_LUGARES, { message: `Un combo admite hasta ${MAX_LUGARES} lugares` }),
  })
  .superRefine((v, ctx) => {
    if (v.fechaFin && v.fechaInicio && v.fechaFin < v.fechaInicio) {
      ctx.addIssue({ code: 'custom', message: 'La fecha de fin no puede ser anterior a la de inicio' })
    }
    const sueltos = v.componentes.flatMap(c => c.sueltos)
    if (new Set(sueltos).size !== sueltos.length) {
      ctx.addIssue({ code: 'custom', message: 'Un producto no puede estar dos veces en el combo' })
    }
    const categorias = v.componentes.flatMap(c => c.categorias)
    if (new Set(categorias).size !== categorias.length) {
      ctx.addIssue({ code: 'custom', message: 'Una categoría no puede estar dos veces en el combo' })
    }
    const unidades = v.componentes.reduce((acc, c) => acc + (Number.isFinite(c.cantidad) ? c.cantidad : 0), 0)
    if (unidades < MIN_UNIDADES_COMBO && v.componentes.every(c => Number.isFinite(c.cantidad))) {
      ctx.addIssue({
        code: 'custom',
        message: `El combo tiene que sumar al menos ${MIN_UNIDADES_COMBO} unidades en total`,
      })
    }
  })

interface LugarForm {
  /** Clave estable para React (el índice cambia al quitar un lugar). */
  key: number
  cantidad: string
  sueltos: string[]
  categorias: string[]
}

/** Número de un campo de texto, "" => NaN. El precio acepta "1.234,56" y "12,5". */
function aNumero(raw: string): number {
  const t = raw.trim()
  if (t === '') return NaN
  const normalizado = t.includes(',') ? t.replace(/\./g, '').replace(',', '.') : t
  return /^-?\d*\.?\d+$/.test(normalizado) ? Number(normalizado) : NaN
}

/** Los lugares de un combo, comparables: para saber si el admin los cambió. */
function firmaLugares(lugares: readonly LugarCombo[]): string {
  return JSON.stringify(lugares.map(l => [l.cantidad, [...l.sueltos].sort(), [...l.categorias].sort()]))
}

const normalizar = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()

const inputCls =
  'w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none text-sm'
const labelCls = 'block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1'
const ayudaCls = 'text-xs text-gray-500 dark:text-gray-400 mt-1'

export default function ModalCombo({
  combo = null,
  productos,
  categorias = [],
  combos = [],
  onSave,
  onClose,
  guardando = false,
  umbrales = { margenMinimoPct: 10, descuentoMaximoPct: 30 },
  verCostos = false,
}: ModalComboProps) {
  const isEditing = !!combo
  const hoy = fechaLocalISO()

  const [nombre, setNombre] = useState(combo?.nombre ?? '')
  const [precio, setPrecio] = useState(combo ? String(combo.precio).replace('.', ',') : '')
  const [fechaInicio, setFechaInicio] = useState(combo?.fechaInicio ?? hoy)
  const [fechaFin, setFechaFin] = useState(combo?.fechaFin ?? '')
  const [combinaEscalas, setCombinaEscalas] = useState(combo?.combinaEscalas ?? false)
  const [topeCombos, setTopeCombos] = useState(combo?.topeCombos != null ? String(combo.topeCombos) : '')
  const [productoAMoverId, setProductoAMoverId] = useState(combo?.productoAMoverId ?? '')
  const [lugares, setLugares] = useState<LugarForm[]>(() =>
    combo && combo.componentes.length > 0
      ? combo.componentes.map((c, i) => ({
        key: i, cantidad: String(c.cantidad), sueltos: [...c.sueltos], categorias: [...c.categorias],
      }))
      : [{ key: 0, cantidad: '1', sueltos: [], categorias: [] }]
  )
  const [siguienteKey, setSiguienteKey] = useState(() => Math.max(1, combo?.componentes.length ?? 0))
  const [busquedas, setBusquedas] = useState<Record<number, string>>({})
  const [abierto, setAbierto] = useState<number | null>(null)
  const [ordenManual, setOrdenManual] = useState<string[] | null>(null)
  const [errores, setErrores] = useState<string[]>([])
  const [errorServidor, setErrorServidor] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  const productoPorId = useMemo(() => {
    const m = new Map<string, ProductoDB>()
    productos.forEach(p => m.set(String(p.id), p))
    return m
  }, [productos])
  const categoriaPorId = useMemo(() => new Map(categorias.map(c => [String(c.id), c])), [categorias])

  const nombreDe = (id: string): string => productoPorId.get(id)?.nombre ?? `Producto #${id}`
  const nombreCategoria = (id: string): string => {
    const c = categoriaPorId.get(id)
    if (!c) return 'Categoría eliminada'
    const padre = c.parent_id ? categoriaPorId.get(String(c.parent_id)) : null
    return padre ? `${padre.nombre} › ${c.nombre}` : c.nombre
  }

  // Los lugares tal como se guardan, y lo que cada uno vende hoy.
  const lugaresCombo: LugarCombo[] = useMemo(
    () => lugares.map(l => ({ cantidad: aNumero(l.cantidad), sueltos: l.sueltos, categorias: l.categorias })),
    [lugares],
  )
  const resueltos = useMemo(() => resolverLugares(lugaresCombo, productos), [lugaresCombo, productos])
  const repetidos = useMemo(() => new Set(productosEnVariosLugares(lugaresCombo, productos)), [lugaresCombo, productos])

  // Productos del combo (sin repetir), para elegir el "producto a mover".
  const productosDelCombo = useMemo(() => Array.from(new Set(resueltos.flatMap(l => l.productos))), [resueltos])

  // Vista previa y alertas (#1194, `evaluarCombo`) sobre lo que el combo vende
  // hoy: "sin combo" con el producto más caro de cada lugar, margen con el
  // costo más alto. Avisan, no bloquean el guardado.
  const precioNum = aNumero(precio)
  const hayPrecio = Number.isFinite(precioNum) && precioNum > 0
  const evaluacion = useMemo(
    () => evaluarCombo(
      {
        id: combo?.id ?? 'nuevo',
        nombre: nombre || 'combo',
        precio: hayPrecio ? precioNum : 0,
        componentes: resueltos.filter(l => Number.isFinite(l.cantidad) && l.cantidad > 0 && l.productos.length > 0),
      },
      productoPorId as ReadonlyMap<string, ProductoParaAlertas>,
      umbrales,
      verCostos,
    ),
    [combo?.id, nombre, hayPrecio, precioNum, resueltos, productoPorId, umbrales, verCostos],
  )
  const { sinCombo, noConviene, descuentoPct } = evaluacion
  // "No conviene" ya tiene su propio aviso abajo.
  const alertasPrecio = evaluacion.alertas.filter(a => a.tipo !== 'no_conviene')

  // ---- Orden entre los combos que compiten (#1213) ----
  const lugaresValidos = lugaresCombo.every(l => Number.isInteger(l.cantidad) && l.cantidad > 0)
  const cambiaronLugares = !combo || !lugaresValidos || firmaLugares(lugaresCombo) !== firmaLugares(combo.componentes)
  const actual: ComboConLugares = useMemo(() => ordenableDe({
    id: combo?.id ?? ID_NUEVO,
    prioridad: combo?.prioridad ?? 0,
    activo: combo?.activo ?? true,
    fechaFin: fechaFin || null,
    componentes: lugaresCombo.map(l => ({ ...l, cantidad: Number.isFinite(l.cantidad) ? l.cantidad : 0 })),
  }, productos), [combo?.id, combo?.prioridad, combo?.activo, fechaFin, lugaresCombo, productos])
  const otros = useMemo(
    () => combos.filter(c => c.id !== combo?.id).map(c => ordenableDe(c, productos)),
    [combos, combo?.id, productos],
  )
  const porId = useMemo(() => new Map([actual, ...otros].map(c => [c.id, c])), [actual, otros])
  const orden = useMemo(
    () => ordenDelGrupo(actual, otros, hoy, { reubicar: cambiaronLugares, manual: ordenManual }),
    [actual, otros, hoy, cambiaronLugares, ordenManual],
  )
  const directos = useMemo(() => new Set(competidoresDirectos(actual, otros, hoy).map(c => c.id)), [actual, otros, hoy])
  const filasOrden = (orden ?? []).filter(id => id === actual.id || directos.has(id))
  const nombreCombo = (id: string) => (id === actual.id ? 'Este combo' : combos.find(c => c.id === id)?.nombre ?? `Combo #${id}`)
  // Avisos de combo tapado con el orden que se va a guardar.
  const tapados = useMemo(() => {
    if (!orden) return []
    const n = orden.length
    const conOrden = [actual, ...otros].map(c => {
      const i = orden.indexOf(c.id)
      return i >= 0 ? { ...c, prioridad: n - i + 1_000_000 } : c
    })
    return combosTapados(conOrden, hoy).filter(t => t.arriba === actual.id || t.abajo === actual.id)
  }, [orden, actual, otros, hoy])

  const actualizarLugar = (key: number, cambio: Partial<LugarForm>) =>
    setLugares(prev => prev.map(l => (l.key === key ? { ...l, ...cambio } : l)))

  const agregarLugar = () => {
    setLugares(prev => [...prev, { key: siguienteKey, cantidad: '1', sueltos: [], categorias: [] }])
    setAbierto(siguienteKey)
    setSiguienteKey(k => k + 1)
  }

  const quitarLugar = (key: number) => setLugares(prev => prev.filter(l => l.key !== key))

  const alternarProducto = (key: number, id: string) => {
    const lugar = lugares.find(l => l.key === key)
    if (!lugar) return
    actualizarLugar(key, {
      sueltos: lugar.sueltos.includes(id) ? lugar.sueltos.filter(p => p !== id) : [...lugar.sueltos, id],
    })
  }

  const alternarCategoria = (key: number, id: string) => {
    const lugar = lugares.find(l => l.key === key)
    if (!lugar) return
    actualizarLugar(key, {
      categorias: lugar.categorias.includes(id) ? lugar.categorias.filter(c => c !== id) : [...lugar.categorias, id],
    })
  }

  // Lo que la lista de un lugar ofrece: categorías activas y productos activos
  // (más lo ya elegido, aunque esté inactivo, para poder sacarlo).
  const opcionesDe = (lugar: LugarForm) => {
    const q = normalizar((busquedas[lugar.key] ?? '').trim())
    const cats = categorias
      .filter(c => c.activa !== false || lugar.categorias.includes(String(c.id)))
      .filter(c => !q || normalizar(nombreCategoria(String(c.id))).includes(q))
      .sort((a, b) => nombreCategoria(String(a.id)).localeCompare(nombreCategoria(String(b.id)), 'es'))
    const prods = productos
      .filter(p => p.activo !== false || lugar.sueltos.includes(String(p.id)))
      .filter(p => !q || normalizar(p.nombre).includes(q) || normalizar(p.codigo ?? '').includes(q))
    return { cats, prods: prods.slice(0, MAX_FILAS_LISTA), hayMas: prods.length > MAX_FILAS_LISTA }
  }

  const handleSubmit = async () => {
    setErrorServidor(null)
    const tope = topeCombos.trim() === '' ? null : aNumero(topeCombos)
    const candidato = {
      nombre,
      precio: precioNum,
      fechaInicio,
      fechaFin: fechaFin || null,
      topeCombos: tope,
      productoAMoverId: productoAMoverId || null,
      componentes: lugaresCombo.map(l => ({ cantidad: l.cantidad, sueltos: [...l.sueltos], categorias: [...l.categorias] })),
    }
    const r = comboSchema.safeParse(candidato)
    // Lo que depende del catálogo de hoy: lo mismo que mira `guardar_combo`.
    const delCatalogo: string[] = []
    for (const p of repetidos) delCatalogo.push(`«${nombreDe(p)}» queda en dos lugares del combo`)
    resueltos.forEach((l, i) => {
      if (lugares[i] && lugares[i].sueltos.length + lugares[i].categorias.length > 0 && l.productos.length === 0) {
        delCatalogo.push(`El lugar ${i + 1} no tiene ningún producto activo`)
      }
    })
    if (productoAMoverId && !productosDelCombo.includes(productoAMoverId)) {
      delCatalogo.push('El producto a mover tiene que ser uno de los productos del combo')
    }
    if (!r.success || delCatalogo.length > 0) {
      setErrores(Array.from(new Set([...(r.success ? [] : r.error.issues.map(i => i.message)), ...delCatalogo])))
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
      prioridad: combo?.prioridad ?? 0,
      topeCombos: v.topeCombos,
      productoAMoverId: v.productoAMoverId,
      componentes: v.componentes,
      ...(orden ? { orden: ordenParaGuardar(orden) } : {}),
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
            Un lugar es un casillero con una cantidad. Lo que pongas en el mismo lugar son alternativas: el cliente
            lleva cualquiera, y puede mezclar (ej: «2 Alpha Talk de cualquier sabor»). Si elegís una categoría, entra
            todo lo que la categoría tenga, también lo que se dé de alta después.
          </p>

          <div className="space-y-3">
            {lugares.map((lugar, idx) => {
              const estaAbierto = abierto === lugar.key
              const { cats, prods, hayMas } = estaAbierto ? opcionesDe(lugar) : { cats: [], prods: [], hayMas: false }
              const trae = resueltos[idx]?.productos.length ?? 0
              const vacio = lugar.sueltos.length + lugar.categorias.length > 0 && trae === 0
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
                        onFocus={() => setAbierto(lugar.key)}
                        onChange={e => {
                          setAbierto(lugar.key)
                          setBusquedas(prev => ({ ...prev, [lugar.key]: e.target.value }))
                        }}
                        placeholder="Buscar producto o categoría..."
                        aria-label={`Buscar producto o categoría del lugar ${idx + 1}`}
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

                  {estaAbierto && (
                    <div
                      className="border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700"
                      data-testid={`combo-lista-${idx + 1}`}
                    >
                      <div className="max-h-64 overflow-y-auto divide-y dark:divide-gray-600">
                        {cats.length > 0 && (
                          <p className="px-3 py-1 text-[11px] font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400 bg-gray-50 dark:bg-gray-800">
                            Categorías
                          </p>
                        )}
                        {cats.map(c => {
                          const id = String(c.id)
                          const n = productosDeCategoria(id, productos).length
                          return (
                            <label key={`c-${id}`} className="flex items-center gap-2 px-3 py-2 text-sm cursor-pointer hover:bg-purple-50 dark:hover:bg-purple-900/20">
                              <input
                                type="checkbox"
                                checked={lugar.categorias.includes(id)}
                                onChange={() => alternarCategoria(lugar.key, id)}
                                className="rounded border-gray-300 text-purple-600 focus:ring-purple-500"
                              />
                              <Tag className="w-3.5 h-3.5 text-purple-500 shrink-0" aria-hidden="true" />
                              <span className="dark:text-white truncate">{nombreCategoria(id)}</span>
                              <span className="text-xs text-gray-400 ml-auto shrink-0">
                                {n} {n === 1 ? 'producto' : 'productos'}
                              </span>
                            </label>
                          )
                        })}
                        {prods.length > 0 && (
                          <p className="px-3 py-1 text-[11px] font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400 bg-gray-50 dark:bg-gray-800">
                            Productos
                          </p>
                        )}
                        {prods.map(prod => {
                          const id = String(prod.id)
                          return (
                            <label key={`p-${id}`} className="flex items-center gap-2 px-3 py-2 text-sm cursor-pointer hover:bg-purple-50 dark:hover:bg-purple-900/20">
                              <input
                                type="checkbox"
                                checked={lugar.sueltos.includes(id)}
                                onChange={() => alternarProducto(lugar.key, id)}
                                className="rounded border-gray-300 text-purple-600 focus:ring-purple-500"
                              />
                              <span className="dark:text-white truncate">{prod.nombre}</span>
                              {prod.activo === false && <span className="text-xs italic text-gray-500">(inactivo)</span>}
                              {repetidos.has(id) && (
                                <span className="text-[11px] text-amber-600 dark:text-amber-400 shrink-0">en otro lugar</span>
                              )}
                              <span className="text-xs text-gray-400 ml-auto shrink-0">{formatPrecio(prod.precio)}</span>
                            </label>
                          )
                        })}
                        {cats.length === 0 && prods.length === 0 && (
                          <p className="text-sm text-gray-400 px-3 py-3 text-center">Sin resultados</p>
                        )}
                        {hayMas && (
                          <p className="text-xs text-gray-400 px-3 py-2 text-center">Hay más productos: escribí para filtrar.</p>
                        )}
                      </div>
                      <div className="flex justify-end px-2 py-1.5 border-t dark:border-gray-600">
                        <Button type="button" variant="ghost" size="sm" onClick={() => setAbierto(null)}>
                          <Check className="w-4 h-4" />
                          Listo
                        </Button>
                      </div>
                    </div>
                  )}

                  {lugar.sueltos.length + lugar.categorias.length === 0 ? (
                    <p className="text-xs text-gray-400">Todavía no hay productos en este lugar.</p>
                  ) : (
                    <div className="flex flex-wrap gap-2">
                      {lugar.categorias.map(id => (
                        <span
                          key={`c-${id}`}
                          className="inline-flex items-center gap-1 text-xs pl-2.5 pr-1 py-1 rounded-full bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-200"
                        >
                          <Tag className="w-3 h-3" aria-hidden="true" />
                          {nombreCategoria(id)}
                          <span className="text-purple-600 dark:text-purple-300">
                            ({productosDeCategoria(id, productos).length})
                          </span>
                          <button
                            type="button"
                            onClick={() => alternarCategoria(lugar.key, id)}
                            aria-label={`Quitar ${nombreCategoria(id)}`}
                            className="p-0.5 rounded-full hover:bg-black/10 dark:hover:bg-white/10"
                          >
                            <X className="w-3 h-3" />
                          </button>
                        </span>
                      ))}
                      {lugar.sueltos.map(id => {
                        const prod = productoPorId.get(id)
                        const inactivo = prod?.activo === false
                        return (
                          <span
                            key={`p-${id}`}
                            className={`inline-flex items-center gap-1 text-xs pl-2.5 pr-1 py-1 rounded-full ${
                              inactivo
                                ? 'bg-gray-200 text-gray-600 dark:bg-gray-600 dark:text-gray-300'
                                : 'bg-blue-50 text-blue-700 dark:bg-blue-900/20 dark:text-blue-300'
                            }`}
                          >
                            {nombreDe(id)}
                            {inactivo && <span className="italic">(inactivo)</span>}
                            {repetidos.has(id) && (
                              <span className="text-amber-600 dark:text-amber-400">(repetido)</span>
                            )}
                            <button
                              type="button"
                              onClick={() => alternarProducto(lugar.key, id)}
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
                  {lugar.categorias.length > 0 && (
                    <p className={`text-xs ${vacio ? 'text-amber-700 dark:text-amber-300' : 'text-gray-500 dark:text-gray-400'}`}>
                      {vacio
                        ? 'Hoy este lugar no tiene ningún producto activo.'
                        : `Hoy entran ${trae} ${trae === 1 ? 'producto' : 'productos'} en este lugar.`}
                    </p>
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
          {evaluacion.margenPct !== null && (
            <p className="text-sm font-medium text-purple-700 dark:text-purple-300" data-testid="combo-margen">
              Margen: {evaluacion.margenPct.toLocaleString('es-AR', { maximumFractionDigits: 1 })}% (costo{' '}
              {formatPrecio(evaluacion.costo ?? 0)})
            </p>
          )}
          {hayPrecio && alertasPrecio.map(a => (
            <p
              key={a.tipo}
              className={`flex items-start gap-1.5 text-sm ${
                a.severidad === 'critical' ? 'text-red-700 dark:text-red-300' : 'text-amber-800 dark:text-amber-200'
              }`}
              data-testid={`combo-alerta-${a.tipo}`}
            >
              <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
              {a.texto}. Se puede guardar igual.
            </p>
          ))}
          <p className="text-[11px] text-purple-600 dark:text-purple-400">
            «Sin combo» suma, por cada lugar, la cantidad por el precio de lista del producto más caro del lugar.
          </p>
        </div>

        {/* Compite con (#1213) */}
        {filasOrden.length > 1 && (
          <div data-testid="combo-compite-con">
            <h3 className="text-sm font-semibold text-gray-800 dark:text-gray-200">Compite con</h3>
            <p className={`${ayudaCls} mb-2`}>
              Estos combos comparten productos con éste. Si un pedido alcanza para más de uno, se arma primero el de
              arriba.
            </p>
            <ol className="border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-600">
              {filasOrden.map((id, i) => {
                const esEste = id === actual.id
                return (
                  <li
                    key={id}
                    className={`flex items-center gap-2 px-3 py-2 text-sm ${
                      esEste ? 'bg-purple-50 dark:bg-purple-900/20 font-semibold text-purple-800 dark:text-purple-200' : 'dark:text-gray-200'
                    }`}
                  >
                    <span className="w-5 text-xs text-gray-400 tabular-nums">{i + 1}.</span>
                    <span className="flex-1 truncate">{nombreCombo(id)}</span>
                    <span className="text-xs text-gray-500 dark:text-gray-400">{porId.get(id)?.unidades ?? 0} u.</span>
                    {esEste && (
                      <span className="flex gap-1">
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          disabled={i === 0}
                          onClick={() => orden && setOrdenManual(moverEnOrden(orden, actual, 'arriba', porId))}
                          aria-label="Subir este combo"
                        >
                          <ArrowUp className="w-4 h-4" />
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          disabled={i === filasOrden.length - 1}
                          onClick={() => orden && setOrdenManual(moverEnOrden(orden, actual, 'abajo', porId))}
                          aria-label="Bajar este combo"
                        >
                          <ArrowDown className="w-4 h-4" />
                        </Button>
                      </span>
                    )}
                  </li>
                )
              })}
            </ol>
            {tapados.map(t => (
              <p
                key={`${t.arriba}-${t.abajo}`}
                className="flex items-start gap-1.5 text-xs mt-2 px-2 py-1 rounded-lg bg-amber-50 text-amber-800 dark:bg-amber-900/20 dark:text-amber-300"
                data-testid="combo-tapado"
              >
                <AlertTriangle className="w-3.5 h-3.5 mt-px shrink-0" aria-hidden="true" />
                {t.abajo === actual.id
                  ? `Con este orden, este combo nunca se va a armar: «${nombreCombo(t.arriba)}» le gana siempre.`
                  : `Con este orden, «${nombreCombo(t.abajo)}» nunca se va a armar: este combo le gana siempre.`}
              </p>
            ))}
          </div>
        )}

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
            <p className={ayudaCls}>El producto que el combo quiere hacer rotar (se usa en el análisis de rotación).</p>
          </div>
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
