/**
 * #908. Promociones de compra de UN proveedor (de la sucursal activa): con qué
 * productos, cuánto por unidad o qué % y desde/hasta cuándo. El modal de compra
 * las usa para sugerir la bonificación que la factura no descontó.
 *
 * Productos: para OPERAR se ofrecen sólo los activos (CLAUDE.md: lo operativo
 * oculta los inactivos). Uno que ya estaba en la promo y después se desactivó
 * se sigue mostrando, marcado "inactivo", para que se pueda ver y sacar.
 */
import { useMemo, useState } from 'react'
import type { FormEvent } from 'react'
import { z } from 'zod'
import { Plus, Edit2, Trash2, Search } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { formatPrecio } from '../../utils/formatters'
import { normalizarBusqueda } from '../../utils/filtrarOpciones'
import { useProductosQuery } from '../../hooks/queries/useProductosQuery'
import {
  usePromocionesProveedorQuery,
  useGuardarPromocionProveedorMutation,
  useEliminarPromocionProveedorMutation,
} from '../../hooks/queries/usePromocionesProveedorQuery'
import type { PromocionProveedorDetalle } from '../../hooks/queries/usePromocionesProveedorQuery'
import type { ProductoDB } from '../../types'

// Schema CO-LOCADO a propósito (no en lib/schemas.ts): un bundle viejo del PWA
// validaría contra un schema desincronizado (ver ModalCambioProducto.tsx).
const promocionProveedorSchema = z.object({
  nombre: z.string().trim().min(2, { message: 'Poné un nombre (al menos 2 letras)' }),
  tipo: z.enum(['monto_por_unidad', 'porcentaje']),
  valor: z.coerce.number({ message: 'Ingresá un número' }).positive({ message: 'Tiene que ser mayor a 0' }),
  vigenteDesde: z.string(),
  vigenteHasta: z.string(),
  activo: z.boolean(),
  notas: z.string(),
  // Los ids son bigint y llegan como number en runtime.
  productoIds: z.array(z.coerce.string()).min(1, { message: 'Elegí al menos un producto' }),
}).superRefine((v, ctx) => {
  if (v.tipo === 'porcentaje' && v.valor > 100) {
    ctx.addIssue({ code: 'custom', path: ['valor'], message: 'El porcentaje no puede pasar de 100' })
  }
  if (v.tipo === 'monto_por_unidad' && v.valor >= 1_000_000_000) {
    ctx.addIssue({ code: 'custom', path: ['valor'], message: 'Monto fuera de rango' })
  }
  if (v.vigenteDesde && v.vigenteHasta && v.vigenteHasta < v.vigenteDesde) {
    ctx.addIssue({ code: 'custom', path: ['vigenteHasta'], message: 'El "hasta" es anterior al "desde"' })
  }
})

interface Borrador {
  id: string | null
  nombre: string
  tipo: 'monto_por_unidad' | 'porcentaje'
  valor: string
  vigenteDesde: string
  vigenteHasta: string
  activo: boolean
  notas: string
  productoIds: string[]
  productoIdsPrevios: string[]
}

const VACIO: Borrador = {
  id: null, nombre: '', tipo: 'monto_por_unidad', valor: '', vigenteDesde: '', vigenteHasta: '',
  activo: true, notas: '', productoIds: [], productoIdsPrevios: [],
}

const desdePromo = (p: PromocionProveedorDetalle): Borrador => ({
  id: p.id,
  nombre: p.nombre,
  tipo: p.tipo,
  valor: String((p.tipo === 'porcentaje' ? p.porcentaje : p.montoPorUnidad) ?? ''),
  vigenteDesde: p.vigenteDesde ?? '',
  vigenteHasta: p.vigenteHasta ?? '',
  activo: p.activo,
  notas: p.notas ?? '',
  productoIds: [...p.productoIds],
  productoIdsPrevios: [...p.productoIds],
})

const inputCls = 'w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none text-sm'

function resumenPromo(p: PromocionProveedorDetalle): string {
  const regla = p.tipo === 'porcentaje' ? `${p.porcentaje ?? 0} % del neto` : `${formatPrecio(p.montoPorUnidad ?? 0)} por unidad`
  const vig = p.vigenteDesde || p.vigenteHasta
    ? ` · ${p.vigenteDesde ? `desde ${p.vigenteDesde}` : ''}${p.vigenteDesde && p.vigenteHasta ? ' ' : ''}${p.vigenteHasta ? `hasta ${p.vigenteHasta}` : ''}`
    : ''
  return `${regla} · ${p.productoIds.length} ${p.productoIds.length === 1 ? 'producto' : 'productos'}${vig}`
}

