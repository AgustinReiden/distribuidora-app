/**
 * PDF de la lista de precios (A4) con la marca de Crecer Distribuciones.
 *
 * Recibe las secciones ya armadas por `armarListaPrecios` (utils/listaPrecios):
 * acá no se decide qué productos entran ni qué datos se muestran, sólo cómo se
 * dibujan. Una fila nunca se corta entre dos hojas, y el título de un rubro no
 * queda solo al pie de una hoja: baja con su primera fila.
 */
import { jsPDF } from 'jspdf'
import type { SeccionListaPrecios, FilaListaPrecios } from '../../utils/listaPrecios'
import { A4, COLORS } from './constants'
import {
  formatFecha,
  formatPrecio,
  generateFilename,
  setDrawColor,
  setFillColor,
  setTextColor,
} from './utils'

export interface DatosListaPreciosPdf {
  secciones: SeccionListaPrecios[]
  /** Nombre de la sucursal activa. */
  sucursal: string
  /** Fecha de vigencia de los precios: hoy, salvo en los tests. */
  fecha?: Date
  /**
   * Logo de la marca para fondo blanco, como data URL PNG. Lo carga quien llama
   * (es un chunk aparte: así no viaja con los demás PDFs). Sin logo, el nombre
   * de la marca va en texto.
   */
  logo?: string | null
}

const MARCA = 'Crecer Distribuciones'
/** crecer-logo.png mide 768 × 502 px. */
const LOGO_PROPORCION = 768 / 502
const LOGO_ALTO = 24

const { width: ANCHO, height: ALTO, margin: MARGEN } = A4
const X_DERECHA = ANCHO - MARGEN

// Columnas de la tabla
const X_PRODUCTO = MARGEN + 2
const ANCHO_PRODUCTO = 84
const X_PRECIO_DERECHA = MARGEN + 118
const X_CONDICION = MARGEN + 124
const ANCHO_CONDICION = X_DERECHA - 2 - X_CONDICION

// Alturas (mm)
const INTERLINEA_NOMBRE = 4
const INTERLINEA_CONDICION = 3.4
const RELLENO_FILA = 1.6
const ALTO_ENCABEZADO_TABLA = 7
const ALTO_TITULO_RUBRO = 10
const ALTO_TITULO_SUBRUBRO = 6.5
const ALTO_CONTINUACION = 5
/** Lo más bajo que puede llegar una fila: debajo va el pie. */
const Y_LIMITE = ALTO - MARGEN - 4
const Y_PIE = ALTO - 9

const TAMANO_NOMBRE = 9
const TAMANO_CONDICION = 7.5

/** Deja sólo lo que entra en Latin-1, que es lo que cubre la fuente. */
const soloLatin1 = (texto: string): string =>
  Array.from(texto).filter(c => (c.codePointAt(0) ?? 0) <= 0xff).join('')

/**
 * Las fuentes estándar de jsPDF no traen la raya, las comillas tipográficas ni
 * los puntos suspensivos: los imprimirían como basura. Se cambian por su par
 * ASCII, y lo que no entre en Latin-1 se saca. Tildes, ñ, "·" y el espacio duro
 * del formato de moneda sí están en la fuente.
 */
export function textoPdf(texto: string): string {
  const conParAscii = texto
    .replace(/[\u2012-\u2015\u2212]/g, '-')
    .replace(/[\u2018\u2019\u201a\u2032]/g, "'")
    .replace(/[\u201c\u201d\u201e\u2033]/g, '"')
    .replace(/\u2026/g, '...')
  return soloLatin1(conParAscii)
}

interface FilaMedida {
  nombre: string[]
  condicion: string[]
  alto: number
}

function medirFila(doc: jsPDF, fila: FilaListaPrecios): FilaMedida {
  doc.setFont('helvetica', 'normal')
  doc.setFontSize(TAMANO_NOMBRE)
  const nombre = doc.splitTextToSize(textoPdf(fila.nombre), ANCHO_PRODUCTO) as string[]
  doc.setFontSize(TAMANO_CONDICION)
  const condicion = fila.condicion.flatMap(
    linea => doc.splitTextToSize(textoPdf(linea), ANCHO_CONDICION) as string[],
  )
  const alto = Math.max(
    nombre.length * INTERLINEA_NOMBRE,
    condicion.length * INTERLINEA_CONDICION,
    INTERLINEA_NOMBRE,
  ) + RELLENO_FILA * 2
  return { nombre, condicion, alto }
}

