/**
 * Schemas de validación con Zod
 *
 * Centraliza todas las validaciones de formularios de la aplicación.
 * Cada schema incluye mensajes de error en español.
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
 * Monto positivo
 */
export const montoPositivoSchema = z
  .number({ invalid_type_error: 'Debe ser un número' })
  .positive({ message: 'El monto debe ser mayor a 0' })

/**
 * Monto no negativo (permite 0)
 */
export const montoNoNegativoSchema = z
  .number({ invalid_type_error: 'Debe ser un número' })
  .nonnegative({ message: 'El monto no puede ser negativo' })

/**
 * Cantidad entera positiva
 */
export const cantidadSchema = z
  .number({ invalid_type_error: 'Debe ser un número' })
  .int({ message: 'Debe ser un número entero' })
  .positive({ message: 'La cantidad debe ser mayor a 0' })

/**
 * Stock (entero no negativo)
 */
export const stockSchema = z
  .number({ invalid_type_error: 'Debe ser un número' })
  .int({ message: 'Debe ser un número entero' })
  .nonnegative({ message: 'El stock no puede ser negativo' })

// ============================================
// SCHEMAS DE CLIENTE
// ============================================

export const clienteSchema = z.object({
  nombre: z
    .string()
    .min(1, { message: 'El nombre es obligatorio' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'El nombre debe tener al menos 2 caracteres' }),

  nombre_fantasia: z
    .string()
    .min(1, { message: 'El nombre de fantasía es obligatorio' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'El nombre de fantasía debe tener al menos 2 caracteres' }),

  direccion: z
    .string()
    .min(1, { message: 'La dirección es obligatoria' })
    .transform(val => val.trim())
    .refine(val => val.length >= 5, { message: 'La dirección debe tener al menos 5 caracteres' }),

  telefono: telefonoSchema,
  email: emailSchema,
  cuit: cuitSchema,
  dni: dniSchema,

  tipo: z.enum(['minorista', 'mayorista', 'distribuidor'], {
    errorMap: () => ({ message: 'Tipo de cliente inválido' })
  }),

  zona: z
    .string()
    .min(1, { message: 'La zona es obligatoria' }),

  limite_credito: montoNoNegativoSchema.default(0),

  notas: z.string().optional()
})

/**
 * Schema para cliente rápido (creación simplificada en modal de pedido)
 */
export const clienteRapidoSchema = z.object({
  nombre: z
    .string()
    .min(1, { message: 'El nombre es obligatorio' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'El nombre debe tener al menos 2 caracteres' }),

  nombre_fantasia: z
    .string()
    .min(1, { message: 'El nombre de fantasía es obligatorio' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'El nombre de fantasía debe tener al menos 2 caracteres' }),

  direccion: z
    .string()
    .min(1, { message: 'La dirección es obligatoria' })
    .transform(val => val.trim())
    .refine(val => val.length >= 5, { message: 'La dirección debe tener al menos 5 caracteres' }),

  telefono: z.string().optional(),
  zona: z.string().min(1, { message: 'La zona es obligatoria' })
})

// ============================================
// SCHEMAS DE PRODUCTO
// ============================================

export const productoSchema = z.object({
  nombre: z
    .string()
    .min(1, { message: 'El nombre es obligatorio' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'El nombre debe tener al menos 2 caracteres' }),

  codigo: z
    .string()
    .transform(val => val.trim())
    .optional(),

  precio: montoPositivoSchema,

  costo_sin_iva: montoNoNegativoSchema.default(0),

  porcentaje_iva: z
    .number()
    .min(0, { message: 'El IVA no puede ser negativo' })
    .max(100, { message: 'El IVA no puede ser mayor a 100%' })
    .default(21),

  impuestos_internos: montoNoNegativoSchema.default(0),

  stock: stockSchema.default(0),

  stock_minimo: stockSchema.default(0),

  unidad: z.enum(['unidad', 'kg', 'litro', 'pack', 'caja', 'docena'], {
    errorMap: () => ({ message: 'Unidad inválida' })
  }).default('unidad'),

  categoria: z.string().optional()
})

// ============================================
// SCHEMAS DE PEDIDO
// ============================================

