/**
 * Escáner de facturas, Entrega C: la tabla de revisión rápida.
 *
 * Una fila por renglón de la factura, con lo impreso, el estado del vínculo
 * (✓ vinculado / ? sugerido NN% / ✗ sin coincidencia), el producto elegido
 * (editable con el Combobox, ordenado por el matcher), la cantidad con la
 * conversión bulto → unidad, precio, bonificación, importe y la advertencia de
 * la línea. Las líneas resueltas ya están en `items`; las pendientes bloquean
 * el guardado.
 *
 * Teclado (con el foco en una fila):
 *   ↑ / ↓       fila anterior / siguiente
 *   Enter       acepta la sugerencia y salta a la próxima pendiente
 *   B, / o F2   abre el buscador de producto de la fila
 *
 * La lógica (qué bloquea, cuál es la próxima, duplicados, conversión) vive en
 * utils/revisionEscaneo; acá sólo se dibuja y se despacha.
 */
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { KeyboardEvent, ReactNode } from 'react'
import { AlertTriangle, Ban, CheckCircle, ExternalLink, FileText, ListChecks, Plus, Undo2, ZoomIn, ZoomOut, X } from 'lucide-react'
import { Button } from '../ui/Button'
import { Combobox } from '../ui/Combobox'
import NumberInput from '../ui/NumberInput'
import { formatPrecio } from '../../utils/formatters'
import { buscarEnCatalogo, prepararCatalogo } from '../../utils/matchEscaneo'
import type { CatalogoPreparado } from '../../utils/matchEscaneo'
// Del módulo y no del barrel (modal lazy).
import { CANDIDATOS_VACIOS, useCandidatosEscaneoQuery } from '../../hooks/queries/useEscaneoQuery'
import {
  UMBRAL_ACEPTAR_TODAS, conversionOfrecida, duplicadosPorProducto, estadoDeRevision, factorDeLinea,
  ordenRevision, siguientePendiente, textoCantidad, tieneSugerencia,
} from '../../utils/revisionEscaneo'
import type { LineaRevision, RevisionEscaneo } from '../../utils/revisionEscaneo'
import type { ProductoDB } from '../../types'
import type { CompraActionType } from './ModalCompra.reducer'

export interface RevisionEscaneoTablaProps {
  revision: RevisionEscaneo;
  productos: ProductoDB[];
  /** Proveedor de la compra (para premiar lo que ya se le compró al buscar). */
  proveedorId: string | null;
  dispatch: (action: CompraActionType) => void;
  /** Formulario "Crear nuevo" de la línea; `cerrar` lo oculta. null = no se puede crear. */
  renderCrear: ((index: number, linea: LineaRevision, cerrar: () => void) => ReactNode) | null;
  /** URL firmada y corta del archivo escaneado. */
  obtenerUrlFactura: ((ruta: string) => Promise<string>) | null;
}

const pct = (n: number) => `${Math.round(n * 100)}%`

/** El chip de estado de la línea. */
function ChipEstado({ linea }: { linea: LineaRevision }) {
  const r = linea.resolucion
  const base = 'inline-flex items-center gap-1 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium'
  if (r.tipo === 'producto') {
    const detalle = r.via === 'automatico' ? linea.match.motivo
      : r.via === 'sugerencia' ? 'Sugerencia aceptada'
        : r.via === 'creado' ? 'Producto creado desde la factura' : 'Elegido a mano'
    return <span title={detalle} className={`${base} bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-200`}>✓ vinculado</span>
  }
  if (r.tipo === 'omitida') {
    return <span className={`${base} bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300`}>Omitida</span>
  }
  if (tieneSugerencia(linea)) {
    return <span title={linea.match.motivo} className={`${base} bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200`}>? sugerido {pct(linea.match.confianza)}</span>
  }
  return <span title={linea.match.motivo} className={`${base} bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-200`}>✗ sin coincidencia</span>
}

