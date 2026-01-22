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

/**
 * Valida un CUIT argentino (formato XX-XXXXXXXX-X)
 * @param cuit - CUIT a validar
 * @returns true si el formato es valido o esta vacio
 * @example
 * validarCuit("20-12345678-9") // true
 * validarCuit("20123456789") // true (sin guiones)
 */
export const validarCuit = (cuit: string): boolean => {
  if (!cuit) return true; // Opcional
  const cuitLimpio = cuit.replace(/-/g, '');
  return /^[0-9]{11}$/.test(cuitLimpio);
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
