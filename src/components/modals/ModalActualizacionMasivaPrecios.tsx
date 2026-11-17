import { useState, useMemo, useCallback, Suspense } from 'react'
import type { ChangeEvent } from 'react'
import { Percent, Search, AlertTriangle, TrendingUp, TrendingDown } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { useActualizarPreciosMasivoMutation } from '../../hooks/queries'
import { useGruposPrecioQuery } from '../../hooks/queries/useGruposPrecioQuery'
import { leerPreciosVigentes } from '../../hooks/queries/preciosVigentes'
import { usePoliticasComercialesQuery } from '../../hooks/queries/usePoliticasComercialesQuery'
import type { ErrorPreciosMasivo } from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import { calcularNuevosPrecios, mensajeExitoPreciosMasivo, separarSinPrecio } from '../../utils/precios'
import { escalasCambiaron, escalasDeSeleccion, seleccionTrasErrorMasivo } from '../../utils/preciosMasivoLotes'
import { compararPrecios, mensajeCambiosDePrecio } from '../../utils/preciosVigentes'
import type { PrecioVigente } from '../../utils/preciosVigentes'
import { formatPrecio } from '../../utils/formatters'
import type { ProductoDB, ProveedorDBExtended } from '../../types'
import { lazyWithReload } from '../../utils/lazyWithReload'

const ModalConfirmacion = lazyWithReload(() => import('./ModalConfirmacion'))

export interface ModalActualizacionMasivaPreciosProps {
  productos: ProductoDB[]
  proveedores: ProveedorDBExtended[]
  categorias: string[]
  onClose: () => void
}

const PREVIEW_LIMIT = 5

