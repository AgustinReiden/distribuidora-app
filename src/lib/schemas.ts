/**
 * Schemas de validación con Zod
 *
 * Primitivos reutilizables (CUIT, DNI, montos, etc.), los helpers de
 * validación (`validateForm`, `getFirstError`, `createFormValidator`) y los
 * diccionarios de labels compartidos entre vistas de salvedades.
 *
 * Los schemas de un modal lazy NO viven acá: van co-locados en el propio
 * modal (ver `src/components/modals/Modal*.tsx`), para que la validación
 * viaje siempre en el mismo chunk que la UI que la usa.
 */

import { z } from 'zod'

// ============================================
// SCHEMAS BASE / REUTILIZABLES
// ============================================

/**
 * Validación de CUIT argentino (11 dígitos)
 */
export const cuitSchema = z
  .string()
  .transform(val => val.replace(/\D/g, ''))
  .refine(val => val.length === 0 || val.length === 11, {
    message: 'El CUIT debe tener 11 dígitos'
  })
  .optional()

/**
 * Validación de DNI argentino (7-8 dígitos)
 */
export const dniSchema = z
  .string()
  .transform(val => val.replace(/\D/g, ''))
  .refine(val => val.length === 0 || (val.length >= 7 && val.length <= 8), {
    message: 'El DNI debe tener 7 u 8 dígitos'
  })
  .optional()

/**
 * Validación de email
 */
export const emailSchema = z
  .string()
  .email({ message: 'Email inválido' })
  .or(z.literal(''))
  .optional()

/**
 * Validación de teléfono
 */
export const telefonoSchema = z
  .string()
  .min(8, { message: 'El teléfono debe tener al menos 8 dígitos' })
  .or(z.literal(''))
  .optional()

/**
 * Condición frente al IVA (mig 177). Distingue "no gravado" de "0% gravado",
 * que hasta ahora eran indistinguibles. La BD tiene un CHECK de coherencia: si
 * no es `gravado`, la alícuota tiene que ser 0.
 */
export const condicionIvaSchema = z
  .enum(['gravado', 'exento', 'no_gravado'], { error: 'Condición de IVA inválida' })
  .default('gravado')

/**
 * Monto positivo
 */
export const montoPositivoSchema = z
  .number({ error: 'Debe ser un número' })
  .positive({ message: 'El monto debe ser mayor a 0' })

/**
 * Monto no negativo (permite 0)
 */
export const montoNoNegativoSchema = z
  .number({ error: 'Debe ser un número' })
  .nonnegative({ message: 'El monto no puede ser negativo' })

/**
 * Cantidad entera positiva
 */
export const cantidadSchema = z
  .number({ error: 'Debe ser un número' })
  .int({ message: 'Debe ser un número entero' })
  .positive({ message: 'La cantidad debe ser mayor a 0' })

/**
 * Stock (entero no negativo)
 */
export const stockSchema = z
  .number({ error: 'Debe ser un número' })
  .int({ message: 'Debe ser un número entero' })
  .nonnegative({ message: 'El stock no puede ser negativo' })

// ============================================
// HELPERS DE VALIDACIÓN
// ============================================

export interface ValidationSuccess<T> {
  success: true
  data: T
  errors?: undefined
}

export interface ValidationError {
  success: false
  data?: undefined
  errors: Record<string, string>
}

export type ValidationResult<T> = ValidationSuccess<T> | ValidationError

/**
 * Valida datos contra un schema y retorna resultado estructurado
 * @param schema - Zod schema to validate against
 * @param data - Data to validate
 * @returns Validation result with data or errors
 */
export function validateForm<T>(schema: z.ZodSchema<T>, data: unknown): ValidationResult<T> {
  const result = schema.safeParse(data)

  if (result.success) {
    return { success: true, data: result.data }
  }

  // Convertir errores a un objeto con paths como keys
  // Zod v4 usa 'issues' en lugar de 'errors'
  const errors: Record<string, string> = {}
  const issues = result.error.issues || []
  for (const issue of issues) {
    const path = issue.path.join('.')
    if (!errors[path]) {
      errors[path] = issue.message
    }
  }

  return { success: false, errors }
}

/**
 * Obtiene el primer mensaje de error de una validación fallida
 * @param schema - Zod schema to validate against
 * @param data - Data to validate
 * @returns First error message or null if valid
 */
export function getFirstError<T>(schema: z.ZodSchema<T>, data: unknown): string | null {
  const result = schema.safeParse(data)

  if (result.success) return null

  // Zod v4 usa 'issues' en lugar de 'errors'
  const issues = result.error.issues || []
  return issues[0]?.message || 'Error de validación'
}

export interface FormValidator<T> {
  /** Validates the entire form data */
  validate: (data: unknown) => ValidationResult<T>
  /** Validates a single field */
  validateField: (field: string, value: unknown) => string | null
}

/**
 * Hook helper para usar validación en formularios React
 * Ejemplo de uso:
 * const { validate, errors, clearErrors } = useFormValidation(clienteSchema)
 * @param schema - Zod object schema
 * @returns Form validator with validate and validateField methods
 */