function dibujarEncabezadoPrincipal(doc: jsPDF, datos: DatosListaPreciosPdf, vigencia: string): number {
  if (datos.logo) {
    // Comprimido: sin esto el logo son dos streams crudos de 385 KB.
    doc.addImage(datos.logo, 'PNG', MARGEN, 10, LOGO_ALTO * LOGO_PROPORCION, LOGO_ALTO, undefined, 'FAST')
  } else {
    doc.setFont('helvetica', 'bold')
    doc.setFontSize(14)
    setTextColor(doc, COLORS.brand[600])
    doc.text(MARCA, MARGEN, 22)
  }

  doc.setFont('helvetica', 'bold')
  doc.setFontSize(20)
  setTextColor(doc, COLORS.brand[600])
  doc.text('Lista de precios', X_DERECHA, 18, { align: 'right' })

  if (datos.sucursal) {
    doc.setFontSize(12)
    setTextColor(doc, COLORS.gray[800])
    doc.text(textoPdf(`Sucursal ${datos.sucursal}`), X_DERECHA, 25, { align: 'right' })
  }

  doc.setFont('helvetica', 'normal')
  doc.setFontSize(9)
  setTextColor(doc, COLORS.gray[600])
  doc.text(vigencia, X_DERECHA, 30.5, { align: 'right' })

  doc.setFont('helvetica', 'bold')
  setTextColor(doc, COLORS.brand[600])
  doc.text('Precios con IVA incluido', X_DERECHA, 35.5, { align: 'right' })

  setDrawColor(doc, COLORS.brand[600])
  doc.setLineWidth(0.8)
  doc.line(MARGEN, 38.5, X_DERECHA, 38.5)
  return 44
}

/** Las hojas siguientes repiten lo mínimo para que una hoja suelta se entienda. */
function dibujarEncabezadoContinuacion(doc: jsPDF, datos: DatosListaPreciosPdf, vigencia: string): number {
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(8)
  setTextColor(doc, COLORS.brand[600])
  const sucursal = datos.sucursal ? ` · Sucursal ${datos.sucursal}` : ''
  doc.text(textoPdf(`${MARCA} · Lista de precios${sucursal}`), MARGEN, 12)

  doc.setFont('helvetica', 'normal')
  doc.setFontSize(7.5)
  setTextColor(doc, COLORS.gray[600])
  doc.text(`${vigencia} · Precios con IVA incluido`, X_DERECHA, 12, { align: 'right' })

  setDrawColor(doc, COLORS.brand[600])
  doc.setLineWidth(0.4)
  doc.line(MARGEN, 14.5, X_DERECHA, 14.5)
  return 20
}

function dibujarEncabezadoTabla(doc: jsPDF, y: number): number {
  setFillColor(doc, COLORS.brand[600])
  doc.rect(MARGEN, y, X_DERECHA - MARGEN, ALTO_ENCABEZADO_TABLA, 'F')
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(8)
  setTextColor(doc, COLORS.white)
  const base = y + 4.7
  doc.text('Producto', X_PRODUCTO, base)
  doc.text('Precio', X_PRECIO_DERECHA, base, { align: 'right' })
  doc.text('Condición mayorista', X_CONDICION, base)
  return y + ALTO_ENCABEZADO_TABLA + 1.5
}

function dibujarTituloRubro(doc: jsPDF, rubro: string, y: number): void {
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(11)
  setTextColor(doc, COLORS.brand[600])
  doc.text(textoPdf(rubro), MARGEN, y + 6)
  setDrawColor(doc, COLORS.brand[600])
  doc.setLineWidth(0.3)
  doc.line(MARGEN, y + 7.6, X_DERECHA, y + 7.6)
}

function dibujarTituloSubrubro(doc: jsPDF, subrubro: string, y: number): void {
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(9)
  setTextColor(doc, COLORS.gray[700])
  doc.text(textoPdf(subrubro), X_PRODUCTO, y + 4.5)
}

function dibujarFila(doc: jsPDF, fila: FilaListaPrecios, medida: FilaMedida, y: number, sombreada: boolean): void {
  if (sombreada) {
    setFillColor(doc, COLORS.gray[50])
    doc.rect(MARGEN, y, X_DERECHA - MARGEN, medida.alto, 'F')
  }
  const base = y + RELLENO_FILA + 3

  doc.setFont('helvetica', 'normal')
  doc.setFontSize(TAMANO_NOMBRE)
  setTextColor(doc, COLORS.gray[900])
  medida.nombre.forEach((linea, i) => doc.text(linea, X_PRODUCTO, base + i * INTERLINEA_NOMBRE))

  doc.setFont('helvetica', 'bold')
  doc.text(formatPrecio(fila.precio), X_PRECIO_DERECHA, base, { align: 'right' })

  doc.setFont('helvetica', 'normal')
  doc.setFontSize(TAMANO_CONDICION)
  setTextColor(doc, COLORS.gray[700])
  medida.condicion.forEach((linea, i) => doc.text(linea, X_CONDICION, base - 0.2 + i * INTERLINEA_CONDICION))
}