export default function ModalActualizacionMasivaPrecios({
  productos: productosEnCache,
  proveedores,
  categorias,
  onClose,
}: ModalActualizacionMasivaPreciosProps) {
  const notify = useNotification()
  const mutation = useActualizarPreciosMasivoMutation()
  // Las condiciones mayoristas de los productos (#1561, CAT-7). Si no cargan, no se
  // puede saber qué escalas tocan: no se deja aplicar a ciegas.
  const grupos = useGruposPrecioQuery()
  // El múltiplo del redondeo es de la política de la sucursal (#1561, CAT-8). Sin la
  // del servidor no se aplica: el default podría no ser el que eligió el admin.
  const politica = usePoliticasComercialesQuery()
  const multiplo = politica.politicas.multiploRedondeoPrecio

  const [porcentajeStr, setPorcentajeStr] = useState('')
  const [busqueda, setBusqueda] = useState('')
  const [filtroProveedor, setFiltroProveedor] = useState<string>('todos')
  const [filtroCategoria, setFiltroCategoria] = useState<string>('todas')
  const [seleccionados, setSeleccionados] = useState<Set<string>>(new Set())
  const [confirmOpen, setConfirmOpen] = useState(false)
  // Decisión del dueño (12/11): ofrecer aplicarles el mismo porcentaje a las escalas, tildado.
  const [aplicarEscalas, setAplicarEscalas] = useState(true)

  // FRG2-3 (#1599): el catálogo del caché puede tener hasta 10 minutos. Los precios
  // que el usuario vio al abrir son la referencia; al confirmar se leen de la base y
  // si alguno cambió, `frescos` pasa a ser lo que se muestra y se calcula, y se
  // avisa sin aplicar nada hasta que el usuario confirme de nuevo.
  const [referencia, setReferencia] = useState<Map<string, { precio: number | null | undefined; precio_sin_iva: number | null | undefined }>>(
    () => new Map(productosEnCache.map(p => [p.id, { precio: p.precio, precio_sin_iva: p.precio_sin_iva }]))
  )
  const [frescos, setFrescos] = useState<Map<string, PrecioVigente>>(new Map())
  const [avisoPrecios, setAvisoPrecios] = useState('')
  const [verificando, setVerificando] = useState(false)
  const productos = useMemo(
    () => (frescos.size === 0 ? productosEnCache : productosEnCache.map(p => {
      const f = frescos.get(p.id)
      if (!f) return p
      return {
        ...p,
        precio: f.precio ?? p.precio,
        precio_sin_iva: f.precio_sin_iva ?? p.precio_sin_iva,
        ...(f.condicion_iva ? { condicion_iva: f.condicion_iva } : {}),
        ...(f.porcentaje_iva != null ? { porcentaje_iva: f.porcentaje_iva } : {}),
      } as ProductoDB
    })),
    [productosEnCache, frescos]
  )

  const porcentaje = parseFloat(porcentajeStr.replace(',', '.'))
  // Una rebaja del 100 % o más deja el precio en 0 o negativo: no es un porcentaje válido.
  const porcentajeValido = !isNaN(porcentaje) && porcentaje !== 0 && porcentaje > -100

  const proveedoresMap = useMemo(
    () => new Map(proveedores.map(p => [p.id, p.nombre])),
    [proveedores]
  )

  const productosFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase()
    return productos.filter(p => {
      if (q) {
        const matchTexto =
          p.nombre?.toLowerCase().includes(q) ||
          p.codigo?.toLowerCase().includes(q)
        if (!matchTexto) return false
      }
      if (filtroProveedor !== 'todos' && p.proveedor_id !== filtroProveedor) return false
      if (filtroCategoria !== 'todas' && p.categoria !== filtroCategoria) return false
      return true
    })
  }, [productos, busqueda, filtroProveedor, filtroCategoria])

  const productosSeleccionados = useMemo(
    () => productos.filter(p => seleccionados.has(p.id)),
    [productos, seleccionados]
  )

  // Un producto sin precio no cambia con un porcentaje: no se manda ni se cuenta (#1599, b7).
  const { conPrecio: productosAActualizar, sinPrecio: productosSinPrecio } = useMemo(
    () => separarSinPrecio(productosSeleccionados),
    [productosSeleccionados]
  )

  const seleccionadosFueraDelFiltro = useMemo(() => {
    const idsFiltrados = new Set(productosFiltrados.map(p => p.id))
    return productosSeleccionados.filter(p => !idsFiltrados.has(p.id)).length
  }, [productosFiltrados, productosSeleccionados])

  const previewItems = useMemo(() => {
    if (!porcentajeValido) return []
    return productosSeleccionados.slice(0, PREVIEW_LIMIT).map(p => ({
      producto: p,
      nuevos: calcularNuevosPrecios(p, porcentaje, multiplo),
    }))
  }, [productosSeleccionados, porcentaje, porcentajeValido, multiplo])

  const algunoQuedaEnCero = useMemo(() => {
    if (!porcentajeValido) return false
    return productosSeleccionados.some(p => {
      const nuevos = calcularNuevosPrecios(p, porcentaje, multiplo)
      return nuevos.precio_final === 0 || nuevos.precio_neto === 0
    })
  }, [productosSeleccionados, porcentaje, porcentajeValido, multiplo])

  const escalas = useMemo(
    () => escalasDeSeleccion(grupos.data ?? [], seleccionados, porcentajeValido ? porcentaje : 0, multiplo),
    [grupos.data, seleccionados, porcentaje, porcentajeValido, multiplo]
  )

  const visiblesTodosSeleccionados =
    productosFiltrados.length > 0 &&
    productosFiltrados.every(p => seleccionados.has(p.id))

  const toggleProducto = useCallback((id: string) => {
    setSeleccionados(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }, [])

  const toggleSeleccionarVisibles = useCallback(() => {
    setSeleccionados(prev => {
      const next = new Set(prev)
      if (visiblesTodosSeleccionados) {
        productosFiltrados.forEach(p => next.delete(p.id))
      } else {
        productosFiltrados.forEach(p => next.add(p.id))
      }
      return next
    })
  }, [productosFiltrados, visiblesTodosSeleccionados])

  const handleDeseleccionarTodos = useCallback(() => {
    setSeleccionados(new Set())
  }, [])

  const puedeAplicar =
    porcentajeValido && productosAActualizar.length > 0 && !mutation.isPending && !verificando && grupos.isSuccess && politica.isSuccess

  const handleAplicar = useCallback(() => {
    if (!puedeAplicar) return
    setAvisoPrecios('')
    setConfirmOpen(true)
  }, [puedeAplicar])

  const handleConfirmar = useCallback(async () => {
    setConfirmOpen(false)

    // Antes de mandar un solo precio: ¿siguen siendo los que se vieron?
    setVerificando(true)
    let vigentes: PrecioVigente[]
    try {
      vigentes = await leerPreciosVigentes(productosAActualizar.map(p => p.id))
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudieron verificar los precios actuales. No se aplicó nada.')
      return
    } finally {
      setVerificando(false)
    }
    const comparacion = compararPrecios(
      productosAActualizar.map(p => {
        // Lo último que el usuario vio de cada producto: lo de al abrir, o lo que el
        // aviso anterior le mostró. Uno que no estaba al abrir se mide contra su caché.
        const visto = referencia.get(p.id) ?? { precio: p.precio, precio_sin_iva: p.precio_sin_iva }
        return { id: p.id, nombre: p.nombre, precio: visto.precio, precio_sin_iva: visto.precio_sin_iva }
      }),
      vigentes,
    )
    if (comparacion.cambios.length > 0 || comparacion.faltan.length > 0) {
      setFrescos(prev => new Map([...prev, ...vigentes.map(v => [v.id, v] as const)]))
      setReferencia(prev => new Map([...prev, ...vigentes.map(v => [v.id, { precio: v.precio, precio_sin_iva: v.precio_sin_iva }] as const)]))
      if (comparacion.faltan.length > 0) {
        const fuera = new Set(comparacion.faltan.map(f => f.id))
        setSeleccionados(prev => new Set([...prev].filter(id => !fuera.has(id))))
      }
      setAvisoPrecios(mensajeCambiosDePrecio(comparacion))
      // El aviso de la pantalla ya dice cuáles cambiaron y que no se aplicó nada (`mensajeCambiosDePrecio`):
      // el toast no repite esa frase.
      notify.warning('Cambiaron precios mientras tenías abierta esta pantalla: revisá el aviso.')
      return
    }

    // Las escalas mayoristas también salen de la base y no de la lista en caché (FRG2-3, #1599):
    // si otro admin tocó una condición mientras esta pantalla estaba abierta, se avisa y no se aplica.
    if (aplicarEscalas) {
      let condicionesFrescas: typeof grupos.data
      try {
        condicionesFrescas = (await grupos.refetch({ throwOnError: true })).data
      } catch {
        notify.error('No se pudieron verificar las condiciones mayoristas actuales. No se aplicó nada.')
        return
      }
      const frescas = escalasDeSeleccion(condicionesFrescas ?? [], seleccionados, porcentaje, multiplo)
      if (escalasCambiaron(escalas.aplicables, frescas.aplicables)) {
        setAvisoPrecios('Cambiaron las escalas mayoristas de estos productos desde que abriste esta pantalla. No se aplicó nada: revisalas en la vista previa y volvé a apretar Aplicar para confirmar.')
        notify.warning('Cambiaron las condiciones mayoristas mientras tenías abierta esta pantalla: revisá el aviso.')
        return
      }
    }

    const items = productosAActualizar.map(p => {
      const nuevos = calcularNuevosPrecios(p, porcentaje, multiplo)
      return {
        producto_id: p.id,
        precio_neto: nuevos.precio_neto,
        imp_internos: nuevos.imp_internos,
        precio_final: nuevos.precio_final,
      }
    })
    try {
      const result = await mutation.mutateAsync({
        items,
        escalas: aplicarEscalas ? escalas.aplicables : [],
      })
      // Entraron todos los productos: la corrida está hecha. Una escala que no se cambió
      // se avisa (#1561), pero no deja la selección con productos ya aumentados.
      if (result.escalas_sin_cambiar?.length) notify.warning(mensajeExitoPreciosMasivo(result))
      else notify.success(mensajeExitoPreciosMasivo(result))
      onClose()
    } catch (err) {
      const mensaje = err instanceof Error ? err.message : 'Error actualizando precios'
      // #1473 y #1561: si algo cambió, quedan seleccionados sólo los que se pueden volver
      // a mandar (los trabados y los de las tandas que no se mandaron): volver a aplicar
      // no le suma el porcentaje otra vez a los que ya cambiaron. Sólo si no cambió nada
      // queda la selección entera.
      const salida = seleccionTrasErrorMasivo(err as ErrorPreciosMasivo | null)
      if (salida.seleccionar) {
        setSeleccionados(new Set(salida.seleccionar))
        notify.warning(mensaje)
        return
      }
      notify.error(mensaje)
    }
  }, [productosAActualizar, porcentaje, mutation, notify, onClose, aplicarEscalas, escalas.aplicables, multiplo, referencia, grupos, seleccionados])

  const handlePorcentajeChange = (e: ChangeEvent<HTMLInputElement>) => {
    const v = e.target.value
    // Permitir vacío, signo negativo, dígitos, punto/coma decimal
    if (v === '' || /^-?\d*[.,]?\d*$/.test(v)) {
      setPorcentajeStr(v)
    }
  }

  const signoIcono =
    porcentajeValido && porcentaje > 0 ? (
      <TrendingUp className="w-5 h-5 text-green-600 dark:text-green-400" aria-hidden="true" />
    ) : porcentajeValido && porcentaje < 0 ? (
      <TrendingDown className="w-5 h-5 text-red-600 dark:text-red-400" aria-hidden="true" />
    ) : (
      <Percent className="w-5 h-5 text-gray-400 dark:text-gray-500" aria-hidden="true" />
    )

  const conEscalas = aplicarEscalas && escalas.aplicables.length > 0
  const mensajeConfirmacion = `Vas a actualizar ${productosAActualizar.length} producto(s)${
    conEscalas ? ` y ${escalas.aplicables.length} escala(s) mayorista(s)` : ''
  }${
    productosSinPrecio.length > 0 ? ` (${productosSinPrecio.length} seleccionado(s) sin precio quedan afuera)` : ''
  } con un ${
    porcentaje > 0 ? '+' : ''
  }${porcentaje}%. Esta acción modifica precio neto y precio final (los impuestos internos no se tocan)${
    escalas.aplicables.length > 0 && !aplicarEscalas ? '. Las escalas mayoristas quedan como están' : ''
  }. ¿Continuar?`

  return (
    <ModalBase
      onClose={onClose}
      title="Actualización masiva de precios"
      description="Aplicá un porcentaje de aumento o rebaja a varios productos a la vez."
      maxWidth="max-w-4xl"
    >
      <div className="flex flex-col">
          <div className="px-5 sm:px-6 py-5 space-y-5">
            {/* Input de porcentaje */}
            <div>
              <label htmlFor="pct-aumento" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                Porcentaje de aumento o rebaja
              </label>
              {/* No usa FormField (#777): este input va envuelto en un div con ícono y
                  sufijo "%", y FormField clona UN solo hijo: el id y los aria-* caerían
                  en el div y no en el input, y el label dejaría de apuntarle. */}
              <div className="relative">
                <div className="absolute inset-y-0 left-3 flex items-center pointer-events-none">
                  {signoIcono}
                </div>
                <input
                  id="pct-aumento"
                  type="text"
                  inputMode="decimal"
                  value={porcentajeStr}
                  onChange={handlePorcentajeChange}
                  placeholder="Ej: 3 para +3%, -5 para -5%"
                  className="w-full pl-10 pr-10 py-2.5 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                  aria-describedby="pct-help"
                />
                <span className="absolute inset-y-0 right-3 flex items-center text-gray-500 dark:text-gray-400">%</span>
              </div>
              <p id="pct-help" className="mt-1.5 text-xs text-gray-500 dark:text-gray-400">
                Los nuevos precios se redondean a múltiplos de ${multiplo} (se cambia en Configuración), salvo que el redondeo
                mueva el precio tanto o más que el porcentaje: ahí quedan al centavo. El neto sale del precio final.
              </p>
            </div>

            {/* Filtros */}
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
              <div className="relative">
                <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 w-4 h-4" aria-hidden="true" />
                <input
                  type="text"
                  value={busqueda}
                  onChange={e => setBusqueda(e.target.value)}
                  placeholder="Buscar nombre o código"
                  className="w-full pl-9 pr-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                  aria-label="Buscar productos"
                />
              </div>
              <select
                value={filtroProveedor}
                onChange={e => setFiltroProveedor(e.target.value)}
                className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                aria-label="Filtrar por proveedor"
              >
                <option value="todos">Todos los proveedores</option>
                {proveedores.map(p => (
                  <option key={p.id} value={p.id}>{p.nombre}</option>
                ))}
              </select>
              <select
                value={filtroCategoria}
                onChange={e => setFiltroCategoria(e.target.value)}
                className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                aria-label="Filtrar por categoría"
              >
                <option value="todas">Todas las categorías</option>
                {categorias.map(c => (
                  <option key={c} value={c}>{c}</option>
                ))}
              </select>
            </div>

            {/* Acciones de selección */}
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <button
                type="button"
                onClick={toggleSeleccionarVisibles}
                disabled={productosFiltrados.length === 0}
                className="px-3 py-1.5 rounded-md bg-indigo-100 dark:bg-indigo-900/30 text-indigo-700 dark:text-indigo-300 hover:bg-indigo-200 dark:hover:bg-indigo-900/50 disabled:opacity-50 disabled:cursor-not-allowed font-medium"
              >
                {visiblesTodosSeleccionados ? 'Quitar selección visibles' : 'Seleccionar visibles'}
              </button>
              {seleccionados.size > 0 && (
                <button
                  type="button"
                  onClick={handleDeseleccionarTodos}
                  className="px-3 py-1.5 rounded-md bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 font-medium"
                >
                  Limpiar selección
                </button>
              )}
              <span className="ml-auto text-gray-600 dark:text-gray-400">
                <span className="font-medium text-gray-800 dark:text-gray-200">{productosSeleccionados.length}</span> seleccionado(s)
                {seleccionadosFueraDelFiltro > 0 && (
                  <span className="text-gray-500 dark:text-gray-500">
                    {' '}({seleccionadosFueraDelFiltro} fuera del filtro actual)
                  </span>
                )}
                {productosSinPrecio.length > 0 && (
                  <span className="text-amber-700 dark:text-amber-400">
                    {' '}({productosSinPrecio.length} sin precio: no se tocan)
                  </span>
                )}
              </span>
            </div>

            {/* Lista de productos */}
            <div className="border dark:border-gray-700 rounded-lg overflow-hidden shadow-sm">
              <div className="max-h-80 overflow-y-auto">
                <table className="w-full text-sm">
                  <thead className="bg-gray-50 dark:bg-gray-800 sticky top-0 z-10 shadow-sm">
                    <tr className="text-left text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-400">
                      <th className="px-4 py-3 w-12"></th>
                      <th className="px-4 py-3">Producto</th>
                      <th className="px-4 py-3 hidden sm:table-cell">Proveedor</th>
                      <th className="px-4 py-3 text-right">Neto</th>
                      <th className="px-4 py-3 text-right">Final</th>
                    </tr>
                  </thead>
                  <tbody>
                    {productosFiltrados.length === 0 && (
                      <tr>
                        <td colSpan={5} className="px-4 py-10 text-center text-gray-500 dark:text-gray-400">
                          No hay productos que coincidan con los filtros.
                        </td>
                      </tr>
                    )}
                    {productosFiltrados.map(p => {
                      const seleccionado = seleccionados.has(p.id)
                      return (
                        <tr
                          key={p.id}
                          className={`border-t dark:border-gray-700 cursor-pointer transition-colors ${
                            seleccionado
                              ? 'bg-indigo-50 dark:bg-indigo-900/20'
                              : 'hover:bg-gray-50 dark:hover:bg-gray-800/50'
                          }`}
                          onClick={() => toggleProducto(p.id)}
                        >
                          <td className="px-4 py-3">
                            <input
                              type="checkbox"
                              checked={seleccionado}
                              onChange={() => toggleProducto(p.id)}
                              onClick={e => e.stopPropagation()}
                              aria-label={`Seleccionar ${p.nombre}`}
                              className="w-4 h-4 accent-indigo-600 cursor-pointer"
                            />
                          </td>
                          <td className="px-4 py-3">
                            <div className="font-medium text-gray-800 dark:text-gray-100">{p.nombre}</div>
                            {p.codigo && (
                              <div className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">{p.codigo}</div>
                            )}
                          </td>
                          <td className="px-4 py-3 text-gray-600 dark:text-gray-400 hidden sm:table-cell">
                            {p.proveedor_id ? proveedoresMap.get(p.proveedor_id) ?? '—' : '—'}
                          </td>
                          <td className="px-4 py-3 text-right text-gray-700 dark:text-gray-300 tabular-nums">
                            {p.precio_sin_iva ? formatPrecio(p.precio_sin_iva) : '—'}
                          </td>
                          <td className="px-4 py-3 text-right font-semibold text-gray-800 dark:text-gray-100 tabular-nums">
                            {formatPrecio(p.precio)}
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            </div>

            {/* Escalas mayoristas (#1561, CAT-7) */}
            {productosSeleccionados.length > 0 && politica.isError && (
              <div role="alert" className="flex items-start gap-2 rounded-lg border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-900/20 p-3 text-sm text-red-700 dark:text-red-300">
                <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5" aria-hidden="true" />
                <span>
                  No se pudo cargar la política comercial, y sin ella no se sabe a qué múltiplo redondear.{' '}
                  <button type="button" className="underline font-medium" onClick={() => { void politica.refetch() }}>Reintentar</button>
                </span>
              </div>
            )}
            {productosSeleccionados.length > 0 && grupos.isError && (
              <div role="alert" className="flex items-start gap-2 rounded-lg border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-900/20 p-3 text-sm text-red-700 dark:text-red-300">
                <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5" aria-hidden="true" />
                <span>
                  No se pudieron cargar las condiciones mayoristas, y sin ellas no se sabe qué escalas tienen estos productos.{' '}
                  <button type="button" className="underline font-medium" onClick={() => { void grupos.refetch() }}>Reintentar</button>
                </span>
              </div>
            )}
            {productosSeleccionados.length > 0 && (escalas.aplicables.length > 0 || escalas.parciales > 0) && (
              <div className="rounded-lg border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-900/20 p-3 text-sm text-amber-800 dark:text-amber-200 space-y-2">
                {escalas.aplicables.length > 0 && (
                  <label className="flex items-start gap-2 cursor-pointer">
                    <input
                      type="checkbox"
                      checked={aplicarEscalas}
                      onChange={e => setAplicarEscalas(e.target.checked)}
                      className="w-4 h-4 mt-0.5 accent-indigo-600"
                    />
                    <span>
                      Los productos elegidos tienen <strong>{escalas.aplicables.length}</strong> escala(s) mayorista(s).
                      Aplicarles el mismo porcentaje{porcentajeValido ? ` (${porcentaje > 0 ? '+' : ''}${porcentaje}%)` : ''}.
                      Si no, el descuento por cantidad cambia con el aumento.
                    </span>
                  </label>
                )}
                {escalas.parciales > 0 && (
                  <p className="flex items-start gap-2">
                    <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5" aria-hidden="true" />
                    <span>
                      {escalas.parciales} escala(s) de {escalas.condicionesParciales.join(', ')} no se tocan: esa condición
                      tiene productos que no elegiste, y su escala vale para todos. Revisalas en Condiciones mayoristas.
                    </span>
                  </p>
                )}
              </div>
            )}

            {avisoPrecios && (
              <div role="alert" className="flex items-start gap-2 rounded-lg border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-900/20 p-3 text-sm text-amber-900 dark:text-amber-200">
                <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5" aria-hidden="true" />
                <span>{avisoPrecios}</span>
              </div>
            )}

            {/* Preview */}
            {productosSeleccionados.length > 0 && porcentajeValido && (
              <div className="bg-gray-50 dark:bg-gray-800/50 border dark:border-gray-700 rounded-lg p-4">
                <p className="text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-400 mb-3">
                  Vista previa — precio final ({Math.min(PREVIEW_LIMIT, productosSeleccionados.length)} de {productosSeleccionados.length})
                </p>
                <ul className="space-y-1.5 text-sm">
                  {previewItems.map(({ producto, nuevos }) => (
                    <li key={producto.id} className="flex items-center justify-between text-gray-700 dark:text-gray-300 gap-3">
                      <span className="truncate">{producto.nombre}</span>
                      <span className="font-mono tabular-nums whitespace-nowrap text-gray-500 dark:text-gray-400">
                        {formatPrecio(producto.precio)}
                        <span className="mx-1.5 text-gray-400">→</span>
                        <span className={`font-semibold ${porcentaje >= 0 ? 'text-green-700 dark:text-green-400' : 'text-red-700 dark:text-red-400'}`}>
                          {nuevos.precio_final !== null ? formatPrecio(nuevos.precio_final) : '—'}
                        </span>
                      </span>
                    </li>
                  ))}
                </ul>
                {algunoQuedaEnCero && (
                  <div className="mt-3 flex items-start gap-2 text-xs text-yellow-700 dark:text-yellow-400">
                    <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5" aria-hidden="true" />
                    <span>Algún producto seleccionado queda en $0 tras el redondeo. Revisalo antes de aplicar.</span>
                  </div>
                )}
              </div>
            )}
          </div>

          {/* Footer sticky */}
          <div className="sticky bottom-0 flex justify-end gap-2 px-5 sm:px-6 py-4 bg-white dark:bg-gray-800 border-t dark:border-gray-700">
            <Button type="button" variant="ghost" size="md" onClick={onClose}>
              Cancelar
            </Button>
            <Button
              type="button"
              variant="primary"
              size="md"
              onClick={handleAplicar}
              disabled={!puedeAplicar}
              className="shadow-sm"
            >
              {mutation.isPending ? 'Aplicando...' : verificando ? 'Verificando precios...' : 'Aplicar'}
            </Button>
          </div>
        </div>

        {confirmOpen && (
          <Suspense fallback={null}>
            <ModalConfirmacion
              config={{
                visible: true,
                tipo: 'warning',
                titulo: 'Confirmar actualización',
                mensaje: mensajeConfirmacion,
                onConfirm: handleConfirmar,
              }}
              onClose={() => setConfirmOpen(false)}
            />
          </Suspense>
        )}
    </ModalBase>
  )
}
