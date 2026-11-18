/**
 * ModalSustituirRegalo
 *
 * Permite a un admin/encargado cambiar el producto de un item bonificacion
 * en un pedido (regalo de una promocion). Justifica con motivo y autoriza
 * la operacion.
 *
 * Diseno didactico (rediseno mig 063):
 *   - Solo 3 campos visibles: producto nuevo, cantidad, motivo.
 *   - Banner explica en lenguaje de negocio con NUMEROS REALES del caso
 *     (nombres de productos, barra de progreso actual y proyectada). Sin
 *     jerga tecnica "Modo A/B", "fardo", "acumulador", "contenedor" en
 *     la vista principal.
 *   - El campo "contenedor del sustituto" se esconde en "Configuracion
 *     avanzada" (collapsible). Default: el propio producto sustituto
 *     (auto-inferido por el RPC con mig 063 si se manda NULL).
 *
 * Llama a la RPC `sustituir_regalo_pedido` via useSustituirRegaloMutation.
 * Maneja idempotencia (UUID generado en el primer render).
 *
 * Reparto en sabores (mig 275, #831): con "Repartir en otro sabor" se agregan
 * filas y el regalo se reparte en N productos cuya suma tiene que ser la
 * cantidad original, en la misma unidad de la linea. Con dos filas o mas se
 * llama a `dividir_regalo_pedido`; con una sola, es la sustitucion de siempre.
 * La validacion vive en `utils/repartoRegalo`.
 *
 * Otro empaque u otro producto (#950): con UNA fila, el admin puede elegir
 * cualquier producto operativo. Si es de otra categoria/subcategoria o viene en
 * otro empaque, la cantidad se sugiere POR VALOR (precio de lista por unidad
 * suelta) y el admin la puede corregir; si es de otra categoria y no tiene
 * cargadas sus unidades sueltas por unidad de stock, no deja confirmar. El
 * reparto (dos filas o mas) sigue en la misma categoria. La cuenta vive en
 * `utils/regaloOtroEmpaque`.
 */
import { useMemo, useState, memo } from 'react'
import { Gift, AlertTriangle, ChevronDown, ChevronUp, Info, Plus, Trash2 } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import NumberInput from '../ui/NumberInput'
import { Combobox } from '../ui/Combobox'
import { useProductosQuery, usePromoAcumuladorQuery } from '../../hooks/queries'
import { useSustituirRegaloMutation, useDividirRegaloMutation, useCorteRegaloQuery } from '../../hooks/queries/useSustituirRegaloMutation'
import { validarRepartoRegalo, type ParteReparto } from '../../utils/repartoRegalo'
import { nuevoRequestId } from '../../utils/idempotencia'
import { useNotification } from '../../contexts/NotificationContext'
import { filtrarProductosOperativos, esProductoOperativo } from '../../utils/productosOperativos'
import { filtrarRegalosCompatibles, esRegaloCompatible, TEXTO_REGALO_MISMA_CATEGORIA } from '../../utils/regaloCompatible'
import { evaluarCambioRegalo, topeSustitutoRegalo } from '../../utils/regaloOtroEmpaque'
import { formatPrecio } from '../../utils/formatters'
import type { ProductoDB } from '../../types'
import type { CambioDeVersion } from '../../utils/versionPedido'
import { RegistroIlegiblesContext, useRegistroIlegibles } from '../../hooks/useRegistroIlegibles'
import { AvisoCamposEnRojo } from '../ui/AvisoCamposEnRojo'
import { useClavesDeRenglones } from '../../hooks/useClavesDeRenglones'