export interface ModalPromocionesProveedorProps {
  proveedor: { id: string; nombre: string }
  onClose: () => void
}

export default function ModalPromocionesProveedor({ proveedor, onClose }: ModalPromocionesProveedorProps) {
  const { data: promos = [], isLoading, error: errorCarga } = usePromocionesProveedorQuery(proveedor.id)
  const { data: productos = [] } = useProductosQuery()
  const guardar = useGuardarPromocionProveedorMutation()
  const eliminar = useEliminarPromocionProveedorMutation()

  const [borrador, setBorrador] = useState<Borrador | null>(null)
  const [errores, setErrores] = useState<Record<string, string>>({})
  const [errorGuardar, setErrorGuardar] = useState<string>('')
  const [porBorrar, setPorBorrar] = useState<PromocionProveedorDetalle | null>(null)
  const [busqueda, setBusqueda] = useState('')
  const [soloDelProveedor, setSoloDelProveedor] = useState(true)

  const productosPorId = useMemo(() => new Map(productos.map(p => [String(p.id), p])), [productos])
  const hayDelProveedor = useMemo(
    () => productos.some(p => String(p.proveedor_id ?? '') === String(proveedor.id)),
    [productos, proveedor.id],
  )

  const ofrecidos = useMemo<ProductoDB[]>(() => {
    if (!borrador) return []
    const elegidos = new Set(borrador.productoIds)
    const q = normalizarBusqueda(busqueda)
    return productos.filter(p => {
      const id = String(p.id)
      // Los ya elegidos siempre se ven (aunque estén inactivos: es lo que hay que poder sacar).
      if (elegidos.has(id)) return !q || normalizarBusqueda(`${p.nombre} ${p.codigo ?? ''}`).includes(q)
      if (p.activo === false) return false
      if (soloDelProveedor && hayDelProveedor && String(p.proveedor_id ?? '') !== String(proveedor.id)) return false
      return !q || normalizarBusqueda(`${p.nombre} ${p.codigo ?? ''}`).includes(q)
    })
  }, [borrador, productos, busqueda, soloDelProveedor, hayDelProveedor, proveedor.id])

  const abrir = (b: Borrador) => {
    setBorrador(b)
    setErrores({})
    setErrorGuardar('')
    setBusqueda('')
  }

  const toggleProducto = (id: string) => {
    setBorrador(b => b && ({
      ...b,
      productoIds: b.productoIds.includes(id) ? b.productoIds.filter(x => x !== id) : [...b.productoIds, id],
    }))
  }

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault()
    if (!borrador) return
    const r = promocionProveedorSchema.safeParse(borrador)
    if (!r.success) {
      const errs: Record<string, string> = {}
      for (const issue of r.error.issues) {
        const k = String(issue.path[0] ?? 'form')
        if (!errs[k]) errs[k] = issue.message
      }
      setErrores(errs)
      return
    }
    setErrores({})
    setErrorGuardar('')
    try {
      await guardar.mutateAsync({
        id: borrador.id,
        proveedorId: proveedor.id,
        nombre: r.data.nombre,
        tipo: r.data.tipo,
        montoPorUnidad: r.data.tipo === 'monto_por_unidad' ? r.data.valor : null,
        porcentaje: r.data.tipo === 'porcentaje' ? r.data.valor : null,
        vigenteDesde: r.data.vigenteDesde || null,
        vigenteHasta: r.data.vigenteHasta || null,
        activo: r.data.activo,
        notas: r.data.notas || null,
        productoIds: r.data.productoIds,
        productoIdsPrevios: borrador.productoIdsPrevios,
      })
      setBorrador(null)
    } catch (err) {
      setErrorGuardar(err instanceof Error ? err.message : 'No se pudo guardar la promoción')
    }
  }

  const confirmarBorrado = async () => {
    if (!porBorrar) return
    try {
      await eliminar.mutateAsync(porBorrar.id)
      setPorBorrar(null)
    } catch (err) {
      setErrorGuardar(err instanceof Error ? err.message : 'No se pudo eliminar la promoción')
      setPorBorrar(null)
    }
  }

  return (
    <ModalBase
      title={`Promociones de ${proveedor.nombre}`}
      description="Lo que el proveedor bonifica por promoción. Al cargar una factura suya, si la promo aplicaba y no está descontada, se sugiere la bonificación."
      onClose={onClose}
      maxWidth="max-w-2xl"
    >
      <div className="space-y-4 p-1">
        {errorCarga && (
          <p role="alert" className="text-sm text-red-700 dark:text-red-400">No se pudieron leer las promociones.</p>
        )}
        {errorGuardar && (
          <p role="alert" className="text-sm text-red-700 dark:text-red-400">{errorGuardar}</p>
        )}

        {/* Confirmación de borrado ADENTRO del modal: como hermano en el
            container quedaría detrás del overlay. */}
        {porBorrar && (
          <div role="alertdialog" aria-label="Confirmar borrado" className="rounded-lg border border-red-300 bg-red-50 p-3 text-sm dark:border-red-700 dark:bg-red-900/20">
            <p className="text-gray-900 dark:text-red-100">
              ¿Eliminar la promoción "{porBorrar.nombre}"? Las compras ya cargadas no cambian.
            </p>
            <div className="mt-2 flex justify-end gap-2">
              <Button type="button" variant="ghost" size="sm" onClick={() => setPorBorrar(null)}>Cancelar</Button>
              <Button type="button" variant="danger" size="sm" onClick={confirmarBorrado} disabled={eliminar.isPending}>
                Eliminar
              </Button>
            </div>
          </div>
        )}

        {!borrador && (
          <>
            {isLoading ? (
              <p className="text-sm text-gray-500">Cargando…</p>
            ) : promos.length === 0 ? (
              <p className="text-sm text-gray-600 dark:text-gray-400">Este proveedor no tiene promociones cargadas.</p>
            ) : (
              <ul className="divide-y rounded-lg border dark:divide-gray-700 dark:border-gray-700">
                {promos.map(p => (
                  <li key={p.id} className="flex items-center gap-2 p-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-medium text-gray-900 dark:text-white">
                        {p.nombre}
                        {!p.activo && <span className="ml-2 text-xs font-normal text-gray-500">(inactiva)</span>}
                      </p>
                      <p className="text-xs text-gray-600 dark:text-gray-400">{resumenPromo(p)}</p>
                    </div>
                    <Button type="button" variant="ghost" size="iconSm" title="Editar" aria-label={`Editar ${p.nombre}`} onClick={() => abrir(desdePromo(p))}>
                      <Edit2 className="h-4 w-4" />
                    </Button>
                    <Button type="button" variant="ghost" size="iconSm" title="Eliminar" aria-label={`Eliminar ${p.nombre}`}
                            className="text-red-600 dark:text-red-400" onClick={() => setPorBorrar(p)}>
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </li>
                ))}
              </ul>
            )}
            <div className="flex justify-between gap-2">
              <Button type="button" variant="success" size="sm" className="gap-1" onClick={() => abrir(VACIO)}>
                <Plus className="h-4 w-4" /> Nueva promoción
              </Button>
              <Button type="button" variant="ghost" size="sm" onClick={onClose}>Cerrar</Button>
            </div>
          </>
        )}

        {borrador && (
          <form onSubmit={handleSubmit} className="space-y-3" noValidate>
            <div>
              <label htmlFor="pp-nombre" className="mb-1 block text-sm font-medium text-gray-700 dark:text-gray-300">Nombre</label>
              <input id="pp-nombre" className={inputCls} value={borrador.nombre}
                     onChange={e => setBorrador({ ...borrador, nombre: e.target.value })} />
              {errores.nombre && <p role="alert" className="mt-1 text-xs text-red-700 dark:text-red-400">{errores.nombre}</p>}
            </div>

            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <div>
                <label htmlFor="pp-tipo" className="mb-1 block text-sm font-medium text-gray-700 dark:text-gray-300">Tipo</label>
                <select id="pp-tipo" className={inputCls} value={borrador.tipo}
                        onChange={e => setBorrador({ ...borrador, tipo: e.target.value as Borrador['tipo'] })}>
                  <option value="monto_por_unidad">Monto por unidad (sin IVA)</option>
                  <option value="porcentaje">Porcentaje del neto</option>
                </select>
              </div>
              <div>
                <label htmlFor="pp-valor" className="mb-1 block text-sm font-medium text-gray-700 dark:text-gray-300">
                  {borrador.tipo === 'porcentaje' ? 'Porcentaje' : 'Monto por unidad'}
                </label>
                <input id="pp-valor" className={inputCls} inputMode="decimal" value={borrador.valor}
                       onChange={e => setBorrador({ ...borrador, valor: e.target.value.replace(',', '.') })} />
                {errores.valor && <p role="alert" className="mt-1 text-xs text-red-700 dark:text-red-400">{errores.valor}</p>}
              </div>
              <div>
                <label htmlFor="pp-desde" className="mb-1 block text-sm font-medium text-gray-700 dark:text-gray-300">Vigente desde</label>
                <input id="pp-desde" type="date" className={inputCls} value={borrador.vigenteDesde}
                       onChange={e => setBorrador({ ...borrador, vigenteDesde: e.target.value })} />
              </div>
              <div>
                <label htmlFor="pp-hasta" className="mb-1 block text-sm font-medium text-gray-700 dark:text-gray-300">Vigente hasta</label>
                <input id="pp-hasta" type="date" className={inputCls} value={borrador.vigenteHasta}
                       onChange={e => setBorrador({ ...borrador, vigenteHasta: e.target.value })} />
                {errores.vigenteHasta && <p role="alert" className="mt-1 text-xs text-red-700 dark:text-red-400">{errores.vigenteHasta}</p>}
              </div>
            </div>

            <label className="flex items-center gap-2 text-sm text-gray-700 dark:text-gray-300">
              <input type="checkbox" checked={borrador.activo}
                     onChange={e => setBorrador({ ...borrador, activo: e.target.checked })} />
              Activa
            </label>

            <fieldset className="space-y-2">
              <legend className="text-sm font-medium text-gray-700 dark:text-gray-300">
                Productos ({borrador.productoIds.length} elegidos)
              </legend>
              <div className="relative">
                <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-400" aria-hidden="true" />
                <input aria-label="Buscar producto" className={`${inputCls} pl-9`} value={busqueda}
                       placeholder="Buscar producto…" onChange={e => setBusqueda(e.target.value)} />
              </div>
              {hayDelProveedor && (
                <label className="flex items-center gap-2 text-xs text-gray-600 dark:text-gray-400">
                  <input type="checkbox" checked={soloDelProveedor} onChange={e => setSoloDelProveedor(e.target.checked)} />
                  Sólo productos de este proveedor
                </label>
              )}
              <ul className="max-h-60 overflow-y-auto rounded-lg border dark:border-gray-700">
                {ofrecidos.length === 0 && (
                  <li className="p-3 text-sm text-gray-500">Ningún producto coincide.</li>
                )}
                {ofrecidos.map(p => {
                  const id = String(p.id)
                  return (
                    <li key={id}>
                      <label className="flex items-center gap-2 px-3 py-1.5 text-sm hover:bg-gray-50 dark:hover:bg-gray-700/50">
                        <input type="checkbox" checked={borrador.productoIds.includes(id)} onChange={() => toggleProducto(id)} />
                        <span className="text-gray-900 dark:text-white">{p.nombre}</span>
                        {p.activo === false && <span className="text-xs text-gray-500">(inactivo)</span>}
                      </label>
                    </li>
                  )
                })}
              </ul>
              {/* Elegidos que no están en el catálogo cargado (borrados): sólo se cuentan. */}
              {borrador.productoIds.some(id => !productosPorId.has(id)) && productos.length > 0 && (
                <p className="text-xs text-gray-500">Hay productos elegidos que ya no están en el catálogo.</p>
              )}
              {errores.productoIds && <p role="alert" className="text-xs text-red-700 dark:text-red-400">{errores.productoIds}</p>}
            </fieldset>

            <div>
              <label htmlFor="pp-notas" className="mb-1 block text-sm font-medium text-gray-700 dark:text-gray-300">Notas</label>
              <textarea id="pp-notas" rows={2} className={inputCls} value={borrador.notas}
                        onChange={e => setBorrador({ ...borrador, notas: e.target.value })} />
            </div>

            <div className="flex justify-end gap-2">
              <Button type="button" variant="ghost" size="sm" onClick={() => setBorrador(null)}>Volver</Button>
              <Button type="submit" variant="success" size="sm" disabled={guardar.isPending}>
                {guardar.isPending ? 'Guardando…' : 'Guardar'}
              </Button>
            </div>
          </form>
        )}
      </div>
    </ModalBase>
  )
}
