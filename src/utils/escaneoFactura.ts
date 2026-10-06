/**
 * Escáner de facturas (Entrega A): del resultado v2 de la edge function
 * `escanear-factura` al `FacturaEscaneada` que ya consume ModalCompra
 * (preview → APLICAR_ESCANEO → vínculo de productos).
 *
 * Lógica pura y testeada. El schema Zod que valida la respuesta NO vive acá:
 * va co-locado en el modal (ModalCompra.escaneo.ts), ver CLAUDE.md.
 */

/** Lo que devuelve la edge function en `data` (supabase/functions/escanear-factura/validacion.ts). */
export interface FacturaV2Escaneo {
  version: 2
  tipoComprobante: 'A' | 'B' | 'C' | 'M' | 'remito' | 'otro'
  tipoFactura: 'FC' | 'ZZ' | null
  puntoVenta: string | null
  numero: string | null
  numeroCompleto: string | null
  fechaEmision: string | null
  proveedor: { nombre: string | null; cuit: string | null }
  condicionVenta: string | null
  items: Array<{
    codigo: string | null
    descripcion: string
    cantidad: number | null
    unidad: 'bulto' | 'unidad' | null
    unidadesPorBulto: number | null
    precioUnitarioNeto: number | null
    /** PORCENTAJE de la línea (10 = 10%), la misma semántica que `bonificacion` de la compra. */
    bonificacionPct: number | null
    importeNeto: number | null
    alicuotaIva: number | null
    impuestoInternoMonto: number | null
    legible: boolean
  }>
  pie: {
    netoGravado: number | null
    noGravado: number | null
    exento: number | null
    iva: Array<{ alicuota: number; monto: number }>
    impuestosInternos: Array<{ tasa: number | null; monto: number }>
    percepcionIva: number | null
    percepcionIibb: number | null
    otrosTributos: number | null
    descuentosPie: Array<{ descripcion: string; monto: number }>
    total: number | null
  }
  confianza: number
}

export interface AdvertenciaEscaneo {
  nivel: 'error' | 'aviso'
  codigo: string
  mensaje: string
  /** 1-based; ausente = de la factura entera. */
  linea?: number
}

/** Mismo shape que `FacturaEscaneada` del reducer (se repite para no importar del modal). */
export interface FacturaEscaneadaMapeada {
  proveedorNombre: string | null
  proveedorCuit: string | null
  numeroFactura: string | null
  fechaCompra: string | null
  items: Array<{
    codigo: string | null
    descripcion: string
    cantidad: number
    costoUnitario: number
    bonificacion: number
    /** null = la factura no la dice (B, C, remito): se usa la del producto. */
    iva: number | null
  }>
  subtotal: number | null
  iva: number | null
  total: number | null
  formaPago: string | null
  confianza: number
  tipoFactura: 'FC' | 'ZZ' | null
  /** mig 293. La letra si el comprobante es una factura (A/B/C/M); null si no. */
  letraComprobante: 'A' | 'B' | 'C' | 'M' | null
  /** Totales impresos para "Control contra factura". Sólo los que se leyeron. */
  control: { gravado?: number; iva?: number; impuestosInternos?: number; percepciones?: number; total?: number }
  advertencias: AdvertenciaEscaneo[]
}

/** Tipos que acepta el bucket `facturas` (mig 239) → extensión canónica de la ruta. */
const EXTENSION_POR_MIME: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'image/heif': 'heic',
  'application/pdf': 'pdf',
}

export const CONTENT_TYPE_POR_EXTENSION: Record<string, string> = {
  jpg: 'image/jpeg',
  png: 'image/png',
  webp: 'image/webp',
  heic: 'image/heic',
  pdf: 'application/pdf',
}

/**
 * Extensión de la ruta para el archivo elegido, o null si no se puede
 * escanear. Por el MIME y, si el navegador no lo informa (pasa con HEIC en
 * algunos Android/Windows), por la extensión del nombre.
 */
export function extensionArchivoFactura(file: { type: string; name: string }): string | null {
  const porMime = EXTENSION_POR_MIME[file.type.toLowerCase()]
  if (porMime) return porMime
  if (file.type && file.type !== 'application/octet-stream') return null
  const ext = file.name.split('.').pop()?.toLowerCase() ?? ''
  const normal = ext === 'jpeg' ? 'jpg' : ext === 'heif' ? 'heic' : ext
  return normal in CONTENT_TYPE_POR_EXTENSION ? normal : null
}

/**
 * Objeto del bucket `facturas`: `<sucursal_id>/<uuid>.<ext>`. La edge function
 * rechaza cualquier otra forma, y un prefijo que no sea la sucursal activa.
 */
