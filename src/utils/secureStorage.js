/**
 * Secure Storage - Wrapper para localStorage con encriptacion basica
 *
 * Usa AES-like encoding para datos sensibles almacenados localmente.
 * NOTA: Esto NO es encriptacion de grado militar, pero previene lectura casual
 * de datos en DevTools. Para datos muy sensibles, usar IndexedDB con Web Crypto API.
 */

// Clave de ofuscacion (en produccion, derivar de algo unico del usuario)
const STORAGE_PREFIX = 'distribuidora_secure_'
const ENCODING_KEY = 'D1str1bu1d0r4_2024_S3cur3'

/**
 * Codifica un string usando XOR con la clave
 * @param {string} str - String a codificar
 * @returns {string} - String codificado en base64
 */
function encode(str) {
  if (!str) return ''

  try {
    let encoded = ''
    for (let i = 0; i < str.length; i++) {
      const charCode = str.charCodeAt(i) ^ ENCODING_KEY.charCodeAt(i % ENCODING_KEY.length)
      encoded += String.fromCharCode(charCode)
    }
    // Convertir a base64 para almacenamiento seguro
    return btoa(unescape(encodeURIComponent(encoded)))
  } catch (e) {
    console.error('[SecureStorage] Error encoding:', e)
    return ''
  }
}

/**
 * Decodifica un string codificado
 * @param {string} encodedStr - String codificado en base64
 * @returns {string} - String original
 */
function decode(encodedStr) {
  if (!encodedStr) return ''

  try {
    // Decodificar base64
    const decoded = decodeURIComponent(escape(atob(encodedStr)))

    let original = ''
    for (let i = 0; i < decoded.length; i++) {
      const charCode = decoded.charCodeAt(i) ^ ENCODING_KEY.charCodeAt(i % ENCODING_KEY.length)
      original += String.fromCharCode(charCode)
    }
    return original
  } catch (e) {
    console.error('[SecureStorage] Error decoding:', e)
    return ''
  }
}

/**
 * Guarda un valor en localStorage de forma segura
 * @param {string} key - Clave de almacenamiento
 * @param {any} value - Valor a guardar (sera serializado a JSON)
 * @returns {boolean} - true si se guardo correctamente
 */
export function setSecureItem(key, value) {
  try {
    const jsonStr = JSON.stringify(value)
    const encoded = encode(jsonStr)
    localStorage.setItem(STORAGE_PREFIX + key, encoded)
    return true
  } catch (e) {
    console.error('[SecureStorage] Error saving:', e)
    return false
  }
}

/**
 * Obtiene un valor de localStorage de forma segura
 * @param {string} key - Clave de almacenamiento
 * @param {any} defaultValue - Valor por defecto si no existe
 * @returns {any} - Valor deserializado o defaultValue
 */
export function getSecureItem(key, defaultValue = null) {
  try {
    const encoded = localStorage.getItem(STORAGE_PREFIX + key)
    if (!encoded) return defaultValue

    const decoded = decode(encoded)
    if (!decoded) return defaultValue

    return JSON.parse(decoded)
  } catch (e) {
    console.error('[SecureStorage] Error reading:', e)
    return defaultValue
  }
}

/**
 * Elimina un valor de localStorage seguro
 * @param {string} key - Clave de almacenamiento
 */
export function removeSecureItem(key) {
  try {
    localStorage.removeItem(STORAGE_PREFIX + key)
  } catch (e) {
    console.error('[SecureStorage] Error removing:', e)
  }
}

/**
 * Verifica si existe un valor en localStorage seguro
 * @param {string} key - Clave de almacenamiento
 * @returns {boolean}
 */
export function hasSecureItem(key) {
  return localStorage.getItem(STORAGE_PREFIX + key) !== null
}

/**
 * Limpia todos los items seguros de localStorage
 */
export function clearSecureStorage() {
  try {
    const keys = Object.keys(localStorage)
    keys.forEach(key => {
      if (key.startsWith(STORAGE_PREFIX)) {
        localStorage.removeItem(key)
      }
    })
  } catch (e) {
    console.error('[SecureStorage] Error clearing:', e)
  }
}

/**
 * Migra datos existentes de localStorage normal a secureStorage
 * @param {string} oldKey - Clave original en localStorage
 * @param {string} newKey - Nueva clave para secureStorage
 * @returns {boolean} - true si se migro correctamente
 */
export function migrateToSecure(oldKey, newKey) {
  try {
    const oldData = localStorage.getItem(oldKey)
    if (oldData) {
      const parsed = JSON.parse(oldData)
      setSecureItem(newKey, parsed)
      localStorage.removeItem(oldKey)
      return true
    }
    return false
  } catch (e) {
    console.error('[SecureStorage] Error migrating:', e)
    return false
  }
}

export default {
  setItem: setSecureItem,
  getItem: getSecureItem,
  removeItem: removeSecureItem,
  hasItem: hasSecureItem,
  clear: clearSecureStorage,
  migrate: migrateToSecure
}
