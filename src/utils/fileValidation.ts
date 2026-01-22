/**
 * Utilidades de validación de archivos para seguridad
 *
 * Previene ataques mediante:
 * - Validación de tipos MIME y extensiones
 * - Límites de tamaño de archivo
 * - Validación de estructura básica
 */

// Configuración de límites
export const FILE_LIMITS = {
  maxSizeBytes: 10 * 1024 * 1024, // 10MB máximo
  maxSizeMB: 10
} as const;

// Tipos de archivo permitidos para Excel
export const EXCEL_CONFIG = {
  allowedExtensions: ['.xlsx', '.xls'],
  allowedMimeTypes: [
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', // .xlsx
    'application/vnd.ms-excel', // .xls
    'application/octet-stream' // Algunos navegadores reportan esto
  ],
  maxRows: 10000 // Límite de filas para prevenir DoS
} as const;

export interface ValidationResult {
  valid: boolean;
  error?: string;
  warnings?: string[];
}

export interface SanitizedDataResult extends ValidationResult {
  data?: Record<string, unknown>[];
}

/**
 * Valida un archivo Excel antes de procesarlo
 */
export function validateExcelFile(file: File | null | undefined): ValidationResult {
  if (!file) {
    return { valid: false, error: 'No se proporcionó ningún archivo' }
  }

  // Validar tamaño
  if (file.size > FILE_LIMITS.maxSizeBytes) {
    return {
      valid: false,
      error: `El archivo excede el tamaño máximo permitido (${FILE_LIMITS.maxSizeMB}MB)`
    }
  }

  // Validar tamaño mínimo (archivos vacíos o sospechosamente pequeños)
  if (file.size < 100) {
    return {
      valid: false,
      error: 'El archivo parece estar vacío o corrupto'
    }
  }

  // Validar extensión
  const fileName = file.name.toLowerCase()
  const hasValidExtension = EXCEL_CONFIG.allowedExtensions.some(ext =>
    fileName.endsWith(ext)
  )

  if (!hasValidExtension) {
    return {
      valid: false,
      error: `Tipo de archivo no permitido. Solo se aceptan archivos ${EXCEL_CONFIG.allowedExtensions.join(', ')}`
    }
  }

  // Validar tipo MIME (algunos navegadores pueden no reportarlo correctamente)
  if (file.type && !(EXCEL_CONFIG.allowedMimeTypes as readonly string[]).includes(file.type)) {
    console.warn(`[FileValidation] MIME type inesperado: ${file.type}, pero extensión válida`)
    // No rechazar por MIME ya que algunos navegadores reportan incorrectamente
  }

  return { valid: true }
}

/**
 * Valida datos parseados de Excel
 */
export function validateExcelData(data: unknown): ValidationResult {
  const warnings: string[] = []

  if (!Array.isArray(data)) {
    return { valid: false, error: 'El archivo no contiene datos válidos' }
  }

  if (data.length === 0) {
    return { valid: false, error: 'El archivo está vacío o no tiene datos' }
  }

  // Verificar límite de filas
  if (data.length > EXCEL_CONFIG.maxRows) {
    return {
      valid: false,
      error: `El archivo excede el límite de ${EXCEL_CONFIG.maxRows.toLocaleString()} filas. Por favor, divida el archivo.`
    }
  }

  // Advertir si hay muchas filas
  if (data.length > 1000) {
    warnings.push(`El archivo contiene ${data.length.toLocaleString()} filas. El procesamiento puede tomar tiempo.`)
  }

  // Verificar que las filas tengan datos
  const filasVacias = (data as Record<string, unknown>[]).filter(row =>
    !row || Object.keys(row).length === 0 ||
    Object.values(row).every(v => v === null || v === undefined || v === '')
  ).length

  if (filasVacias === data.length) {
    return { valid: false, error: 'Todas las filas están vacías' }
  }

  if (filasVacias > 0) {
    warnings.push(`Se encontraron ${filasVacias} filas vacías que serán ignoradas`)
  }

  return { valid: true, warnings: warnings.length > 0 ? warnings : undefined }
}

/**
 * Sanitiza un valor de celda Excel
 */
export function sanitizeExcelValue(value: unknown): string | number | null {
  if (value === null || value === undefined) {
    return null
  }

  // Si es número, devolverlo directamente
  if (typeof value === 'number') {
    return isFinite(value) ? value : null
  }

  // Si es string, sanitizar
  if (typeof value === 'string') {
    // Remover caracteres de control (excluye tab, newline, carriage return)
    // eslint-disable-next-line no-control-regex
    let sanitized = value.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '')

    // Truncar strings muy largos (prevención de memoria)
    if (sanitized.length > 1000) {
      sanitized = sanitized.substring(0, 1000)
    }

    // Prevenir fórmulas de inyección (aunque xlsx ya las debería manejar)
    if (/^[=+\-@]/.test(sanitized)) {
      // Escapar prefijos de fórmula
      sanitized = "'" + sanitized
    }

    return sanitized.trim()
  }

  // Otros tipos, convertir a string
  return String(value).substring(0, 1000)
}

/**
 * Valida y sanitiza datos de un archivo Excel completo
 */
export function validateAndSanitizeExcelData(data: unknown): SanitizedDataResult {
  // Primero validar estructura
  const validation = validateExcelData(data)
  if (!validation.valid) {
    return validation
  }

  // Sanitizar cada celda
  const sanitizedData = (data as Record<string, unknown>[]).map(row => {
    if (!row || typeof row !== 'object') return null

    const sanitizedRow: Record<string, string | number | null> = {}
    for (const [key, value] of Object.entries(row)) {
      // Sanitizar nombre de columna
      const sanitizedKey = sanitizeExcelValue(key)
      if (sanitizedKey && typeof sanitizedKey === 'string') {
        sanitizedRow[sanitizedKey] = sanitizeExcelValue(value)
      }
    }
    return Object.keys(sanitizedRow).length > 0 ? sanitizedRow : null
  }).filter((row): row is Record<string, string | number | null> => row !== null)

  return {
    valid: true,
    data: sanitizedData,
    warnings: validation.warnings
  }
}

export default {
  validateExcelFile,
  validateExcelData,
  sanitizeExcelValue,
  validateAndSanitizeExcelData,
  FILE_LIMITS,
  EXCEL_CONFIG
}