export const itemPedidoSchema = z.object({
  producto_id: z.string().uuid({ message: 'Producto inválido' }),
  cantidad: cantidadSchema,
  precio_unitario: montoPositivoSchema,
  descuento: z
    .number()
    .min(0, { message: 'El descuento no puede ser negativo' })
    .max(100, { message: 'El descuento no puede ser mayor a 100%' })
    .default(0)
})

export const pedidoSchema = z.object({
  cliente_id: z.string().uuid({ message: 'Debe seleccionar un cliente' }),

  items: z
    .array(itemPedidoSchema)
    .min(1, { message: 'Debe agregar al menos un producto' }),

  forma_pago: z.enum(['efectivo', 'transferencia', 'cheque', 'cuenta_corriente', 'tarjeta'], {
    errorMap: () => ({ message: 'Forma de pago inválida' })
  }),

  monto_pagado: montoNoNegativoSchema.default(0),

  notas: z.string().optional(),

  fecha_entrega: z.string().optional()
}).refine(
  (data) => {
    const total = data.items.reduce((sum, item) => {
      const subtotal = item.cantidad * item.precio_unitario
      const descuento = subtotal * (item.descuento / 100)
      return sum + (subtotal - descuento)
    }, 0)
    return data.monto_pagado <= total
  },
  { message: 'El monto pagado no puede ser mayor al total del pedido', path: ['monto_pagado'] }
)

// ============================================
// SCHEMAS DE PAGO
// ============================================

export const pagoSchema = z.object({
  cliente_id: z.string().uuid({ message: 'Cliente inválido' }),

  monto: montoPositivoSchema,

  forma_pago: z.enum(['efectivo', 'transferencia', 'cheque', 'tarjeta'], {
    errorMap: () => ({ message: 'Forma de pago inválida' })
  }),

  numero_cheque: z.string().optional(),

  banco: z.string().optional(),

  fecha_cheque: z.string().optional(),

  notas: z.string().optional()
}).refine(
  (data) => {
    // Si es cheque, el número es obligatorio
    if (data.forma_pago === 'cheque') {
      return data.numero_cheque && data.numero_cheque.trim().length > 0
    }
    return true
  },
  { message: 'El número de cheque es obligatorio para pagos con cheque', path: ['numero_cheque'] }
)

// ============================================
// SCHEMAS DE COMPRA
// ============================================

export const itemCompraSchema = z.object({
  producto_id: z.string().uuid({ message: 'Producto inválido' }),
  cantidad: cantidadSchema,
  costo_unitario: montoNoNegativoSchema,
  impuestos_internos: montoNoNegativoSchema.default(0),
  porcentaje_iva: z.number().min(0).max(100).default(21)
})

export const compraSchema = z.object({
  proveedor_id: z.string().uuid().optional(),
  proveedor_nombre: z.string().optional(),

  numero_factura: z.string().optional(),

  fecha_compra: z.string().min(1, { message: 'La fecha es obligatoria' }),

  forma_pago: z.enum(['efectivo', 'transferencia', 'cheque', 'cuenta_corriente', 'tarjeta'], {
    errorMap: () => ({ message: 'Forma de pago inválida' })
  }),

  items: z
    .array(itemCompraSchema)
    .min(1, { message: 'Debe agregar al menos un producto' }),

  notas: z.string().optional()
}).refine(
  (data) => {
    // Debe tener proveedor_id O proveedor_nombre
    return data.proveedor_id || (data.proveedor_nombre && data.proveedor_nombre.trim().length > 0)
  },
  { message: 'Debe seleccionar o ingresar un proveedor', path: ['proveedor_id'] }
)

// ============================================
// SCHEMAS DE MERMA
// ============================================

export const mermaSchema = z.object({
  producto_id: z.string().uuid({ message: 'Debe seleccionar un producto' }),

  cantidad: cantidadSchema,

  motivo: z.enum(['vencimiento', 'rotura', 'deterioro', 'robo', 'otro'], {
    errorMap: () => ({ message: 'Motivo inválido' })
  }),

  notas: z.string().optional()
})

// ============================================
// SCHEMAS DE USUARIO
// ============================================