export function rutaEscaneoFactura(sucursalId: number, uuid: string, ext: string): string {
  return `${sucursalId}/${uuid.toLowerCase()}.${ext}`
}

/**
 * UUID v4 para el nombre del objeto. `crypto.randomUUID` falta en Safari < 15.4
 * (y en jsdom); `getRandomValues` está en todos lados.
 */
export function nuevoUuid(): string {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID()
  const b = crypto.getRandomValues(new Uint8Array(16))
  b[6] = (b[6] & 0x0f) | 0x40
  b[8] = (b[8] & 0x3f) | 0x80
  const h = Array.from(b, x => x.toString(16).padStart(2, '0')).join('')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}

/** "Contado" / "Cta. Cte." / "30 días" → forma de pago de la compra, o null. */
export function formaPagoDesdeCondicion(condicion: string | null): string | null {
  if (!condicion) return null
  const c = condicion.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
  if (/transf/.test(c)) return 'transferencia'
  if (/cheque|echeq/.test(c)) return 'cheque'
  if (/tarjeta/.test(c)) return 'tarjeta'
  if (/cuenta|cta|cte|credito|\d+\s*d(ias)?\b|plazo/.test(c)) return 'cuenta_corriente'
  if (/contado|efectivo/.test(c)) return 'efectivo'
  return null
}

const sumar = (ns: number[]) => ns.reduce((a, n) => a + n, 0)

/**
 * Comprobante leído → tipo y letra de la compra (mig 293). Sale de
 * `tipoComprobante` y no del `tipoFactura` de la respuesta a propósito: la edge
 * function vieja mandaba B y C como ZZ, y así el front queda bien con las dos
 * versiones mientras se despliega.
 *
 *   A, B, C, M → FC con esa letra. B y C son facturas: la letra es la que hace
 *                que el costo sea lo pagado (como ZZ) y el IVA no sea crédito.
 *   remito     → ZZ, sin letra.
 *   otro       → no se toca: elige el usuario.
 */
export function comprobanteEscaneado(
  tipo: FacturaV2Escaneo['tipoComprobante'],
): Pick<FacturaEscaneadaMapeada, 'tipoFactura' | 'letraComprobante'> {
  switch (tipo) {
    case 'A':
    case 'B':
    case 'C':
    case 'M':
      return { tipoFactura: 'FC', letraComprobante: tipo }
    case 'remito':
      return { tipoFactura: 'ZZ', letraComprobante: null }
    default:
      return { tipoFactura: null, letraComprobante: null }
  }
}

/**
 * v2 → FacturaEscaneada. Copia, no recalcula: un número que no cierra ya
 * viene marcado en `advertencias` y se muestra en la vista previa.
 *
 *  - `costoUnitario` = `precioUnitarioNeto` (antes de la bonificación).
 *  - `bonificacion` = `bonificacionPct`: los dos son % de la línea.
 *  - `iva` = `alicuotaIva`, null si la factura no la discrimina.
 */
export function mapearFacturaV2(data: FacturaV2Escaneo, advertencias: AdvertenciaEscaneo[]): FacturaEscaneadaMapeada {
  const { pie } = data
  const control: FacturaEscaneadaMapeada['control'] = {}
  if (pie.netoGravado != null) control.gravado = pie.netoGravado
  if (pie.iva.length > 0) control.iva = sumar(pie.iva.map(e => e.monto))
  if (pie.impuestosInternos.length > 0) control.impuestosInternos = sumar(pie.impuestosInternos.map(e => e.monto))
  if (pie.percepcionIva != null || pie.percepcionIibb != null) {
    control.percepciones = (pie.percepcionIva ?? 0) + (pie.percepcionIibb ?? 0)
  }
  if (pie.total != null) control.total = pie.total

  return {
    proveedorNombre: data.proveedor.nombre,
    proveedorCuit: data.proveedor.cuit,
    numeroFactura: data.numeroCompleto,
    fechaCompra: data.fechaEmision,
    items: data.items.map(l => ({
      codigo: l.codigo,
      descripcion: l.descripcion,
      cantidad: l.cantidad ?? 0,
      costoUnitario: l.precioUnitarioNeto ?? 0,
      bonificacion: l.bonificacionPct ?? 0,
      iva: l.alicuotaIva,
    })),
    subtotal: pie.netoGravado,
    iva: control.iva ?? null,
    total: pie.total,
    formaPago: formaPagoDesdeCondicion(data.condicionVenta),
    confianza: data.confianza,
    ...comprobanteEscaneado(data.tipoComprobante),
    control,
    advertencias,
  }
}