/** El buscador de la fila: alternativas primero, después el matcher. */
function SelectorProductoLinea({ index, linea, productos, porId, preparado, ultimoCosto, onElegir }: {
  index: number;
  linea: LineaRevision;
  productos: ProductoDB[];
  porId: Map<string, ProductoDB>;
  preparado: CatalogoPreparado;
  /** producto_id → último costo unitario comprado a este proveedor (mig 292). */
  ultimoCosto: Map<string, number | null>;
  onElegir: (producto: ProductoDB) => void;
}) {
  const sugeridos = useMemo(
    () => new Set([linea.match.productoId, ...linea.match.alternativas].filter((id): id is string => !!id)),
    [linea.match.productoId, linea.match.alternativas],
  )
  const filtrar = useCallback((_: ProductoDB[], consulta: string): ProductoDB[] => {
    const ids = consulta.trim()
      ? buscarEnCatalogo(preparado, consulta).map(r => r.productoId)
      // Sin tipear: lo que propuso el matcher y después el ranking del texto impreso.
      : [...sugeridos, ...buscarEnCatalogo(preparado, linea.impresa.descripcion).map(r => r.productoId)]
    const vistos = new Set<string>()
    const salida: ProductoDB[] = []
    for (const id of ids) {
      const p = porId.get(id)
      if (p && !vistos.has(id)) { vistos.add(id); salida.push(p) }
    }
    return salida
  }, [preparado, sugeridos, porId, linea.impresa.descripcion])

  const r = linea.resolucion
  const sugerido = linea.match.productoId ? porId.get(linea.match.productoId) : undefined
  // El nombre va como TEXTO, entero y en negrita, arriba del buscador: en el
  // input (o como placeholder "¿…?") la columna lo cortaba y no se leía qué
  // producto se estaba por aceptar. El input queda sólo para cambiarlo.
  const nombre = r.tipo === 'producto' ? r.productoNombre
    : r.tipo === 'pendiente' && sugerido ? sugerido.nombre : null

  /** Segunda línea de la opción: código, último costo a este proveedor y por qué se sugiere. */
  const detalle = (p: ProductoDB) => {
    const id = String(p.id)
    const costo = ultimoCosto.get(id)
    const porQue = id === linea.match.productoId ? (linea.match.motivo || 'Sugerido')
      : sugeridos.has(id) ? 'Alternativa del matcher' : null
    return [p.codigo, costo != null ? `último ${formatPrecio(costo)}` : null, porQue].filter(Boolean).join(' · ')
  }

  return (
    <div className="space-y-1">
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
        <ChipEstado linea={linea} />
        {nombre && <span className="break-words font-semibold text-gray-900 dark:text-white">{nombre}</span>}
      </div>
      <Combobox<ProductoDB>
        id={`revision-producto-${index}`}
        opciones={productos}
        getKey={p => String(p.id)}
        getLabel={p => p.nombre}
        filtrar={filtrar}
        limite={20}
        renderOpcion={p => {
          const d = detalle(p)
          return (
            <span className="block">
              <span className="block break-words">{p.nombre}</span>
              {d && <span className="block text-xs text-gray-500 dark:text-gray-400">{d}</span>}
            </span>
          )
        }}
        // Sin valor: el elegido ya se ve arriba, y repetido en un input angosto
        // sólo se ve cortado.
        valor={null}
        placeholder={nombre ? 'Cambiar producto...' : 'Buscar producto...'}
        aria-label={`Producto de la línea ${index + 1}`}
        onSeleccionar={onElegir}
        inputClassName="py-1.5 text-sm sm:text-sm"
        // Más ancha que la columna desde sm: el nombre entero en cada opción.
        // En el celular, del ancho del input (la tabla ya scrollea de costado).
        listaClassName="sm:min-w-[28rem]"
      />
    </div>
  )
}