export const usuarioSchema = z.object({
  nombre: z
    .string()
    .min(1, { message: 'El nombre es obligatorio' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'El nombre debe tener al menos 2 caracteres' }),

  email: z
    .string()
    .email({ message: 'Email inválido' })
    .min(1, { message: 'El email es obligatorio' }),

  rol: z.enum(['admin', 'preventista', 'transportista'], {
    errorMap: () => ({ message: 'Rol inválido' })
  }),

  zona: z.string().optional(),

  telefono: telefonoSchema
})

// ============================================
// SCHEMAS DE PROVEEDOR
// ============================================

export const proveedorSchema = z.object({
  nombre: z
    .string()
    .min(1, { message: 'El nombre es obligatorio' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'El nombre debe tener al menos 2 caracteres' }),

  cuit: cuitSchema,

  direccion: z.string().optional(),

  telefono: telefonoSchema,

  email: emailSchema,

  contacto: z.string().optional(),

  notas: z.string().optional()
})

// ============================================
// HELPERS DE VALIDACIÓN
// ============================================

export interface ValidationSuccess<T> {
  success: true;
  data: T;
  errors?: undefined;
}

export interface ValidationError {
  success: false;
  data?: undefined;
  errors: Record<string, string>;
}

export type ValidationResult<T> = ValidationSuccess<T> | ValidationError;

/**
 * Valida datos contra un schema y retorna resultado estructurado
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
 */
export function getFirstError<T>(schema: z.ZodSchema<T>, data: unknown): string | null {
  const result = schema.safeParse(data)

  if (result.success) return null

  // Zod v4 usa 'issues' en lugar de 'errors'
  const issues = result.error.issues || []
  return issues[0]?.message || 'Error de validación'
}

export interface FormValidator<T> {
  validate: (data: unknown) => ValidationResult<T>;
  validateField: (field: string, value: unknown) => string | null;
}

/**
 * Hook helper para usar validación en formularios React
 * Ejemplo de uso:
 * const { validate, errors, clearErrors } = useFormValidation(clienteSchema)
 */
export function createFormValidator<T>(schema: z.ZodObject<z.ZodRawShape>): FormValidator<T> {
  return {
    validate: (data: unknown) => validateForm(schema as z.ZodSchema<T>, data),
    validateField: (field: string, value: unknown) => {
      const fieldSchema = schema.shape[field]
      if (!fieldSchema) return null
      const result = fieldSchema.safeParse(value)
      return result.success ? null : (result.error.issues[0]?.message ?? null)
    }
  }
}

// ============================================
// SCHEMAS PARA MODALES (adaptados a nombres de formularios)
// ============================================

/**
 * Schema para ModalCliente - usa nombres de campos del formulario
 */
export const modalClienteSchema = z.object({
  tipo_documento: z.enum(['CUIT', 'DNI']).default('CUIT'),

  numero_documento: z
    .string()
    .transform(val => val.replace(/\D/g, ''))
    .refine(
      (val) => {
        // La validación depende del tipo_documento que no está disponible aquí
        // Se valida por longitud: 11 para CUIT, 7-8 para DNI
        return val.length === 0 || val.length === 11 || (val.length >= 7 && val.length <= 8)
      },
      { message: 'Documento inválido' }
    ),

  razonSocial: z
    .string()
    .min(1, { message: 'La razón social es obligatoria' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'La razón social debe tener al menos 2 caracteres' }),

  nombreFantasia: z
    .string()
    .min(1, { message: 'El nombre de fantasía es obligatorio' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'El nombre de fantasía debe tener al menos 2 caracteres' }),

  direccion: z
    .string()
    .min(1, { message: 'La dirección es obligatoria' })
    .transform(val => val.trim())
    .refine(val => val.length >= 5, { message: 'La dirección debe tener al menos 5 caracteres' }),

  telefono: z
    .string()
    .refine(val => !val || val.replace(/\D/g, '').length >= 8, {
      message: 'El teléfono debe tener al menos 8 dígitos'
    })
    .optional(),

  latitud: z.number().nullable().optional(),
  longitud: z.number().nullable().optional(),
  contacto: z.string().optional(),
  zona: z.string().optional(),
  horarios_atencion: z.string().optional(),
  rubro: z.string().optional(),
  notas: z.string().optional(),
  limiteCredito: z.coerce.number().nonnegative().default(0),
  diasCredito: z.coerce.number().int().nonnegative().default(30)
})

