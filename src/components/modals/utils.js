/**
 * Utilidades compartidas para modales
 * @module components/modals/utils
 */

/**
 * Formatea una fecha en formato localizado argentino
 * @param {Date|string} fecha - Fecha a formatear
 * @returns {string} Fecha formateada como "DD/MM/YYYY HH:MM"
 * @example
 * formatFecha(new Date()) // "19/01/2026 15:30"
 * formatFecha("2026-01-19T15:30:00") // "19/01/2026 15:30"
 */
export const formatFecha = (fecha) => new Date(fecha).toLocaleString('es-AR', {
  day: '2-digit',
  month: '2-digit',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit'
});

/**
 * Valida un número de teléfono
 * Acepta formatos con espacios, guiones y paréntesis
 * @param {string} telefono - Teléfono a validar
 * @returns {boolean} true si es válido o está vacío (opcional), false si es inválido
 * @example
 * validarTelefono("+54 11 1234-5678") // true
 * validarTelefono("123") // false (muy corto)
 * validarTelefono("") // true (es opcional)
 */
export const validarTelefono = (telefono) => {
  if (!telefono) return true; // Opcional
  const telefonoLimpio = telefono.replace(/[\s\-\(\)]/g, '');
  return /^[0-9+]{6,15}$/.test(telefonoLimpio);
};

/**
 * Valida un texto con longitud mínima y máxima
 * @param {string} texto - Texto a validar
 * @param {number} [minLength=2] - Longitud mínima requerida
 * @param {number} [maxLength=100] - Longitud máxima permitida
 * @returns {boolean} true si el texto cumple con los requisitos
 * @example
 * validarTexto("Juan Pérez") // true
 * validarTexto("A") // false (muy corto)
 * validarTexto("", 0) // true (minLength=0)
 */
export const validarTexto = (texto, minLength = 2, maxLength = 100) => {
  if (!texto) return false;
  const limpio = texto.trim();
  return limpio.length >= minLength && limpio.length <= maxLength;
};

/**
 * Valida un email con formato básico
 * @param {string} email - Email a validar
 * @returns {boolean} true si el formato es válido o está vacío
 * @example
 * validarEmail("user@example.com") // true
 * validarEmail("invalid") // false
 */
export const validarEmail = (email) => {
  if (!email) return true; // Opcional
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
};

/**
 * Valida un CUIT argentino (formato XX-XXXXXXXX-X)
 * @param {string} cuit - CUIT a validar
 * @returns {boolean} true si el formato es válido o está vacío
 * @example
 * validarCuit("20-12345678-9") // true
 * validarCuit("20123456789") // true (sin guiones)
 */
export const validarCuit = (cuit) => {
  if (!cuit) return true; // Opcional
  const cuitLimpio = cuit.replace(/-/g, '');
  return /^[0-9]{11}$/.test(cuitLimpio);
};

/**
 * Sanitiza un texto removiendo caracteres peligrosos
 * @param {string} texto - Texto a sanitizar
 * @returns {string} Texto sanitizado
 */
export const sanitizarTexto = (texto) => {
  if (!texto) return '';
  return texto.trim().replace(/[<>]/g, '');
};