export interface ModalSustituirRegaloProps {
  pedidoItemId: string
  productoOriginal: ProductoDB
  cantidadOriginal: number
  /** Modo de la promo. true = stock por unidad, false = ajuste por bloque. */
  regaloMueveStock: boolean
  /** Promo asociada al regalo. Necesaria para cargar el acumulador. */
  promocionId?: string | number | null
  /** Unidades por bloque de la promo (modo B). Para mostrar X/N en banner. */
  unidadesPorBloque?: number | null
  /** Contenedor configurado en la promo original. Se muestra en avanzado. */
  ajusteProductoIdOriginal?: string | null
  /**
   * Factor de la linea (congelado, `factorDeLaLinea`): en que unidad esta
   * `cantidadOriginal`. Default: 1 en modo A, el de la promo en modo B.
   */
  factorOriginal?: number | null
  /**
   * Solo admin (#950): con una fila puede cambiar el regalo por cualquier
   * producto, no solo por los de la misma categoria. El server lo vuelve a
   * chequear.
   */
  puedeCambiarDeProducto?: boolean
  /**
   * PRM-1 (#1592): el regalo que da la promo (`producto_regalo_id`, o su contenedor) y
   * el factor de su barra (1 si el regalo mueve stock). El server mide el sustituto de
   * quien no es admin contra él, con el corte de la línea, y la pantalla sugiere y topea
   * con la misma cuenta (`topeSustitutoRegalo`). Sin él, la cuenta va contra la línea.
   */
  regaloPromo?: ProductoDB | null
  factorRegaloPromo?: number | null
  onClose: () => void
  /**
   * Callback al confirmar exitosamente (para que el caller refresque). Trae la
   * versión del pedido de antes y la nueva (#1376): la edición abierta por
   * debajo la tiene que adoptar, o su guardado se rechaza contra uno mismo.
   */
  onSustituido?: (version?: CambioDeVersion) => void
}