/** La factura escaneada al lado de la tabla: imagen con zoom o el PDF. */
function VisorFactura({ ruta, obtenerUrl, onCerrar }: {
  ruta: string;
  obtenerUrl: (ruta: string) => Promise<string>;
  onCerrar: () => void;
}) {
  const [url, setUrl] = useState<string | null>(null)
  const [error, setError] = useState('')
  const [zoom, setZoom] = useState(1)
  useEffect(() => {
    let vivo = true
    obtenerUrl(ruta)
      .then(u => { if (vivo) setUrl(u) })
      .catch(() => { if (vivo) setError('No se pudo abrir la factura.') })
    return () => { vivo = false }
  }, [ruta, obtenerUrl])
  const esPdf = ruta.toLowerCase().endsWith('.pdf')
  return (
    <div className="flex min-h-[18rem] flex-col rounded-lg border bg-white dark:border-gray-700 dark:bg-gray-800 lg:sticky lg:top-0 lg:max-h-[70vh]" aria-label="Factura escaneada">
      <div className="flex items-center gap-1 border-b px-2 py-1 dark:border-gray-700">
        <span className="flex-1 text-xs font-medium text-gray-600 dark:text-gray-300">Factura</span>
        {!esPdf && (
          <>
            <Button type="button" variant="ghost" size="iconSm" aria-label="Alejar" onClick={() => setZoom(z => Math.max(0.5, z - 0.25))}><ZoomOut className="h-4 w-4" /></Button>
            <span className="w-10 text-center text-xs tabular-nums text-gray-500">{Math.round(zoom * 100)}%</span>
            <Button type="button" variant="ghost" size="iconSm" aria-label="Acercar" onClick={() => setZoom(z => Math.min(4, z + 0.25))}><ZoomIn className="h-4 w-4" /></Button>
          </>
        )}
        {url && (
          <a href={url} target="_blank" rel="noopener noreferrer" aria-label="Abrir la factura en otra pestaña"
             className="inline-flex h-8 w-8 items-center justify-center rounded text-gray-500 hover:bg-gray-100 dark:hover:bg-gray-700">
            <ExternalLink className="h-4 w-4" />
          </a>
        )}
        <Button type="button" variant="ghost" size="iconSm" aria-label="Cerrar la factura" onClick={onCerrar}><X className="h-4 w-4" /></Button>
      </div>
      <div className="flex-1 overflow-auto">
        {error && <p className="p-3 text-sm text-red-600 dark:text-red-400">{error}</p>}
        {!error && !url && <p className="p-3 text-sm text-gray-500">Abriendo la factura...</p>}
        {url && (esPdf
          ? <iframe src={url} title="Factura escaneada" className="h-[60vh] w-full" />
          : <img src={url} alt="Factura escaneada" style={{ width: `${zoom * 100}%`, maxWidth: 'none' }} className="block" />)}
      </div>
    </div>
  )
}

