/**
 * Schema Zod de la respuesta de la edge function `escanear-factura`.
 *
 * Co-locado con el modal (CLAUDE.md): ModalCompra es lazy, y un schema
 * importado de un chunk compartido haría que un bundle viejo del PWA valide
 * contra una versión desincronizada y tire "Invalid input" sin error de chunk.
 * Sólo lo importa ModalCompra.tsx (y su test).
 */
import { z } from 'zod'
import type { AdvertenciaEscaneo, FacturaV2Escaneo } from '../../utils/escaneoFactura'

const num = z.number().finite()
const numNull = num.nullable()
const strNull = z.string().nullable()

export const FacturaV2Schema = z.object({
  version: z.literal(2),
  tipoComprobante: z.enum(['A', 'B', 'C', 'M', 'remito', 'otro']),
  tipoFactura: z.enum(['FC', 'ZZ']).nullable(),
  puntoVenta: strNull,
  numero: strNull,
  numeroCompleto: strNull,
  fechaEmision: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).nullable(),
  proveedor: z.object({ nombre: strNull, cuit: strNull }),
  condicionVenta: strNull,
  items: z.array(z.object({
    codigo: strNull,
    descripcion: z.string(),
    cantidad: numNull,
    unidad: z.enum(['bulto', 'unidad']).nullable(),
    unidadesPorBulto: numNull,
    precioUnitarioNeto: numNull,
    bonificacionPct: numNull,
    importeNeto: numNull,
    alicuotaIva: numNull,
    impuestoInternoMonto: numNull,
    legible: z.boolean(),
  })),
  pie: z.object({
    netoGravado: numNull,
    noGravado: numNull,
    exento: numNull,
    iva: z.array(z.object({ alicuota: num, monto: num })),
    impuestosInternos: z.array(z.object({ tasa: numNull, monto: num })),
    percepcionIva: numNull,
    percepcionIibb: numNull,
    otrosTributos: numNull,
    descuentosPie: z.array(z.object({ descripcion: z.string(), monto: num })),
    total: numNull,
  }),
  confianza: num.min(0).max(1),
})

export const AdvertenciaSchema = z.object({
  nivel: z.enum(['error', 'aviso']),
  codigo: z.string(),
  mensaje: z.string(),
  linea: z.number().int().positive().optional(),
})

export const RespuestaEscaneoSchema = z.discriminatedUnion('success', [
  z.object({
    success: z.literal(true),
    data: FacturaV2Schema,
    advertencias: z.array(AdvertenciaSchema),
    modelo: z.string(),
  }),
  z.object({ success: z.literal(false), error: z.string() }),
])

export type RespuestaEscaneo = z.infer<typeof RespuestaEscaneoSchema>

// El util de mapeo declara los tipos a mano (no puede importar de acá). Si el
// schema y esos tipos se separan, esto deja de compilar.
type Igual<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false
const _facturaCompatible: Igual<z.infer<typeof FacturaV2Schema>, FacturaV2Escaneo> = true
const _advertenciaCompatible: Igual<z.infer<typeof AdvertenciaSchema>, AdvertenciaEscaneo> = true
void _facturaCompatible
void _advertenciaCompatible