const ModalSustituirRegalo = memo(function ModalSustituirRegalo({
  pedidoItemId,
  productoOriginal,
  cantidadOriginal,
  regaloMueveStock,
  promocionId = null,
  unidadesPorBloque = null,
  ajusteProductoIdOriginal = null,
  factorOriginal = null,
  puedeCambiarDeProducto = false,
  regaloPromo = null,
  factorRegaloPromo = null,
  onClose,
  onSustituido,
}: ModalSustituirRegaloProps) {
  const notify = useNotification()
  const { data: productos = [] } = useProductosQuery()
  const sustituirMut = useSustituirRegaloMutation()
  // B20: los campos de número en rojo frenan el guardado.
  const ilegibles = useRegistroIlegibles()
  const dividirMut = useDividirRegaloMutation()
  const enviando = sustituirMut.isPending || dividirMut.isPending

  // Acumuladores para mostrar barras "antes" y proyeccion "despues" (modo B)
  const { data: acumuladorOriginal } = usePromoAcumuladorQuery(
    !regaloMueveStock ? promocionId : null,
    productoOriginal.id,
  )

  // UUID estable por instancia del modal para idempotencia
  // Uno por operacion: sustituir y repartir son RPCs distintas que dedupean
  // contra la misma columna, y un reintento de una no puede devolver el replay
  // de la otra ("El reparto ya estaba registrado" sobre una sustitucion).
  const clientRequestIdSustitucion = useMemo(() => nuevoRequestId(), [])
  const clientRequestIdReparto = useMemo(() => nuevoRequestId(), [])

  // Una fila = sustitucion comun. Dos o mas = reparto en sabores.
  const [filas, setFilas] = useState<ParteReparto[]>([
    { productoId: '', cantidad: cantidadOriginal },
  ])
  const esReparto = filas.length > 1
  const productoNuevoId = filas[0]?.productoId ?? ''
  const actualizarFila = (idx: number, cambio: Partial<ParteReparto>) =>
    setFilas(prev => prev.map((f, i) => (i === idx ? { ...f, ...cambio } : f)))
  // T6 de la tercera pasada: claves estables por renglón (con el índice, quitar uno le pasaba el
  // borrador en rojo al de abajo).
  const clavesFilas = useClavesDeRenglones(filas.length)
  const agregarFila = () => {
    setFilas(prev => {
      const asignadas = prev.reduce((acc, f) => acc + (Number(f.cantidad) || 0), 0)
      return [...prev, { productoId: '', cantidad: Math.max(cantidadOriginal - asignadas, 0) }]
    })
    clavesFilas.agregar()
  }
  const quitarFila = (idx: number) => {
    setFilas(prev => prev.filter((_, i) => i !== idx))
    clavesFilas.quitar(idx)
  }
  const [motivo, setMotivo] = useState<string>('')
  const [error, setError] = useState<string>('')
  const [avanzadoOpen, setAvanzadoOpen] = useState<boolean>(false)
  // Contenedor del sustituto. Default vacio = el RPC infiere automaticamente
  // (mig 063): usa el propio producto sustituto como su contenedor. El admin
  // solo lo cambia si abre "Configuracion avanzada" y elige otro fardo.
  const [ajusteProductoIdNuevo, setAjusteProductoIdNuevo] = useState<string>('')

  const productoNuevo = useMemo(
    () => productos.find(p => String(p.id) === String(productoNuevoId)) ?? null,
    [productos, productoNuevoId]
  )

  // Acumulador del sustituto (puede no existir aun)
  const { data: acumuladorSustituto } = usePromoAcumuladorQuery(
    !regaloMueveStock && productoNuevoId ? promocionId : null,
    productoNuevoId || null,
  )

  // Candidatos a regalo: operativos y de la MISMA categoría (y subcategoría) que
  // el original (#950, solución provisoria: el contenedor de la promo descuenta
  // con el factor del empaque original). Sin el original, que entra aparte en
  // `opcionesReparto` aunque esté desactivado.
  const productosOpciones = useMemo(
    () => filtrarRegalosCompatibles(productoOriginal, productos)
      .filter(p => String(p.id) !== String(productoOriginal.id))
      .sort((a, b) => (a.nombre || '').localeCompare(b.nombre || '')),
    [productos, productoOriginal]
  )
  // Contenedor (configuración avanzada): ahí no rige la regla de categoría, es
  // otra decisión (de qué fardo se descuenta).
  const productosContenedor = useMemo(
    () => filtrarProductosOperativos(productos)
      .filter(p => String(p.id) !== String(productoOriginal.id))
      .sort((a, b) => (a.nombre || '').localeCompare(b.nombre || '')),
    [productos, productoOriginal.id]
  )
  // Cambio simple (una fila) hecho por un admin: cualquier operativo (#950). La
  // cantidad se convierte por valor más abajo. Para los demás, la regla de
  // categoría de siempre.
  const productosOpcionesSimple = puedeCambiarDeProducto ? productosContenedor : productosOpciones
  // En un reparto el cliente se puede quedar con parte del sabor original, en su
  // lugar alfabetico (no arriba de todo: quien lo busca por orden no lo encuentra,
  // y "manzana no aparece" fue el reclamo). Si el original se desactivo ya no se
  // puede regalar: no se ofrece y se avisa.
  const originalOperativo = esProductoOperativo(productoOriginal)
  const opcionesReparto = useMemo(
    () => (originalOperativo ? [productoOriginal, ...productosOpciones] : productosOpciones)
      .slice()
      .sort((a, b) => (a.nombre || '').localeCompare(b.nombre || '')),
    [productoOriginal, productosOpciones, originalOperativo]
  )
  const getKeyProducto = (p: ProductoDB) => String(p.id)
  const getLabelProducto = (p: ProductoDB) => p.nombre
  const renderOpcionProducto = (p: ProductoDB) => (
    <>
      {p.nombre}
      {String(p.id) === String(productoOriginal.id)
        ? ' · regalo actual'
        : ((p.stock ?? 0) > 0 ? ` · stock ${p.stock}` : ' · sin stock')}
    </>
  )
  // Radix escucha Escape en captura: con la lista abierta ese Escape es de la lista.
  const handleEscapeKeyDown = (event: KeyboardEvent) => {
    const enfocado = document.activeElement
    if (enfocado?.getAttribute('role') === 'combobox' && enfocado.getAttribute('aria-expanded') === 'true') {
      event.preventDefault()
    }
  }

  // ── Otro empaque / otro producto (#950), solo en el cambio simple ──
  const factorLinea = factorOriginal && factorOriginal > 0
    ? factorOriginal
    : (regaloMueveStock ? 1 : (unidadesPorBloque ?? 1))
  const buscarProducto = (id: string | number | null | undefined) =>
    id == null || id === '' ? null : (productos.find(p => String(p.id) === String(id)) ?? null)
  // De qué producto se va a descontar el sustituto: su barra si ya tiene, el
  // elegido en "avanzado", o él mismo (la misma regla que el server).
  const contenedorDe = (sustitutoId: string, ajusteElegido: string) =>
    buscarProducto(
      acumuladorSustituto && String(acumuladorSustituto.producto_regalo_id) === String(sustitutoId)
        ? (acumuladorSustituto.ajuste_producto_id ?? sustitutoId)
        : (ajusteElegido || sustitutoId)
    )
  // PRM-1 (#1592): el regalo que da la promo con el corte de la línea (lo que cuenta el
  // cupo), contra el que el server mide el sustituto. Sin el corte, la cantidad de la línea.
  const { data: corteLinea } = useCorteRegaloQuery(pedidoItemId)
  const corte = corteLinea ?? cantidadOriginal
  const referencia = regaloPromo
    ? { regalo: regaloPromo, factor: regaloMueveStock ? 1 : (factorRegaloPromo && factorRegaloPromo > 0 ? factorRegaloPromo : 1), corte }
    : null
  const esAdmin = puedeCambiarDeProducto
  const evaluar = (sustitutoId: string, ajusteElegido: string) => {
    const sustituto = buscarProducto(sustitutoId)
    if (!sustituto) return null
    return evaluarCambioRegalo({
      original: productoOriginal,
      sustituto,
      contenedorSustituto: regaloMueveStock ? null : contenedorDe(sustitutoId, ajusteElegido),
      cantidadOriginal,
      factorOriginal: factorLinea,
      regaloMueveStock,
      unidadesPorBloquePromo: unidadesPorBloque,
      referencia,
    })
  }
  // Hasta cuánto puede poner quien no es admin (null: el admin, o sin el regalo de la promo).
  const topeDe = (sustitutoId: string, ajusteElegido: string): number | null => {
    if (esAdmin || !referencia) return null
    const sustituto = buscarProducto(sustitutoId)
    const c = evaluar(sustitutoId, ajusteElegido)
    if (!sustituto || !c || c.tipo === 'falta_bulto') return null
    return topeSustitutoRegalo({
      corte: referencia.corte,
      precioRegalo: referencia.regalo.precio,
      factorRegalo: referencia.factor,
      precioSustituto: sustituto.precio,
      factorSustituto: c.factorSustituto,
      mismoRubro: String(sustituto.id) === String(referencia.regalo.id) || esRegaloCompatible(referencia.regalo, sustituto),
    })
  }
  const cambio = !esReparto && productoNuevoId ? evaluar(String(productoNuevoId), ajusteProductoIdNuevo) : null
  const sugerencia = cambio?.tipo === 'por_valor' ? cambio.sugerencia : null
  const tope = !esReparto && productoNuevoId ? topeDe(String(productoNuevoId), ajusteProductoIdNuevo) : null
  // Al elegir el producto (o cambiar el contenedor) la cantidad arranca en la
  // sugerida por valor, o en la original si es el mismo empaque. Para quien no es
  // admin, nunca por encima de su tope: lo que propone la pantalla entra. Después la
  // puede editar.
  const cantidadInicial = (sustitutoId: string, ajusteElegido: string): number => {
    const c = evaluar(sustitutoId, ajusteElegido)
    const propuesta = c?.tipo === 'por_valor' && c.sugerencia ? c.sugerencia.cantidad : cantidadOriginal
    const t = topeDe(sustitutoId, ajusteElegido)
    return t != null && t >= 1 ? Math.min(propuesta, t) : propuesta
  }

  const cantidadNum = Number(filas[0]?.cantidad) || 0
  const validacion = validarRepartoRegalo(filas, cantidadOriginal, String(productoOriginal.id))
  // Modo A descuenta stock inmediato → validar stock disponible. Lo que vuelve
  // del regalo actual cuenta como disponible para su propio producto.
  // Modo B no mueve stock unitario → no se valida.
  const faltaStock = (fila: ParteReparto): boolean => {
    if (!regaloMueveStock || !fila.productoId) return false
    const prod = productos.find(p => String(p.id) === String(fila.productoId))
    if (!prod) return false
    const vuelve = String(prod.id) === String(productoOriginal.id) ? cantidadOriginal : 0
    return (prod.stock ?? 0) + vuelve < (Number(fila.cantidad) || 0)
  }
  const stockSuficiente = !filas.some(faltaStock)
  const faltaBulto = cambio?.tipo === 'falta_bulto'
  const sobreTope = tope != null && cantidadNum > tope
  const puedeConfirmar = validacion.ok
    && motivo.trim().length > 0
    && stockSuficiente
    && !faltaBulto
    && !sobreTope
    && !enviando
    && !ilegibles.hay

  // Calculos para el banner didactico (modo B)
  const usosOrigAntes = Number(acumuladorOriginal?.usos_pendientes ?? 0)
  const usosOrigDespues = usosOrigAntes - cantidadOriginal
  const usosSustAntes = Number(acumuladorSustituto?.usos_pendientes ?? 0)
  const usosSustDespues = usosSustAntes + cantidadNum
  // Cada barra cuenta con SU N (#950): el del contenedor si tiene
  // `unidades_por_bulto`, si no el de la promo. La del original es el factor de
  // la linea; la del sustituto, el que resolvio `evaluarCambioRegalo`.
  const bloque = factorLinea
  const bloqueSust = cambio && cambio.tipo !== 'falta_bulto' ? cambio.factorSustituto : bloque
  // Defensa display: los acumuladores pueden venir fuera de rango (bug backend de bloques).
  // Clampeamos los valores que se muestran al usuario a [0, N].
  const clamp = (n: number, tope: number) => Math.max(0, Math.min(n, tope))
  const dispOrigAntes = clamp(usosOrigAntes, bloque)
  const dispOrigDespues = clamp(usosOrigDespues, bloque)
  const dispSustAntes = clamp(usosSustAntes, bloqueSust)
  const dispSustDespues = clamp(usosSustDespues, bloqueSust)
  const cruzaAbajo = Math.floor(usosOrigDespues / bloque) < Math.floor(usosOrigAntes / bloque)
  const cruzaArriba = Math.floor(usosSustDespues / bloqueSust) > Math.floor(usosSustAntes / bloqueSust)

  const handleConfirmar = async () => {
    setError('')
    if (!puedeConfirmar) return
    try {
      if (esReparto) {
        const result = await dividirMut.mutateAsync({
          pedidoItemId,
          partes: filas.map(f => ({ productoId: String(f.productoId), cantidad: Number(f.cantidad) })),
          motivo: motivo.trim(),
          clientRequestId: clientRequestIdReparto,
        })
        notify.success(
          result.idempotentReplay
            ? 'El reparto ya estaba registrado'
            : 'Regalo repartido correctamente'
        )
        onSustituido?.(result.version)
        onClose()
        return
      }
      const result = await sustituirMut.mutateAsync({
        pedidoItemId,
        productoNuevoId,
        cantidadNueva: cantidadNum,
        motivo: motivo.trim(),
        // Si el admin no abrio avanzado o no eligio nada, mandamos null y
        // el RPC (mig 063) auto-infiere = productoSustitutoId. Si lo eligio
        // explicito, mandamos su eleccion.
        ajusteProductoIdNuevo: regaloMueveStock
          ? null
          : (ajusteProductoIdNuevo || null),
        clientRequestId: clientRequestIdSustitucion,
      })
      notify.success(
        result.idempotentReplay
          ? 'Sustitucion ya estaba registrada'
          : 'Regalo cambiado correctamente'
      )
      onSustituido?.(result.version)
      onClose()
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al cambiar el regalo'
      setError(msg)
    }
  }

  return (
<RegistroIlegiblesContext.Provider value={ilegibles.registro}>
    <ModalBase title="Cambiar regalo" onClose={onClose} maxWidth="max-w-md" onEscapeKeyDown={handleEscapeKeyDown}>
      <div className="p-4 space-y-4">
        {/* Header: regalo actual */}
        <div className="bg-emerald-50 dark:bg-emerald-900/15 border border-emerald-200 dark:border-emerald-800 rounded-lg p-3">
          <p className="text-xs text-emerald-700 dark:text-emerald-300 mb-1 flex items-center gap-1">
            <Gift className="w-3 h-3" /> Regalo actual
          </p>
          <p className="font-semibold text-emerald-900 dark:text-emerald-100">
            {productoOriginal.nombre}
          </p>
          <p className="text-sm text-emerald-700 dark:text-emerald-300">
            Cantidad: <span className="font-medium">{cantidadOriginal}</span>
          </p>
        </div>

        {/* Producto(s) nuevo(s). Una fila = sustitucion; varias = reparto. */}
        <div className="space-y-2">
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
            {esReparto ? 'Repartirlo en *' : 'Cambiarlo por *'}
          </label>
          {filas.map((fila, idx) => {
            const prodFila = productos.find(p => String(p.id) === String(fila.productoId)) ?? null
            const opciones = esReparto ? opcionesReparto : productosOpcionesSimple
            return (
              <div key={clavesFilas.de(idx)} className="space-y-1">
                <div className="flex items-center gap-2">
                  <Combobox<ProductoDB>
                    aria-label={`Producto ${idx + 1}`}
                    className="flex-1 min-w-0"
                    opciones={opciones}
                    getKey={getKeyProducto}
                    getLabel={getLabelProducto}
                    renderOpcion={renderOpcionProducto}
                    valor={fila.productoId ? String(fila.productoId) : null}
                    onSeleccionar={p => actualizarFila(idx, esReparto
                      ? { productoId: String(p.id) }
                      : { productoId: String(p.id), cantidad: cantidadInicial(String(p.id), ajusteProductoIdNuevo) })}
                    placeholder="Buscar producto nuevo..."
                    textoSinResultados="Ningun producto coincide"
                    limite={1000}
                  />
                  <NumberInput
                    aria-label={`Cantidad ${idx + 1}`}
                    integer
                    min={0}
                    emptyValue={0}
                    commitOnChange
                    value={Number(fila.cantidad) || 0}
                    onChange={(n) => actualizarFila(idx, { cantidad: n })}
                    className="w-20 px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  />
                  {esReparto && (
                    <Button
                      type="button"
                      onClick={() => quitarFila(idx)}
                      variant="ghost"
                      size="iconSm"
                      aria-label={`Quitar fila ${idx + 1}`}
                      className="text-red-500 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/20"
                    >
                      <Trash2 className="w-4 h-4" />
                    </Button>
                  )}
                </div>
                {!esReparto && idx === 0 && prodFila && sugerencia && (
                  <p className="text-xs text-blue-700 dark:text-blue-300" aria-live="polite">
                    ≈ {formatPrecio(sugerencia.valor)} de regalo → {sugerencia.cantidad} de {prodFila.nombre}
                    {cantidadNum !== sugerencia.cantidad && (
                      <>
                        {' · '}
                        <button
                          type="button"
                          className="underline"
                          onClick={() => actualizarFila(0, { cantidad: sugerencia.cantidad })}
                        >
                          usar {sugerencia.cantidad}
                        </button>
                      </>
                    )}
                  </p>
                )}
                {!esReparto && idx === 0 && prodFila && tope != null && referencia && (
                  <p
                    className={`text-xs ${sobreTope ? 'text-red-600 dark:text-red-400' : 'text-gray-600 dark:text-gray-400'}`}
                    role={sobreTope ? 'alert' : undefined}
                  >
                    {tope >= 1
                      ? `Podés poner hasta ${tope} de ${prodFila.nombre}: lo que da la promo es ${referencia.corte} de ${referencia.regalo.nombre}. Para dar más, lo tiene que cambiar un admin.`
                      : `Una unidad de ${prodFila.nombre} ya vale más que el regalo de la promo (${referencia.corte} de ${referencia.regalo.nombre}): ese cambio lo puede hacer sólo un admin.`}
                  </p>
                )}
                {!esReparto && idx === 0 && cambio?.tipo === 'por_valor' && !sugerencia && (
                  <p className="text-xs text-amber-700 dark:text-amber-300 flex items-center gap-1">
                    <AlertTriangle className="w-3 h-3" />
                    Es otro empaque y falta un precio para sugerir la cantidad: cargala a mano.
                  </p>
                )}
                {!esReparto && idx === 0 && cambio?.tipo === 'falta_bulto' && (
                  <p role="alert" className="text-xs text-red-600 dark:text-red-400 flex items-start gap-1">
                    <AlertTriangle className="w-3 h-3 mt-0.5 flex-shrink-0" />
                    <span>
                      {cambio.productoACargar.nombre ?? 'Ese producto'} es de otra categoría y no tiene cargadas
                      sus unidades sueltas por unidad de stock (cuántas botellas o paquetes trae cada una).
                      Cargalo en su ficha de Productos para poder regalarlo.
                    </span>
                  </p>
                )}
                {prodFila && faltaStock(fila) && (
                  <p className="text-xs text-red-600 flex items-center gap-1">
                    <AlertTriangle className="w-3 h-3" />
                    No hay stock suficiente de {prodFila.nombre} ({prodFila.stock ?? 0} disponible)
                  </p>
                )}
              </div>
            )
          })}
          <div className="flex items-center justify-between gap-2">
            <Button
              type="button"
              onClick={agregarFila}
              variant="ghost"
              size="sm"
              className="gap-1 text-emerald-700 dark:text-emerald-300"
            >
              <Plus className="w-3.5 h-3.5" />
              Repartir en otro sabor
            </Button>
            {esReparto && (
              <p
                className={`text-xs font-medium ${validacion.faltante === 0
                  ? 'text-emerald-700 dark:text-emerald-300'
                  : 'text-amber-700 dark:text-amber-300'}`}
                aria-live="polite"
              >
                Asignado {validacion.asignado} de {cantidadOriginal}
                {validacion.faltante > 0 ? ` · faltan ${validacion.faltante}` : ''}
                {validacion.faltante < 0 ? ` · sobran ${-validacion.faltante}` : ''}
              </p>
            )}
          </div>
          <p className="text-xs text-gray-500 dark:text-gray-400">
            {puedeCambiarDeProducto && !esReparto
              ? 'Podés elegir cualquier producto. Si es de otra categoría o de otro empaque, la cantidad se sugiere por valor y la podés corregir.'
              : TEXTO_REGALO_MISMA_CATEGORIA}
          </p>
          {esReparto && !originalOperativo && (
            <p className="text-xs text-amber-700 dark:text-amber-300 flex items-center gap-1">
              <AlertTriangle className="w-3 h-3" />
              {productoOriginal.nombre} esta desactivado: no se puede dejar parte del regalo en ese producto.
            </p>
          )}
          {esReparto && (
            <p className="text-xs text-gray-500 dark:text-gray-400">
              Misma unidad que el regalo actual: la suma tiene que dar {cantidadOriginal}.
            </p>
          )}
        </div>

        {/* Motivo */}
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            Motivo del cambio *
          </label>
          <textarea
            value={motivo}
            onChange={e => setMotivo(e.target.value)}
            rows={2}
            placeholder="Ej: el cliente prefiere otro sabor, no hay stock del original..."
            className="w-full px-3 py-2 border rounded-lg resize-none dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
          />
        </div>

        {/* Reparto: resumen de lo que va a quedar */}
        {esReparto && validacion.ok && (
          <div className="flex items-start gap-2 p-3 rounded-lg bg-blue-50 dark:bg-blue-900/15 border border-blue-200 dark:border-blue-800 text-sm">
            <Info className="w-4 h-4 mt-0.5 flex-shrink-0 text-blue-600 dark:text-blue-400" />
            <div className="space-y-1 text-blue-900 dark:text-blue-100">
              <p className="font-medium">Cuando confirmes, el regalo queda en:</p>
              {filas.map((f, i) => (
                <p key={i}>
                  ✓ <b>{f.cantidad}</b> de{' '}
                  <b>{productos.find(p => String(p.id) === String(f.productoId))?.nombre ?? '?'}</b>
                </p>
              ))}
              <p className="text-xs text-gray-600 dark:text-gray-300">
                {regaloMueveStock
                  ? 'El stock se mueve por la diferencia de cada producto.'
                  : 'Los contadores de la promo se ajustan por la diferencia de cada sabor.'}
              </p>
            </div>
          </div>
        )}

        {/* Banner didactico: que va a pasar cuando confirmes */}
        {!esReparto && productoNuevo && cantidadNum > 0 && (
          <div className="flex items-start gap-2 p-3 rounded-lg bg-blue-50 dark:bg-blue-900/15 border border-blue-200 dark:border-blue-800 text-sm">
            <Info className="w-4 h-4 mt-0.5 flex-shrink-0 text-blue-600 dark:text-blue-400" />
            <div className="space-y-1 text-blue-900 dark:text-blue-100">
              <p className="font-medium">Cuando confirmes:</p>
              {regaloMueveStock ? (
                <>
                  <p>✓ Se devolveran <b>{cantidadOriginal} de {productoOriginal.nombre}</b> al stock.</p>
                  <p>✓ Se descontaran <b>{cantidadNum} de {productoNuevo.nombre}</b> del stock.</p>
                </>
              ) : (
                <>
                  <p>
                    ✓ El contador de <b>{productoOriginal.nombre}</b> baja
                    de <b>{dispOrigAntes}/{bloque}</b> a <b>{dispOrigDespues}/{bloque}</b>.
                  </p>
                  {cruzaAbajo && (
                    <p className="text-emerald-700 dark:text-emerald-300 ml-3">
                      → Se devolvera 1 fardo de {productoOriginal.nombre} al stock.
                    </p>
                  )}
                  <p>
                    ✓ El contador de <b>{productoNuevo.nombre}</b> sube
                    de <b>{dispSustAntes}/{bloqueSust}</b> a <b>{dispSustDespues}/{bloqueSust}</b>.
                  </p>
                  {cruzaArriba ? (
                    <p className="text-orange-700 dark:text-orange-300 ml-3">
                      → Se descontara 1 fardo de {productoNuevo.nombre} del stock ahora.
                    </p>
                  ) : (
                    <p className="text-gray-600 dark:text-gray-300 ml-3 text-xs">
                      → El stock no cambia ahora. Cuando el contador llegue a {bloqueSust} se descontara 1 fardo de {productoNuevo.nombre} automaticamente.
                    </p>
                  )}
                </>
              )}
            </div>
          </div>
        )}

        {/* Configuracion avanzada — colapsada por default. Solo modo B. */}
        {!regaloMueveStock && !esReparto && (
          <div className="border-t border-gray-200 dark:border-gray-700 pt-3">
            <button
              type="button"
              onClick={() => setAvanzadoOpen(v => !v)}
              className="flex items-center gap-1 text-xs text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200"
            >
              {avanzadoOpen ? <ChevronUp className="w-3 h-3" /> : <ChevronDown className="w-3 h-3" />}
              Configuracion avanzada (opcional)
            </button>
            {avanzadoOpen && (
              <div className="mt-3 space-y-2">
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                  Producto donde descontar el sustituto
                </label>
                <select
                  value={ajusteProductoIdNuevo}
                  onChange={e => {
                    setAjusteProductoIdNuevo(e.target.value)
                    // El contenedor decide el empaque del sustituto: la cantidad se recalcula.
                    if (productoNuevoId) actualizarFila(0, { cantidad: cantidadInicial(String(productoNuevoId), e.target.value) })
                  }}
                  className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
                >
                  <option value="">
                    Automatico — usar el mismo producto sustituto (recomendado)
                  </option>
                  {productosContenedor.map(p => (
                    <option key={`cont-${p.id}`} value={p.id}>
                      {p.nombre}
                      {ajusteProductoIdOriginal && String(p.id) === String(ajusteProductoIdOriginal)
                        ? ' · era el de la promo original'
                        : ''}
                    </option>
                  ))}
                </select>
                <p className="text-xs text-gray-500 dark:text-gray-400">
                  Por defecto el sistema usa el mismo producto sustituto como su propio
                  fardo (que es lo que tienen la mayoria de las promos). Cambialo solo
                  si el sustituto se descuenta de OTRO fardo distinto.
                </p>
              </div>
            )}
          </div>
        )}

        {error && (
          <div className="flex items-start gap-2 p-3 rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-sm text-red-700 dark:text-red-300">
            <AlertTriangle className="w-4 h-4 mt-0.5 flex-shrink-0" />
            <p>{error}</p>
          </div>
        )}
      </div>

      {/* N4/T2: dice por qué está frenado el Guardar y lleva al campo en rojo. */}
      <AvisoCamposEnRojo className="mb-2" />
      <div className="flex justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <Button
          onClick={onClose}
          disabled={enviando}
          variant="ghost"
          size="md"
          className="text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600"
        >
          Cancelar
        </Button>
        <Button
          onClick={handleConfirmar}
          disabled={!puedeConfirmar}
          loading={enviando}
          variant="primary"
          size="md"
        >
          {esReparto ? 'Repartir regalo' : 'Cambiar regalo'}
        </Button>
      </div>
    </ModalBase>
    </RegistroIlegiblesContext.Provider>
  )
})

export default ModalSustituirRegalo