/**
 * Schema para ModalProducto - usa nombres de campos del formulario
 */
export const modalProductoSchema = z.object({
  nombre: z
    .string()
    .min(1, { message: 'El nombre es obligatorio' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'El nombre debe tener al menos 2 caracteres' }),

  codigo: z.string().optional(),
  categoria: z.string().optional(),

  stock: z.coerce
    .number({ invalid_type_error: 'El stock debe ser un número' })
    .int({ message: 'El stock debe ser un número entero' })
    .nonnegative({ message: 'El stock no puede ser negativo' }),

  stock_minimo: z.coerce
    .number()
    .int()
    .nonnegative()
    .default(10),

  porcentaje_iva: z.coerce.number().min(0).max(100).default(21),
  costo_sin_iva: z.coerce.number().nonnegative().optional(),
  costo_con_iva: z.coerce.number().nonnegative().optional(),
  impuestos_internos: z.coerce.number().nonnegative().optional(),
  precio_sin_iva: z.coerce.number().nonnegative().optional(),

  precio: z.coerce
    .number({ invalid_type_error: 'El precio debe ser un número' })
    .positive({ message: 'El precio debe ser mayor a 0' })
})

/**
 * Schema para ModalRegistrarPago
 */
export const modalPagoSchema = z.object({
  monto: z.coerce
    .number({ invalid_type_error: 'El monto debe ser un número' })
    .positive({ message: 'El monto debe ser mayor a $0' }),

  formaPago: z.enum(['efectivo', 'transferencia', 'cheque', 'tarjeta', 'cuenta_corriente'], {
    errorMap: () => ({ message: 'Forma de pago inválida' })
  }),

  referencia: z.string().optional(),
  notas: z.string().optional(),
  pedidoSeleccionado: z.string().optional()
}).refine(
  (data) => {
    if (data.formaPago === 'cheque') {
      return data.referencia && data.referencia.trim().length > 0
    }
    return true
  },
  { message: 'El número de cheque es obligatorio', path: ['referencia'] }
)

/**
 * Schema para ModalMermaStock
 */
export const modalMermaSchema = z.object({
  cantidad: z.coerce
    .number({ invalid_type_error: 'La cantidad debe ser un número' })
    .int({ message: 'La cantidad debe ser un número entero' })
    .positive({ message: 'La cantidad debe ser mayor a 0' }),

  motivo: z
    .string()
    .min(1, { message: 'Debe seleccionar un motivo' }),

  observaciones: z.string().optional()
})

/**
 * Schema para ModalProveedor
 */
export const modalProveedorSchema = z.object({
  nombre: z
    .string()
    .min(1, { message: 'El nombre es obligatorio' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'El nombre debe tener al menos 2 caracteres' }),

  cuit: z
    .string()
    .transform(val => val.replace(/\D/g, ''))
    .refine(val => val.length === 0 || val.length === 11, {
      message: 'El CUIT debe tener 11 dígitos'
    })
    .optional(),

  direccion: z.string().optional(),
  latitud: z.number().nullable().optional(),
  longitud: z.number().nullable().optional(),
  telefono: z.string().optional(),

  email: z
    .string()
    .email({ message: 'El email no es válido' })
    .or(z.literal(''))
    .optional(),

  contacto: z.string().optional(),
  notas: z.string().optional()
})

// ============================================
// EXPORTS NOMBRADOS PARA TESTS
// ============================================

export const schemas = {
  cliente: clienteSchema,
  clienteRapido: clienteRapidoSchema,
  producto: productoSchema,
  pedido: pedidoSchema,
  itemPedido: itemPedidoSchema,
  pago: pagoSchema,
  compra: compraSchema,
  itemCompra: itemCompraSchema,
  merma: mermaSchema,
  usuario: usuarioSchema,
  proveedor: proveedorSchema,
  // Schemas para modales
  modalCliente: modalClienteSchema,
  modalProducto: modalProductoSchema,
  modalPago: modalPagoSchema,
  modalMerma: modalMermaSchema,
  modalProveedor: modalProveedorSchema
}

export default schemas
