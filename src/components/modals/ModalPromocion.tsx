/**
 * ModalPromocion
 *
 * Modal para crear/editar una promocion de bonificacion.
 * Incluye: nombre, fechas, selector de productos, reglas (cantidad_compra, cantidad_bonificacion).
 */
import { useState, useMemo } from 'react'
import { X, Search, Gift, ChevronDown, ChevronRight, Layers, Ban, Package, Droplet } from 'lucide-react'
import { fechaLocalISO } from '../../utils/formatters'
import type { ProductoDB } from '../../types'
import type { PromocionConDetalles, PromocionFormInput } from '../../hooks/queries/usePromocionesQuery'

export interface ModalPromocionProps {
  promocion: PromocionConDetalles | null
  productos: ProductoDB[]
  onSave: (data: PromocionFormInput) => Promise<{ success: boolean; error?: string }>
  onClose: () => void
}

export default function ModalPromocion({
  promocion,
  productos,
  onSave,
  onClose,
}: ModalPromocionProps) {
  const isEditing = !!promocion

  const [nombre, setNombre] = useState(promocion?.nombre || '')
  const [fechaInicio, setFechaInicio] = useState(promocion?.fecha_inicio || fechaLocalISO())
  const [fechaFin, setFechaFin] = useState(promocion?.fecha_fin || '')
  const [productoIds, setProductoIds] = useState<Set<string>>(
    new Set(promocion?.productos.map(p => String(p.producto_id)) || [])
  )
  const [cantidadCompra, setCantidadCompra] = useState(
    () => {
      const regla = promocion?.reglas.find(r => r.clave === 'cantidad_compra')
      return regla ? String(Number(regla.valor)) : ''
    }
  )
  const [cantidadBonificacion, setCantidadBonificacion] = useState(
    () => {
      const regla = promocion?.reglas.find(r => r.clave === 'cantidad_bonificacion')
      return regla ? String(Number(regla.valor)) : ''
    }
  )
  const [productoRegaloId, setProductoRegaloId] = useState<string>(
    promocion?.producto_regalo_id ? String(promocion.producto_regalo_id) : ''
  )
  const [limiteUsos, setLimiteUsos] = useState<string>(
    promocion?.limite_usos ? String(promocion.limite_usos) : ''
  )
  const [prioridad, setPrioridad] = useState<string>(
    promocion?.prioridad != null ? String(promocion.prioridad) : '0'
  )
  const [modoExclusion, setModoExclusion] = useState<'acumulable' | 'excluyente'>(
    (promocion?.modo_exclusion as 'acumulable' | 'excluyente') ?? 'acumulable'
  )
  const [ajusteProductoId, setAjusteProductoId] = useState<string>(
    promocion?.ajuste_producto_id ? String(promocion.ajuste_producto_id) : ''
  )
  const [unidadesPorBloque, setUnidadesPorBloque] = useState<string>(
    promocion?.unidades_por_bloque ? String(promocion.unidades_por_bloque) : ''
  )
  const [stockPorBloque, setStockPorBloque] = useState<string>(
    promocion?.stock_por_bloque ? String(promocion.stock_por_bloque) : '1'
  )
  const [descripcionRegalo, setDescripcionRegalo] = useState<string>(
    promocion?.descripcion_regalo ?? ''
  )
  // Derivar tipo al abrir en modo edicion: promos con ajuste_automatico o
  // descripcion_regalo cargada se tratan como fracción. Las nuevas arrancan
  // como unidad entera (el modo clásico).
  const [tipoRegalo, setTipoRegalo] = useState<'unidad_entera' | 'fraccion'>(
    (promocion?.ajuste_automatico || (promocion?.descripcion_regalo ?? '').length > 0)
      ? 'fraccion'
      : 'unidad_entera'
  )
  const [busquedaAjusteProd, setBusquedaAjusteProd] = useState('')
  const [mostrarAvanzadas, setMostrarAvanzadas] = useState(false)
  const [busqueda, setBusqueda] = useState('')
  const [busquedaRegalo, setBusquedaRegalo] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const productosFiltrados = useMemo(() => {
    if (!busqueda.trim()) return productos
    const q = busqueda.toLowerCase()
    return productos.filter(p =>
      p.nombre.toLowerCase().includes(q) ||
      p.codigo?.toLowerCase().includes(q)
    )
  }, [productos, busqueda])

  const productosRegaloFiltrados = useMemo(() => {
    if (!busquedaRegalo.trim()) return productos
    const q = busquedaRegalo.toLowerCase()
    return productos.filter(p =>
      p.nombre.toLowerCase().includes(q) ||
      p.codigo?.toLowerCase().includes(q)
    )
  }, [productos, busquedaRegalo])

  const productosAjusteFiltrados = useMemo(() => {
    if (!busquedaAjusteProd.trim()) return productos
    const q = busquedaAjusteProd.toLowerCase()
    return productos.filter(p =>
      p.nombre.toLowerCase().includes(q) ||
      p.codigo?.toLowerCase().includes(q)
    )
  }, [productos, busquedaAjusteProd])

  const handleToggleProducto = (id: string) => {
    setProductoIds(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const handleSubmit = async () => {
    setError(null)

    if (!nombre.trim()) {
      setError('Ingresa un nombre para la promocion')
      return
    }
    if (!fechaInicio) {
      setError('Selecciona una fecha de inicio')
      return
    }
    if (productoIds.size === 0) {
      setError('Selecciona al menos un producto')
      return
    }
    const compra = parseInt(cantidadCompra)
    const bonif = parseInt(cantidadBonificacion)
    if (!compra || compra <= 0) {
      setError('Ingresa la cantidad de compra (mayor a 0)')
      return
    }
    if (!bonif || bonif <= 0) {
      setError('Ingresa la cantidad de bonificacion (mayor a 0)')
      return
    }

    // Derivados segun tipo de regalo.
    // - Fraccion: ajuste_automatico=true (descuenta fardo al cerrar bloque),
    //   regalo_mueve_stock=false (no descuenta al entregar la botella suelta).
    // - Unidad entera: ajuste_automatico=false, regalo_mueve_stock=true
    //   (el stock se descuenta al entregar cada unidad completa).
    const esFraccion = tipoRegalo === 'fraccion'
    const finalAjusteAutomatico = esFraccion
    const finalRegaloMueveStock = !esFraccion

    if (esFraccion) {
      if (!descripcionRegalo.trim()) {
        setError('Escribí una descripción del regalo (ej: "1 botella Manaos Naranja 600cc")')
        return
      }
      if (!ajusteProductoId) {
        setError('Seleccioná el producto que se descuenta del stock (ej: el fardo que contiene las botellas)')
        return
      }
      const unidBloque = parseInt(unidadesPorBloque)
      if (!unidBloque || unidBloque <= 0) {
        setError('Ingresá cuántas unidades bonificadas forman un bloque (ej: 12 botellas = 1 fardo)')
        return
      }
      const stockBloque = parseInt(stockPorBloque)
      if (!stockBloque || stockBloque <= 0) {
        setError('Ingresá cuánto stock descuenta cada bloque (normalmente 1)')
        return
      }
    }

    setSaving(true)
    const limite = limiteUsos ? parseInt(limiteUsos) : null
    const prio = parseInt(prioridad)
    const unidBloque = parseInt(unidadesPorBloque)
    const stockBloque = parseInt(stockPorBloque)
    const result = await onSave({
      nombre: nombre.trim(),
      tipo: 'bonificacion',
      fechaInicio,
      fechaFin: fechaFin || null,
      limiteUsos: limite && limite > 0 ? limite : null,
      productoIds: Array.from(productoIds),
      productoRegaloId: productoRegaloId || null,
      reglas: [
        { clave: 'cantidad_compra', valor: compra },
        { clave: 'cantidad_bonificacion', valor: bonif },
      ],
      prioridad: Number.isFinite(prio) ? prio : 0,
      regaloMueveStock: finalRegaloMueveStock,
      modoExclusion,
      ajusteAutomatico: finalAjusteAutomatico,
      ajusteProductoId: finalAjusteAutomatico ? (ajusteProductoId || null) : null,
      unidadesPorBloque: finalAjusteAutomatico && Number.isFinite(unidBloque) && unidBloque > 0 ? unidBloque : null,
      stockPorBloque: finalAjusteAutomatico && Number.isFinite(stockBloque) && stockBloque > 0 ? stockBloque : null,
      descripcionRegalo: esFraccion ? descripcionRegalo.trim() : null,
    })
    setSaving(false)

    if (!result.success && result.error) {
      setError(result.error)
    }
  }

  return (
    <div className="fixed inset-0 bg-black/50 z-50 flex items-center justify-center p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-lg max-h-[90vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b dark:border-gray-700">
          <h2 className="text-lg font-semibold dark:text-white">
            {isEditing ? 'Editar Promocion' : 'Nueva Promocion'}
          </h2>
          <button onClick={onClose} className="p-1 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
            <X className="w-5 h-5 text-gray-500" />
          </button>
        </div>

        {/* Body */}
        <div className="flex-1 overflow-y-auto px-5 py-4 space-y-4">
          {/* Nombre */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Nombre</label>
            <input
              type="text"
              value={nombre}
              onChange={e => setNombre(e.target.value)}
              placeholder="Ej: Promo Manaos 12+2"
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none"
            />
          </div>

          {/* Fechas */}
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Fecha inicio</label>
              <input
                type="date"
                value={fechaInicio}
                onChange={e => setFechaInicio(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Fecha fin (opcional)</label>
              <input
                type="date"
                value={fechaFin}
                onChange={e => setFechaFin(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none"
              />
            </div>
          </div>

          {/* Limite de usos (hasta agotar stock) */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Limite de usos (opcional)
            </label>
            <input
              type="number"
              inputMode="numeric"
              step="1"
              min="1"
              value={limiteUsos}
              onChange={e => setLimiteUsos(e.target.value)}
              placeholder="Sin limite"
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none text-sm"
            />
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
              Se desactiva automaticamente al alcanzar este numero de bonificaciones entregadas. Dejar vacio para sin limite.
            </p>
          </div>

          {/* Modo de exclusion: acumulable vs excluyente */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
              ¿Cómo convive con otras promos?
            </label>
            <div className="grid grid-cols-2 gap-2">
              <button
                type="button"
                onClick={() => setModoExclusion('acumulable')}
                className={`flex items-start gap-2 p-3 rounded-lg border text-left transition ${
                  modoExclusion === 'acumulable'
                    ? 'bg-purple-50 dark:bg-purple-900/30 border-purple-400 dark:border-purple-600 ring-2 ring-purple-200 dark:ring-purple-800'
                    : 'bg-white dark:bg-gray-700 border-gray-200 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-600'
                }`}
              >
                <Layers className={`w-4 h-4 mt-0.5 flex-shrink-0 ${modoExclusion === 'acumulable' ? 'text-purple-600 dark:text-purple-400' : 'text-gray-400'}`} />
                <div className="flex-1">
                  <p className={`text-sm font-medium ${modoExclusion === 'acumulable' ? 'text-purple-700 dark:text-purple-300' : 'text-gray-700 dark:text-gray-300'}`}>
                    Acumulable
                  </p>
                  <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                    Se aplica junto con otras promos del pedido.
                  </p>
                </div>
              </button>
              <button
                type="button"
                onClick={() => setModoExclusion('excluyente')}
                className={`flex items-start gap-2 p-3 rounded-lg border text-left transition ${
                  modoExclusion === 'excluyente'
                    ? 'bg-purple-50 dark:bg-purple-900/30 border-purple-400 dark:border-purple-600 ring-2 ring-purple-200 dark:ring-purple-800'
                    : 'bg-white dark:bg-gray-700 border-gray-200 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-600'
                }`}
              >
                <Ban className={`w-4 h-4 mt-0.5 flex-shrink-0 ${modoExclusion === 'excluyente' ? 'text-purple-600 dark:text-purple-400' : 'text-gray-400'}`} />
                <div className="flex-1">
                  <p className={`text-sm font-medium ${modoExclusion === 'excluyente' ? 'text-purple-700 dark:text-purple-300' : 'text-gray-700 dark:text-gray-300'}`}>
                    Excluyente
                  </p>
                  <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                    Si choca con otra excluyente, gana la de mayor cantidad.
                  </p>
                </div>
              </button>
            </div>
            {modoExclusion === 'excluyente' && (
              <p className="text-xs text-gray-500 dark:text-gray-400 mt-2">
                Ejemplo: si tenés una promo "2+2 botellas" y otra "3+1 fardo" excluyentes sobre el mismo producto, al pedir 3 fardos gana la 3+1 (tier más alto). Con sólo 2 fardos, aplica la 2+2.
              </p>
            )}
          </div>

          {/* Tipo de regalo: unidad entera vs fracción */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
              ¿Qué se regala?
            </label>
            <div className="grid grid-cols-2 gap-2">
              <button
                type="button"
                onClick={() => setTipoRegalo('unidad_entera')}
                className={`flex items-start gap-2 p-3 rounded-lg border text-left transition ${
                  tipoRegalo === 'unidad_entera'
                    ? 'bg-emerald-50 dark:bg-emerald-900/30 border-emerald-400 dark:border-emerald-600 ring-2 ring-emerald-200 dark:ring-emerald-800'
                    : 'bg-white dark:bg-gray-700 border-gray-200 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-600'
                }`}
              >
                <Package className={`w-4 h-4 mt-0.5 flex-shrink-0 ${tipoRegalo === 'unidad_entera' ? 'text-emerald-600 dark:text-emerald-400' : 'text-gray-400'}`} />
                <div className="flex-1">
                  <p className={`text-sm font-medium ${tipoRegalo === 'unidad_entera' ? 'text-emerald-700 dark:text-emerald-300' : 'text-gray-700 dark:text-gray-300'}`}>
                    Unidad entera
                  </p>
                  <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                    Se regala el producto tal como figura en el stock (ej: 1 fardo).
                  </p>
                </div>
              </button>
              <button
                type="button"
                onClick={() => setTipoRegalo('fraccion')}
                className={`flex items-start gap-2 p-3 rounded-lg border text-left transition ${
                  tipoRegalo === 'fraccion'
                    ? 'bg-emerald-50 dark:bg-emerald-900/30 border-emerald-400 dark:border-emerald-600 ring-2 ring-emerald-200 dark:ring-emerald-800'
                    : 'bg-white dark:bg-gray-700 border-gray-200 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-600'
                }`}
              >
                <Droplet className={`w-4 h-4 mt-0.5 flex-shrink-0 ${tipoRegalo === 'fraccion' ? 'text-emerald-600 dark:text-emerald-400' : 'text-gray-400'}`} />
                <div className="flex-1">
                  <p className={`text-sm font-medium ${tipoRegalo === 'fraccion' ? 'text-emerald-700 dark:text-emerald-300' : 'text-gray-700 dark:text-gray-300'}`}>
                    Fracción de unidad
                  </p>
                  <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                    Se regala una parte del producto (ej: 1 botella de un fardo x12). El stock se descuenta por bloques completos.
                  </p>
                </div>
              </button>
            </div>
          </div>

          {/* Descripción manual del regalo (solo fracción) */}
          {tipoRegalo === 'fraccion' && (
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Descripción del regalo <span className="text-red-500">*</span>
              </label>
              <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">
                Texto que aparece en la tarjeta del pedido. Ej: "1 botella Manaos Naranja 600cc".
              </p>
              <input
                type="text"
                value={descripcionRegalo}
                onChange={e => setDescripcionRegalo(e.target.value)}
                placeholder='Ej: 1 botella Manaos Naranja 600cc'
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-emerald-500 focus:outline-none"
              />
            </div>
          )}

          {/* Regla de bonificación — layout fracción (incluye producto contenedor, bloque y cantidades) */}
          {tipoRegalo === 'fraccion' && (
            <div className="p-3 bg-blue-50 dark:bg-blue-900/20 rounded-lg border border-blue-200 dark:border-blue-800 space-y-3">
              <div>
                <p className="text-sm font-medium text-blue-800 dark:text-blue-200">
                  Regla de bonificación
                </p>
                <p className="text-xs text-blue-700 dark:text-blue-300 mt-1">
                  Al acumularse las unidades sueltas hasta formar un bloque exacto (ej: 12 botellas = 1 fardo), el sistema descuenta el stock del producto contenedor y registra la merma automáticamente.
                </p>
              </div>

              <div className="space-y-3 pt-2 border-t border-blue-200 dark:border-blue-800">
                  {/* Producto a descontar */}
                  <div>
                    <label className="block text-xs font-medium text-blue-700 dark:text-blue-300 mb-1">
                      Producto del que se descuenta el stock
                    </label>
                    {ajusteProductoId && (
                      <div className="flex items-center gap-2 mb-2 px-3 py-2 bg-white dark:bg-gray-700 border border-blue-200 dark:border-blue-700 rounded-lg">
                        <span className="text-sm text-gray-700 dark:text-gray-200 flex-1 truncate">
                          {productos.find(p => String(p.id) === ajusteProductoId)?.nombre || `Producto #${ajusteProductoId}`}
                        </span>
                        <button
                          onClick={() => setAjusteProductoId('')}
                          className="text-blue-600 hover:text-blue-800 text-xs underline"
                        >
                          Cambiar
                        </button>
                      </div>
                    )}
                    {!ajusteProductoId && (
                      <>
                        <div className="relative mb-1">
                          <Search className="absolute left-3 top-2.5 w-4 h-4 text-gray-400" />
                          <input
                            type="text"
                            value={busquedaAjusteProd}
                            onChange={e => setBusquedaAjusteProd(e.target.value)}
                            placeholder="Buscar producto (ej: fardo)..."
                            className="w-full pl-9 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none text-sm"
                          />
                        </div>
                        {busquedaAjusteProd.trim() && (
                          <div className="max-h-32 overflow-y-auto border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700 bg-white dark:bg-gray-700">
                            {productosAjusteFiltrados.map(prod => (
                              <button
                                key={prod.id}
                                onClick={() => { setAjusteProductoId(String(prod.id)); setBusquedaAjusteProd('') }}
                                className="w-full text-left flex items-center gap-2 px-3 py-2 hover:bg-blue-50 dark:hover:bg-blue-900/20 text-sm"
                              >
                                <span className="dark:text-white truncate">{prod.nombre}</span>
                                {prod.codigo && (
                                  <span className="text-xs text-gray-400 ml-auto shrink-0">{prod.codigo}</span>
                                )}
                              </button>
                            ))}
                            {productosAjusteFiltrados.length === 0 && (
                              <p className="text-sm text-gray-400 px-3 py-4 text-center">Sin resultados</p>
                            )}
                          </div>
                        )}
                      </>
                    )}
                  </div>

                  {/* Unidades por bloque y Stock por bloque */}
                  <div className="grid grid-cols-2 gap-3">
                    <div>
                      <label className="block text-xs font-medium text-blue-700 dark:text-blue-300 mb-1">
                        Unidades bonificadas por bloque
                      </label>
                      <input
                        type="number"
                        inputMode="numeric"
                        step="1"
                        min="1"
                        value={unidadesPorBloque}
                        onChange={e => setUnidadesPorBloque(e.target.value)}
                        placeholder="Ej: 12"
                        className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none text-sm"
                      />
                      <p className="text-[11px] text-blue-600 dark:text-blue-400 mt-1">
                        Cuántas unidades regaladas forman un bloque.
                      </p>
                    </div>
                    <div>
                      <label className="block text-xs font-medium text-blue-700 dark:text-blue-300 mb-1">
                        Stock descontado por bloque
                      </label>
                      <input
                        type="number"
                        inputMode="numeric"
                        step="1"
                        min="1"
                        value={stockPorBloque}
                        onChange={e => setStockPorBloque(e.target.value)}
                        placeholder="Ej: 1"
                        className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none text-sm"
                      />
                      <p className="text-[11px] text-blue-600 dark:text-blue-400 mt-1">
                        Cuánto se descuenta por cada bloque (normalmente 1).
                      </p>
                    </div>
                  </div>

                  {/* Cantidad compra y cantidad gratis (dentro del bloque fracción) */}
                  <div className="grid grid-cols-2 gap-3 pt-2 border-t border-blue-200 dark:border-blue-800">
                    <div>
                      <label className="block text-xs font-medium text-blue-700 dark:text-blue-300 mb-1">
                        Cantidad compra
                      </label>
                      <input
                        type="number"
                        inputMode="numeric"
                        step="1"
                        min="1"
                        value={cantidadCompra}
                        onChange={e => setCantidadCompra(e.target.value)}
                        placeholder="Ej: 2"
                        className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none text-sm"
                      />
                    </div>
                    <div>
                      <label className="block text-xs font-medium text-blue-700 dark:text-blue-300 mb-1">
                        Cantidad gratis
                      </label>
                      <input
                        type="number"
                        inputMode="numeric"
                        step="1"
                        min="1"
                        value={cantidadBonificacion}
                        onChange={e => setCantidadBonificacion(e.target.value)}
                        placeholder="Ej: 1"
                        className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none text-sm"
                      />
                    </div>
                  </div>

                  {cantidadCompra && cantidadBonificacion && unidadesPorBloque && stockPorBloque
                    && parseInt(cantidadCompra) > 0 && parseInt(cantidadBonificacion) > 0
                    && parseInt(unidadesPorBloque) > 0 && parseInt(stockPorBloque) > 0 && (
                    <p className="text-xs text-blue-700 dark:text-blue-300 bg-blue-100 dark:bg-blue-900/40 rounded px-2 py-1.5">
                      Resumen: cada {cantidadCompra} unidades compradas → {cantidadBonificacion} gratis ({descripcionRegalo.trim() || 'unidad fraccionada'}). Cada {unidadesPorBloque} unidades regaladas descuentan {stockPorBloque} del stock del producto contenedor.
                    </p>
                  )}
              </div>
            </div>
          )}

          {/* Regla de bonificacion — layout unidad entera */}
          {tipoRegalo === 'unidad_entera' && (
            <div className="p-3 bg-purple-50 dark:bg-purple-900/20 rounded-lg border border-purple-200 dark:border-purple-800">
              <p className="text-sm font-medium text-purple-700 dark:text-purple-300 mb-2">Regla de bonificación</p>
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs text-purple-600 dark:text-purple-400 mb-1">Cantidad compra</label>
                  <input
                    type="number"
                    inputMode="numeric"
                    step="1"
                    min="1"
                    value={cantidadCompra}
                    onChange={e => setCantidadCompra(e.target.value)}
                    placeholder="Ej: 12"
                    className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none text-sm"
                  />
                </div>
                <div>
                  <label className="block text-xs text-purple-600 dark:text-purple-400 mb-1">Cantidad gratis</label>
                  <input
                    type="number"
                    inputMode="numeric"
                    step="1"
                    min="1"
                    value={cantidadBonificacion}
                    onChange={e => setCantidadBonificacion(e.target.value)}
                    placeholder="Ej: 2"
                    className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none text-sm"
                  />
                </div>
              </div>
              {cantidadCompra && cantidadBonificacion && parseInt(cantidadCompra) > 0 && parseInt(cantidadBonificacion) > 0 && (
                <p className="text-xs text-purple-600 mt-2">
                  Cada {cantidadCompra} unidades compradas → {cantidadBonificacion} gratis (acumulable)
                </p>
              )}
            </div>
          )}

          {/* Producto regalo (solo unidad entera) */}
          {tipoRegalo === 'unidad_entera' && (
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Producto de regalo
            </label>
            <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">
              El producto que se entrega gratis al cumplir la condicion
            </p>
            {productoRegaloId && (
              <div className="flex items-center gap-2 mb-2 px-3 py-2 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg">
                <Gift className="w-4 h-4 text-green-600 flex-shrink-0" />
                <span className="text-sm text-green-700 dark:text-green-300 font-medium flex-1">
                  {productos.find(p => String(p.id) === productoRegaloId)?.nombre || `Producto #${productoRegaloId}`}
                </span>
                <button
                  onClick={() => setProductoRegaloId('')}
                  className="text-green-600 hover:text-green-800 text-xs underline"
                >
                  Quitar
                </button>
              </div>
            )}
            <div className="relative mb-2">
              <Search className="absolute left-3 top-2.5 w-4 h-4 text-gray-400" />
              <input
                type="text"
                value={busquedaRegalo}
                onChange={e => setBusquedaRegalo(e.target.value)}
                placeholder="Buscar producto de regalo..."
                className="w-full pl-9 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-green-500 focus:outline-none text-sm"
              />
            </div>
            {busquedaRegalo.trim() && (
              <div className="max-h-32 overflow-y-auto border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700">
                {productosRegaloFiltrados.map(prod => (
                  <button
                    key={prod.id}
                    onClick={() => { setProductoRegaloId(String(prod.id)); setBusquedaRegalo('') }}
                    className={`w-full text-left flex items-center gap-2 px-3 py-2 hover:bg-green-50 dark:hover:bg-green-900/20 text-sm ${
                      String(prod.id) === productoRegaloId ? 'bg-green-50 dark:bg-green-900/20' : ''
                    }`}
                  >
                    <Gift className="w-3.5 h-3.5 text-green-500 flex-shrink-0" />
                    <span className="dark:text-white truncate">{prod.nombre}</span>
                  </button>
                ))}
                {productosRegaloFiltrados.length === 0 && (
                  <p className="text-sm text-gray-400 px-3 py-4 text-center">Sin resultados</p>
                )}
              </div>
            )}
          </div>
          )}

          {/* Selector de productos (que activan la promo) */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Productos que activan la promo ({productoIds.size} seleccionados)
            </label>
            <div className="relative mb-2">
              <Search className="absolute left-3 top-2.5 w-4 h-4 text-gray-400" />
              <input
                type="text"
                value={busqueda}
                onChange={e => setBusqueda(e.target.value)}
                placeholder="Buscar producto..."
                className="w-full pl-9 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none text-sm"
              />
            </div>
            <div className="max-h-48 overflow-y-auto border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700">
              {productosFiltrados.map(prod => {
                const selected = productoIds.has(String(prod.id))
                return (
                  <label
                    key={prod.id}
                    className={`flex items-center gap-2 px-3 py-2 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700 ${
                      selected ? 'bg-purple-50 dark:bg-purple-900/20' : ''
                    }`}
                  >
                    <input
                      type="checkbox"
                      checked={selected}
                      onChange={() => handleToggleProducto(String(prod.id))}
                      className="rounded border-gray-300 text-purple-600 focus:ring-purple-500"
                    />
                    <span className="text-sm dark:text-white truncate">{prod.nombre}</span>
                    {prod.codigo && (
                      <span className="text-xs text-gray-400 ml-auto shrink-0">{prod.codigo}</span>
                    )}
                  </label>
                )
              })}
              {productosFiltrados.length === 0 && (
                <p className="text-sm text-gray-400 px-3 py-4 text-center">Sin resultados</p>
              )}
            </div>
          </div>

          {/* Opciones avanzadas (collapsible) */}
          <div className="border-t dark:border-gray-700 pt-3">
            <button
              type="button"
              onClick={() => setMostrarAvanzadas(v => !v)}
              className="flex items-center gap-1.5 text-sm text-gray-600 dark:text-gray-400 hover:text-gray-800 dark:hover:text-gray-200"
            >
              {mostrarAvanzadas ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
              <span>Opciones avanzadas</span>
            </button>
            {mostrarAvanzadas && (
              <div className="mt-3 pl-1">
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                  Prioridad (desempate entre excluyentes)
                </label>
                <input
                  type="number"
                  inputMode="numeric"
                  step="1"
                  value={prioridad}
                  onChange={e => setPrioridad(e.target.value)}
                  placeholder="0"
                  className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none text-sm"
                />
                <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                  Sólo se usa entre promos <strong>excluyentes</strong> con igual cantidad de compra. Gana la de mayor prioridad. Casi nunca hace falta tocarlo.
                </p>
              </div>
            )}
          </div>

          {error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 text-red-600 dark:text-red-400 text-sm rounded-lg">
              {error}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex justify-end gap-2 px-5 py-4 border-t dark:border-gray-700">
          <button
            onClick={onClose}
            className="px-4 py-2 text-sm text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg"
          >
            Cancelar
          </button>
          <button
            onClick={handleSubmit}
            disabled={saving}
            className="px-4 py-2 text-sm bg-purple-600 text-white rounded-lg hover:bg-purple-700 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {saving ? 'Guardando...' : isEditing ? 'Actualizar' : 'Crear Promocion'}
          </button>
        </div>
      </div>
    </div>
  )
}