function dibujarPie(doc: jsPDF, pagina: number, total: number): void {
  setDrawColor(doc, COLORS.gray[200])
  doc.setLineWidth(0.2)
  doc.line(MARGEN, Y_PIE - 4, X_DERECHA, Y_PIE - 4)
  doc.setFont('helvetica', 'normal')
  doc.setFontSize(7.5)
  setTextColor(doc, COLORS.gray[500])
  doc.text(MARCA, MARGEN, Y_PIE)
  doc.text(`Página ${pagina} de ${total}`, X_DERECHA, Y_PIE, { align: 'right' })
}

export function construirListaPreciosPdf(datos: DatosListaPreciosPdf): jsPDF {
  const doc = new jsPDF({ orientation: 'portrait', unit: 'mm', format: 'a4' })
  const vigencia = `Precios vigentes al ${formatFecha(datos.fecha ?? new Date())}`

  let y = dibujarEncabezadoTabla(doc, dibujarEncabezadoPrincipal(doc, datos, vigencia))
  let sombreada = false

  const nuevaHoja = (continuacion: string | null) => {
    doc.addPage()
    y = dibujarEncabezadoContinuacion(doc, datos, vigencia)
    if (continuacion) {
      doc.setFont('helvetica', 'italic')
      doc.setFontSize(8)
      setTextColor(doc, COLORS.gray[500])
      doc.text(textoPdf(`${continuacion} (continuación)`), MARGEN, y + 3)
      y += ALTO_CONTINUACION
    }
    y = dibujarEncabezadoTabla(doc, y)
    sombreada = false
  }

  if (datos.secciones.length === 0) {
    doc.setFont('helvetica', 'normal')
    doc.setFontSize(10)
    setTextColor(doc, COLORS.gray[600])
    doc.text('No hay productos activos con precio cargado.', MARGEN, y + 6)
  }

  let rubroAnterior: string | null = null
  for (const seccion of datos.secciones) {
    if (seccion.filas.length === 0) continue
    const claveRubro = `${seccion.sinCategoria ? 1 : 0}\u0000${seccion.rubro}`
    const titulaRubro = claveRubro !== rubroAnterior
    const altoTitulos = (titulaRubro ? ALTO_TITULO_RUBRO : 0) + (seccion.subrubro ? ALTO_TITULO_SUBRUBRO : 0)

    // El título baja de hoja junto con su primera fila. Si el rubro ya se tituló
    // en la hoja anterior, la nueva arranca con su subrubro: dice de dónde viene.
    if (y + altoTitulos + medirFila(doc, seccion.filas[0]).alto > Y_LIMITE) {
      nuevaHoja(titulaRubro ? null : seccion.rubro)
    }

    if (titulaRubro) {
      dibujarTituloRubro(doc, seccion.rubro, y)
      y += ALTO_TITULO_RUBRO
      rubroAnterior = claveRubro
    }
    if (seccion.subrubro) {
      dibujarTituloSubrubro(doc, seccion.subrubro, y)
      y += ALTO_TITULO_SUBRUBRO
    }
    sombreada = false

    const titulo = seccion.subrubro ? `${seccion.rubro} · ${seccion.subrubro}` : seccion.rubro
    for (const fila of seccion.filas) {
      const medida = medirFila(doc, fila)
      if (y + medida.alto > Y_LIMITE) nuevaHoja(titulo)
      dibujarFila(doc, fila, medida, y, sombreada)
      y += medida.alto
      sombreada = !sombreada
    }
    y += 2
  }

  const total = doc.getNumberOfPages()
  for (let pagina = 1; pagina <= total; pagina++) {
    doc.setPage(pagina)
    dibujarPie(doc, pagina, total)
  }
  return doc
}

/** Arma la lista y la descarga. */
export function generarListaPrecios(datos: DatosListaPreciosPdf): void {
  const fecha = datos.fecha ?? new Date()
  construirListaPreciosPdf({ ...datos, fecha }).save(generateFilename('lista-precios', datos.sucursal, fecha))
}