export function createFormValidator<T>(schema: z.ZodObject<z.ZodRawShape>): FormValidator<T> {
  return {
    validate: (data: unknown) => validateForm(schema as z.ZodSchema<T>, data),
    validateField: (field: string, value: unknown): string | null => {
      const fieldSchema = schema.shape[field] as z.ZodSchema | undefined
      if (!fieldSchema) return null
      const result = fieldSchema.safeParse(value)
      return result.success ? null : (result.error.issues[0]?.message ?? null)
    }
  }
}

// ============================================
// SCHEMAS DE SALVEDADES
// ============================================

export const motivoSalvedadSchema = z.enum([
  'faltante_stock',
  'producto_danado',
  'cliente_rechaza',
  'error_pedido',
  'producto_vencido',
  'diferencia_precio',
  'otro'
], {
  error: 'Motivo no válido'
})

export type MotivoSalvedadSchema = z.infer<typeof motivoSalvedadSchema>

export const estadoResolucionSalvedadSchema = z.enum([
  'reprogramada',
  'nota_credito',
  'descuento_transportista',
  'absorcion_empresa',
  'resuelto_otro',
  'anulada'
], {
  error: 'Estado de resolución no válido'
})

export type EstadoResolucionSalvedadSchema = z.infer<typeof estadoResolucionSalvedadSchema>

export const registrarSalvedadSchema = z.object({
  pedidoItemId: z.string().min(1, { message: 'Debe seleccionar un item' }),
  cantidadAfectada: z.coerce
    .number({ error: 'La cantidad debe ser un número' })
    .int({ message: 'La cantidad debe ser un número entero' })
    .positive({ message: 'La cantidad debe ser mayor a 0' }),
  motivo: motivoSalvedadSchema,
  descripcion: z.string().optional(),
  devolverStock: z.boolean().default(true)
})

export type RegistrarSalvedadFormData = z.infer<typeof registrarSalvedadSchema>

export const resolverSalvedadSchema = z.object({
  estadoResolucion: estadoResolucionSalvedadSchema,
  notas: z.string().min(5, { message: 'Debe agregar notas de la resolución (mínimo 5 caracteres)' }),
  pedidoReprogramadoId: z.string().optional()
})

export type ResolverSalvedadFormData = z.infer<typeof resolverSalvedadSchema>

// ============================================
// SCHEMAS PARA MODALES ADICIONALES
// ============================================

/**
 * Schema para ModalCompra (validación de formulario de compra)
 */
export const modalCompraSchema = z.object({
  proveedorId: z.string().optional(),
  proveedorNombre: z.string().optional(),
  usarProveedorNuevo: z.boolean(),
  fechaCompra: z.string().min(1, { message: 'La fecha es obligatoria' }),
  formaPago: z.enum(['efectivo', 'transferencia', 'cheque', 'cuenta_corriente', 'tarjeta'], {
    message: 'Forma de pago inválida'
  }),
  tipoFactura: z.enum(['ZZ', 'FC']).default('FC'),
  items: z.array(z.object({
    productoId: z.string(),
    cantidad: z.number().positive({ message: 'La cantidad debe ser mayor a 0' }),
    costoUnitario: z.number().nonnegative(),
    bonificacion: z.number().int().nonnegative().default(0)
  })).min(1, { message: 'Debe agregar al menos un producto' })
})

export type ModalCompraFormData = z.infer<typeof modalCompraSchema>

/**
 * Schema para validar items de salvedad en ModalEntregaConSalvedad
 */
export const itemSalvedadSchema = z.object({
  itemId: z.string(),
  cantidadAfectada: z.number()
    .int({ message: 'La cantidad debe ser un número entero' })
    .positive({ message: 'La cantidad debe ser mayor a 0' }),
  motivo: motivoSalvedadSchema,
  descripcion: z.string().optional()
}).refine(
  (data) => {
    if (data.motivo === 'otro') {
      return data.descripcion && data.descripcion.trim().length >= 10
    }
    return true
  },
  { message: 'Debe especificar una descripción (mínimo 10 caracteres)', path: ['descripcion'] }
)

export type ItemSalvedadFormData = z.infer<typeof itemSalvedadSchema>

// Etiquetas para mostrar en UI
export const MOTIVOS_SALVEDAD_LABELS: Record<MotivoSalvedadSchema, string> = {
  faltante_stock: 'Faltante de Stock',
  producto_danado: 'Producto Dañado',
  cliente_rechaza: 'Cliente Rechaza',
  error_pedido: 'Error en Pedido',
  producto_vencido: 'Producto Vencido',
  diferencia_precio: 'Diferencia de Precio',
  otro: 'Otro'
}

export const ESTADOS_RESOLUCION_LABELS: Record<EstadoResolucionSalvedadSchema | 'pendiente', string> = {
  pendiente: 'Pendiente',
  reprogramada: 'Reprogramada',
  nota_credito: 'Nota de Crédito',
  descuento_transportista: 'Descuento a Transportista',
  absorcion_empresa: 'Absorción Empresa',
  resuelto_otro: 'Resuelto (Otro)',
  anulada: 'Anulada'
}