export default function RevisionEscaneoTabla({
  revision, productos, proveedorId, dispatch, renderCrear, obtenerUrlFactura,
}: RevisionEscaneoTablaProps) {
  const { lineas } = revision
  // Lo ya comprado al proveedor premia en el buscador, como en el matcher. Es
  // la misma query (y la misma caché) que usó la vista previa.
  const comprados = useCandidatosEscaneoQuery(proveedorId).data?.comprados ?? CANDIDATOS_VACIOS.comprados
  const porId = useMemo(() => new Map(productos.map(p => [String(p.id), p])), [productos])
  const ultimoCosto = useMemo(() => new Map(comprados.map(c => [c.productoId, c.ultimoCosto])), [comprados])
  const preparado = useMemo(() => prepararCatalogo(productos, { proveedorId, comprados }), [productos, proveedorId, comprados])
  const orden = useMemo(() => ordenRevision(lineas), [lineas])
  const estado = useMemo(() => estadoDeRevision(lineas), [lineas])
  const duplicados = useMemo(() => duplicadosPorProducto(lineas), [lineas])
  const [crearEn, setCrearEn] = useState<number | null>(null)
  const [confirmarLote, setConfirmarLote] = useState(false)
  const [verFactura, setVerFactura] = useState(false)

  // Foco: las filas son la unidad de navegación. Tras resolver una línea, el
  // foco va a la próxima pendiente; se pide con un ref y lo cumple el efecto
  // del render siguiente (la fila puede haberse movido de lugar).
  const filas = useRef(new Map<number, HTMLTableRowElement>())
  const [activa, setActiva] = useState<number>(() => estado.pendientes[0] ?? orden[0] ?? 0)
  const enfocar = useRef<number | null>(null)
  useEffect(() => {
    if (enfocar.current === null) return
    const i = enfocar.current
    enfocar.current = null
    filas.current.get(i)?.focus()
  })
  const irA = (i: number | null | undefined) => {
    if (i === null || i === undefined) return
    enfocar.current = i
    setActiva(i)
    filas.current.get(i)?.focus()
  }
  /** Después de resolver `index`: la próxima pendiente, o la fila siguiente. */
  const avanzarDesde = (index: number) => {
    const pos = orden.indexOf(index)
    irA(siguientePendiente(lineas, orden, index) ?? orden[Math.min(pos + 1, orden.length - 1)])
  }

  const resolver = (index: number, producto: ProductoDB) => {
    const linea = lineas[index]
    dispatch({
      type: 'RESOLVER_LINEA_ESCANEO',
      payload: { index, producto, via: linea.match.productoId === String(producto.id) ? 'sugerencia' : 'manual' },
    })
    avanzarDesde(index)
  }

  const abrirBuscador = (index: number) => {
    document.getElementById(`revision-producto-${index}`)?.focus()
  }

  const onKeyDownFila = (e: KeyboardEvent<HTMLTableRowElement>, index: number) => {
    // Sólo con el foco en la fila: las teclas del buscador o de un botón son de ellos.
    if (e.target !== e.currentTarget) return
    const pos = orden.indexOf(index)
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault()
        irA(orden[Math.min(pos + 1, orden.length - 1)])
        return
      case 'ArrowUp':
        e.preventDefault()
        irA(orden[Math.max(pos - 1, 0)])
        return
      case 'Enter': {
        e.preventDefault()
        const linea = lineas[index]
        const sugerido = linea.match.productoId ? porId.get(linea.match.productoId) : undefined
        if (linea.resolucion.tipo === 'pendiente') {
          if (sugerido) resolver(index, sugerido)
          else abrirBuscador(index)
          return
        }
        avanzarDesde(index)
        return
      }
      case 'b':
      case 'B':
      case '/':
      case 'F2':
        e.preventDefault()
        abrirBuscador(index)
        return
      default:
    }
  }

  const aceptarLote = () => {
    const payload = estado.aceptablesEnLote.flatMap(index => {
      const producto = porId.get(lineas[index].match.productoId ?? '')
      return producto ? [{ index, producto }] : []
    })
    dispatch({ type: 'ACEPTAR_SUGERIDAS_ESCANEO', payload })
    setConfirmarLote(false)
  }

  const pendientes = estado.pendientes.length
  const tabla = (
    <div className="overflow-x-auto rounded-lg border dark:border-gray-700">
      <table className="w-full text-sm" aria-label="Líneas de la factura">
        <thead className="bg-gray-50 text-left text-xs text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            <th scope="col" className="px-2 py-2">#</th>
            <th scope="col" className="px-2 py-2 min-w-[12rem]">En la factura</th>
            <th scope="col" className="px-2 py-2 min-w-[14rem] sm:min-w-[20rem]">Producto</th>
            <th scope="col" className="px-2 py-2">Cantidad</th>
            <th scope="col" className="px-2 py-2 text-right">Precio</th>
            <th scope="col" className="px-2 py-2 text-right">Bonif.</th>
            <th scope="col" className="px-2 py-2 text-right">Importe</th>
            <th scope="col" className="px-2 py-2"><span className="sr-only">Acciones</span></th>
          </tr>
        </thead>
        <tbody className="divide-y dark:divide-gray-700">
          {orden.map(index => {
            const linea = lineas[index]
            const { impresa, resolucion } = linea
            const resuelta = resolucion.tipo === 'producto'
            const grupo = resuelta ? duplicados.get(resolucion.productoId) : undefined
            const otras = grupo?.filter(j => j !== index) ?? []
            const factor = factorDeLinea(linea)
            const ofrecida = conversionOfrecida(linea)
            const importe = impresa.importeNeto ?? impresa.cantidad * impresa.costoUnitario * (1 - (impresa.bonificacion || 0) / 100)
            const totalGrupo = grupo?.reduce((acc, j) => acc + lineas[j].impresa.cantidad * factorDeLinea(lineas[j]), 0)
            return [
              <tr
                key={index}
                ref={el => { if (el) filas.current.set(index, el); else filas.current.delete(index) }}
                tabIndex={activa === index ? 0 : -1}
                aria-label={`Línea ${index + 1}: ${impresa.descripcion}`}
                aria-selected={activa === index}
                onFocus={e => { if (e.target === e.currentTarget) setActiva(index) }}
                onKeyDown={e => onKeyDownFila(e, index)}
                className={[
                  'align-top outline-none focus:bg-blue-50 focus:ring-2 focus:ring-inset focus:ring-blue-400 dark:focus:bg-blue-900/20',
                  resolucion.tipo === 'omitida' ? 'opacity-60' : '',
                  grupo ? 'border-l-4 border-l-blue-300 dark:border-l-blue-700' : '',
                ].join(' ')}
              >
                <td className="px-2 py-2 text-xs text-gray-500 tabular-nums">{index + 1}</td>
                <td className="px-2 py-2">
                  <p className="break-words text-gray-800 dark:text-gray-100">
                    {impresa.codigo && <span className="mr-1 font-mono text-xs text-gray-500">{impresa.codigo}</span>}
                    {impresa.descripcion}
                  </p>
                  {impresa.legible === false && <p className="text-xs text-amber-700 dark:text-amber-300">No se leyó con claridad</p>}
                  {linea.advertencias.map((a, k) => (
                    <p key={k} className="flex items-start gap-1 text-xs text-amber-700 dark:text-amber-300">
                      <AlertTriangle className="mt-0.5 h-3 w-3 shrink-0" />{a}
                    </p>
                  ))}
                  {otras.length > 0 && (
                    <p className="text-xs text-blue-700 dark:text-blue-300">
                      Se van a sumar con la línea {otras.map(j => j + 1).join(', ')}: {totalGrupo?.toLocaleString('es-AR')} u en total
                    </p>
                  )}
                </td>
                {/* El estado va en la misma celda que el producto: la columna
                    propia le restaba ancho al nombre, que es lo que hay que leer. */}
                <td className="px-2 py-2">
                  {resolucion.tipo === 'omitida'
                    ? <span className="flex flex-wrap items-center gap-2"><ChipEstado linea={linea} /><span className="text-xs text-gray-500">No se carga</span></span>
                    : <SelectorProductoLinea index={index} linea={linea} productos={productos} porId={porId}
                                             preparado={preparado} ultimoCosto={ultimoCosto} onElegir={p => resolver(index, p)} />}
                </td>
                <td className="px-2 py-2 whitespace-nowrap">
                  <span className="tabular-nums">{textoCantidad(linea)}</span>
                  {resuelta && (
                    <span className="mt-1 flex items-center gap-1 text-xs text-gray-500">
                      <label htmlFor={`revision-upb-${index}`}>u/bulto</label>
                      <NumberInput
                        id={`revision-upb-${index}`}
                        aria-label={`Unidades por bulto de la línea ${index + 1}`}
                        min={1}
                        emptyValue={1}
                        value={factor}
                        onChange={n => dispatch({ type: 'SET_CONVERSION_LINEA_ESCANEO', payload: { index, unidadesPorBulto: n > 1 ? n : null } })}
                        className="w-14 rounded border px-1 py-0.5 text-right text-xs dark:border-gray-600 dark:bg-gray-700 dark:text-white"
                      />
                      {ofrecida && (
                        <button type="button" className="text-blue-700 underline dark:text-blue-300"
                                aria-label={`Convertir a unidades: ${ofrecida} por bulto`}
                                onClick={() => dispatch({ type: 'SET_CONVERSION_LINEA_ESCANEO', payload: { index, unidadesPorBulto: ofrecida } })}>
                          ×{ofrecida}?
                        </button>
                      )}
                    </span>
                  )}
                </td>
                <td className="px-2 py-2 text-right tabular-nums whitespace-nowrap">
                  {formatPrecio(impresa.costoUnitario)}
                  {factor !== 1 && <span className="block text-xs text-gray-500">{formatPrecio(impresa.costoUnitario / factor)} /u</span>}
                </td>
                <td className="px-2 py-2 text-right tabular-nums">{impresa.bonificacion ? `${impresa.bonificacion}%` : '—'}</td>
                <td className="px-2 py-2 text-right tabular-nums whitespace-nowrap">{formatPrecio(importe)}</td>
                <td className="px-2 py-2">
                  {/* Compactas y en una fila: apiladas y con rótulo largo se
                      llevaban el ancho que necesita el nombre del producto. */}
                  <div className="flex flex-nowrap justify-end gap-1">
                    {resolucion.tipo === 'pendiente' && renderCrear && (
                      <Button type="button" size="sm" variant="success" className="h-7 gap-1 whitespace-nowrap px-2 text-xs"
                              onClick={() => setCrearEn(crearEn === index ? null : index)}
                              aria-label={`Crear producto nuevo para la línea ${index + 1}`} title="Crear producto nuevo">
                        <Plus className="h-3.5 w-3.5" aria-hidden="true" />Crear
                      </Button>
                    )}
                    {resolucion.tipo === 'omitida' ? (
                      <Button type="button" size="sm" variant="ghost" className="h-7 gap-1 whitespace-nowrap px-2 text-xs"
                              onClick={() => dispatch({ type: 'REABRIR_LINEA_ESCANEO', payload: { index } })}
                              aria-label={`Volver a cargar la línea ${index + 1}`}>
                        <Undo2 className="h-3.5 w-3.5" aria-hidden="true" />Deshacer
                      </Button>
                    ) : (
                      <Button type="button" size="sm" variant="secondary" className="h-7 gap-1 whitespace-nowrap px-2 text-xs"
                              onClick={() => { dispatch({ type: 'OMITIR_LINEA_ESCANEO', payload: { index } }); avanzarDesde(index) }}
                              aria-label={`Omitir la línea ${index + 1}`} title="No cargar esta línea">
                        <Ban className="h-3.5 w-3.5" aria-hidden="true" />Omitir
                      </Button>
                    )}
                  </div>
                </td>
              </tr>,
              crearEn === index && renderCrear && resolucion.tipo === 'pendiente' ? (
                <tr key={`${index}-crear`}>
                  <td colSpan={8} className="px-2 pb-3">
                    {renderCrear(index, linea, () => setCrearEn(null))}
                  </td>
                </tr>
              ) : null,
            ]
          })}
        </tbody>
      </table>
    </div>
  )

  return (
    <section aria-label="Revisión de la factura escaneada" className="space-y-2 rounded-lg border border-purple-200 bg-purple-50/50 p-3 dark:border-purple-800 dark:bg-purple-900/10">
      <div className="flex flex-wrap items-center gap-2">
        <ListChecks className="h-5 w-5 text-purple-600" />
        <h3 className="font-medium text-purple-900 dark:text-purple-100">Revisión de la factura</h3>
        <span className="text-xs text-gray-600 dark:text-gray-300">
          {estado.resueltas} vinculadas · {pendientes} {pendientes === 1 ? 'pendiente' : 'pendientes'}
          {estado.omitidas > 0 && ` · ${estado.omitidas} omitidas`}
        </span>
        <span className="flex-1" />
        {revision.rutaArchivo && obtenerUrlFactura && (
          <Button type="button" size="sm" variant="ghost" onClick={() => setVerFactura(v => !v)} className="gap-1">
            <FileText className="h-4 w-4" />{verFactura ? 'Ocultar factura' : 'Ver factura'}
          </Button>
        )}
        <Button type="button" size="sm" variant="primary" disabled={estado.aceptablesEnLote.length === 0}
                onClick={() => setConfirmarLote(true)}>
          Aceptar todas las sugeridas ≥ {Math.round(UMBRAL_ACEPTAR_TODAS * 100)}% ({estado.aceptablesEnLote.length})
        </Button>
        {pendientes === 0 && (
          <Button type="button" size="sm" variant="success" className="gap-1" onClick={() => dispatch({ type: 'CERRAR_REVISION_ESCANEO' })}>
            <CheckCircle className="h-4 w-4" />Terminar revisión
          </Button>
        )}
      </div>

      {confirmarLote && (
        <div role="alertdialog" aria-label="Aceptar sugeridas" className="space-y-2 rounded-lg border border-blue-300 bg-blue-50 p-3 dark:border-blue-700 dark:bg-blue-900/20">
          <p className="text-sm text-blue-900 dark:text-blue-100">
            Se van a vincular {estado.aceptablesEnLote.length} {estado.aceptablesEnLote.length === 1 ? 'línea' : 'líneas'} con
            el producto sugerido (confianza de {Math.round(UMBRAL_ACEPTAR_TODAS * 100)}% o más). Las demás siguen pendientes.
          </p>
          <div className="flex flex-wrap gap-2">
            <Button type="button" size="sm" variant="primary" onClick={aceptarLote}>
              Sí, aceptar {estado.aceptablesEnLote.length}
            </Button>
            <Button type="button" size="sm" variant="secondary" onClick={() => setConfirmarLote(false)}>Cancelar</Button>
          </div>
        </div>
      )}

      {revision.advertenciasGenerales.length > 0 && (
        <ul aria-label="Advertencias de la factura" className="space-y-0.5 text-xs text-amber-800 dark:text-amber-200">
          {revision.advertenciasGenerales.map((a, i) => (
            <li key={i} className="flex items-start gap-1"><AlertTriangle className="mt-0.5 h-3 w-3 shrink-0" />{a}</li>
          ))}
        </ul>
      )}
      {revision.bonificacionPie && (
        <p className="text-xs text-gray-600 dark:text-gray-300">
          El pie trae «{revision.bonificacionPie.descripcion}» por {formatPrecio(revision.bonificacionPie.monto)}: si no está
          descontada de la base del impuesto interno, aparece como sugerencia en Cargos.
        </p>
      )}

      {verFactura && revision.rutaArchivo && obtenerUrlFactura ? (
        <div className="grid gap-3 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
          {tabla}
          <VisorFactura ruta={revision.rutaArchivo} obtenerUrl={obtenerUrlFactura} onCerrar={() => setVerFactura(false)} />
        </div>
      ) : tabla}

      <p className="text-xs text-gray-500 dark:text-gray-400">
        Teclado: ↑ ↓ para moverse · Enter acepta la sugerencia y pasa a la próxima · B busca otro producto.
        {pendientes > 0 && ` Faltan resolver ${pendientes} ${pendientes === 1 ? 'línea' : 'líneas'} para poder registrar (vinculá, creá u omití).`}
      </p>
    </section>
  )
}
