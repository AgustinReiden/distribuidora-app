/**
 * Utilidades compartidas para modales
 * @module components/modals/utils
 */

/**
 * Formatea una fecha en formato localizado argentino
 * @param fecha - Fecha a formatear
 * @returns Fecha formateada como "DD/MM/YYYY HH:MM"
 * @example
 * formatFecha(new Date()) // "19/01/2026 15:30"
 * formatFecha("2026-01-19T15:30:00") // "19/01/2026 15:30"
 */
export const formatFecha = (fecha: Date | string): string => new Date(fecha).toLocaleString('es-AR', {
  day: '2-digit',
  month: '2-digit',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit'
});

/**
 * Valida un numero de telefono
 * Acepta formatos con espacios, guiones y parentesis
 * @param telefono - Telefono a validar
 * @returns true si es valido o esta vacio (opcional), false si es invalido
 * @example
 * validarTelefono("+54 11 1234-5678") // true
 * validarTelefono("123") // false (muy corto)
 * validarTelefono("") // true (es opcional)
 */
export const validarTelefono = (telefono: string): boolean => {
  if (!telefono) return true; // Opcional
  const telefonoLimpio = telefono.replace(/[\s\-()]/g, '');
  return /^[0-9+]{6,15}$/.test(telefonoLimpio);
};

/**
 * Valida un texto con longitud minima y maxima
 * @param texto - Texto a validar
 * @param minLength - Longitud minima requerida (default: 2)
 * @param maxLength - Longitud maxima permitida (default: 100)
 * @returns true si el texto cumple con los requisitos
 * @example
 * validarTexto("Juan Perez") // true
 * validarTexto("A") // false (muy corto)
 * validarTexto("", 0) // true (minLength=0)
 */
export const validarTexto = (texto: string, minLength: number = 2, maxLength: number = 100): boolean => {
  if (!texto) return false;
  const limpio = texto.trim();
  return limpio.length >= minLength && limpio.length <= maxLength;
};

/**
 * Valida un email con formato basico
 * @param email - Email a validar
 * @returns true si el formato es valido o esta vacio
 * @example
 * validarEmail("user@example.com") // true
 * validarEmail("invalid") // false
 */
export const validarEmail = (email: string): boolean => {
  if (!email) return true; // Opcional
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
};

/** Pesos del dígito verificador del CUIT/CUIL (módulo 11). */
const PESOS_CUIT = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2];

/**
 * Valida un CUIT argentino: 11 dígitos (con o sin guiones) y dígito
 * verificador correcto (módulo 11). Vacío se permite (es opcional).
 * Decisión del dueño en #1561 (D37, 1561-b11): uno inválido se rechaza.
 * El server lo valida igual al guardar un CUIT nuevo o cambiado
 * (`clientes_tipo_documento_del_valor`, catalogo-B1 de la tanda 6 de #1603).
 * @param cuit - CUIT a validar
 * @returns true si es válido o está vacío
 * @example
 * validarCuit("20-12345678-6") // true
 * validarCuit("20-12345678-9") // false (dígito verificador)
 * validarCuit("20123456786") // true (sin guiones)
 */
export const validarCuit = (cuit: string): boolean => {
  if (!cuit) return true; // Opcional
  const cuitLimpio = cuit.replace(/[-\s]/g, '');
  if (!/^[0-9]{11}$/.test(cuitLimpio)) return false;
  const suma = PESOS_CUIT.reduce((acc, peso, i) => acc + peso * Number(cuitLimpio[i]), 0);
  const resto = suma % 11;
  // Resto 1 daría un dígito de 10: no existe CUIT con esa combinación.
  if (resto === 1) return false;
  const esperado = resto === 0 ? 0 : 11 - resto;
  return esperado === Number(cuitLimpio[10]);
};

/**
 * Mensaje de error de un CUIT tipeado, o null si se puede guardar.
 * @param cuit - Lo que hay en el campo
 * @param original - El CUIT con el que se abrió la ficha: uno viejo que no se
 *   tocó no bloquea guardar otros cambios (el rechazo es para lo que se escribe).
 */
export const errorDeCuit = (cuit: string, original?: string | null): string | null => {
  const digitos = (cuit || '').replace(/\D/g, '');
  if (digitos.length === 0) return null;
  if (original && digitos === original.replace(/\D/g, '')) return null;
  if (digitos.length !== 11) return 'El CUIT debe tener 11 dígitos';
  // Ningún CUIT empieza con 00: era un número inventado rellenado con ceros, de cuando el
  // campo era obligatorio, o un DNI (B17, #1561).
  if (digitos.startsWith('00')) {
    return 'Un CUIT no empieza con 00. Si es un DNI, elegí «DNI» en el tipo de documento; si el cliente no tiene documento, dejá el campo vacío.';
  }
  if (!validarCuit(digitos)) {
    return 'El CUIT no es válido: el dígito verificador no coincide. Revisá los números.';
  }
  return null;
};

/**
 * Error del documento de un cliente según su tipo, o null si se puede guardar.
 * CUIT: 11 dígitos y dígito verificador (D37 de #1561); DNI: 7 u 8 cifras, sin
 * contar los ceros de adelante (la base rechaza un número corto rellenado, B17).
 * Vacío se permite. `original` es el documento con el que se abrió la ficha.
 */
export const errorDeDocumento = (
  tipo: 'CUIT' | 'DNI',
  numero: string,
  original?: string | null
): string | null => {
  const digitos = (numero || '').replace(/\D/g, '');
  if (digitos.length === 0) return null;
  if (tipo === 'CUIT') return errorDeCuit(numero, original);
  const cifras = digitos.replace(/^0+/, '').length;
  return digitos.length <= 8 && cifras >= 7 ? null : 'El DNI debe tener 7 u 8 dígitos';
};

/**
 * Sanitiza un texto removiendo caracteres peligrosos
 * @param texto - Texto a sanitizar
 * @returns Texto sanitizado
 */
export const sanitizarTexto = (texto: string): string => {
  if (!texto) return '';
  return texto.trim().replace(/[<>]/g, '');
};
