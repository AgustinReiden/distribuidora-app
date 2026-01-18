/**
 * Secure Storage - Wrapper para localStorage con cifrado AES-GCM
 *
 * Usa Web Crypto API (AES-GCM) cuando está disponible.
 * Mantiene compatibilidad con datos legacy (XOR) para migración automática.
 */

const STORAGE_PREFIX = 'distribuidora_secure_'
const KEY_STORAGE_NAME = 'distribuidora_crypto_key'

// Clave legacy para compatibilidad con datos existentes
const LEGACY_ENCODING_KEY = 'D1str1bu1d0r4_2024_S3cur3'

// Detectar si Web Crypto API está disponible
const cryptoAvailable = typeof window !== 'undefined' &&
  window.crypto &&
  window.crypto.subtle &&
  typeof window.crypto.subtle.encrypt === 'function'

/**
 * Genera o recupera la clave de cifrado única del dispositivo
 * @returns {Promise<CryptoKey|null>}
 */
async function getCryptoKey() {
  if (!cryptoAvailable) return null

  try {
    // Intentar recuperar clave existente
    const storedKey = localStorage.getItem(KEY_STORAGE_NAME)

    if (storedKey) {
      const keyData = JSON.parse(storedKey)
      return await window.crypto.subtle.importKey(
        'jwk',
        keyData,
        { name: 'AES-GCM', length: 256 },
        true,
        ['encrypt', 'decrypt']
      )
    }

    // Generar nueva clave si no existe
    const key = await window.crypto.subtle.generateKey(
      { name: 'AES-GCM', length: 256 },
      true,
      ['encrypt', 'decrypt']
    )

    // Exportar y guardar la clave
    const exportedKey = await window.crypto.subtle.exportKey('jwk', key)
    localStorage.setItem(KEY_STORAGE_NAME, JSON.stringify(exportedKey))

    return key
  } catch (e) {
    console.warn('Error inicializando crypto key:', e)
    return null
  }
}

// Cache de la clave para evitar regenerarla
let cachedKey = null
async function getKey() {
  if (cachedKey) return cachedKey
  cachedKey = await getCryptoKey()
  return cachedKey
}

/**
 * Cifra datos usando AES-GCM
 * @param {string} plaintext - Texto a cifrar
 * @returns {Promise<string>} - Datos cifrados en base64
 */
async function encryptAES(plaintext) {
  const key = await getKey()
  if (!key) return null

  try {
    const iv = window.crypto.getRandomValues(new Uint8Array(12))
    const encodedText = new TextEncoder().encode(plaintext)

    const ciphertext = await window.crypto.subtle.encrypt(
      { name: 'AES-GCM', iv },
      key,
      encodedText
    )

    // Combinar IV + ciphertext y convertir a base64
    const combined = new Uint8Array(iv.length + ciphertext.byteLength)
    combined.set(iv)
    combined.set(new Uint8Array(ciphertext), iv.length)

    return btoa(String.fromCharCode(...combined))
  } catch (e) {
    console.warn('Error cifrando:', e)
    return null
  }
}

/**
 * Descifra datos usando AES-GCM
 * @param {string} ciphertext - Texto cifrado en base64
 * @returns {Promise<string|null>} - Texto descifrado o null si falla
 */
async function decryptAES(ciphertext) {
  const key = await getKey()
  if (!key) return null

  try {
    const combined = Uint8Array.from(atob(ciphertext), c => c.charCodeAt(0))

    // Extraer IV (primeros 12 bytes) y ciphertext
    const iv = combined.slice(0, 12)
    const data = combined.slice(12)

    const decrypted = await window.crypto.subtle.decrypt(
      { name: 'AES-GCM', iv },
      key,
      data
    )

    return new TextDecoder().decode(decrypted)
  } catch (e) {
    // Fallo silencioso - puede ser datos legacy
    return null
  }
}

/**
 * Codifica un string usando XOR (método legacy para compatibilidad)
 * @param {string} str - String a codificar
 * @returns {string} - String codificado en base64
 */
function encodeLegacy(str) {
  if (!str) return ''

  try {
    let encoded = ''
    for (let i = 0; i < str.length; i++) {
      const charCode = str.charCodeAt(i) ^ LEGACY_ENCODING_KEY.charCodeAt(i % LEGACY_ENCODING_KEY.length)
      encoded += String.fromCharCode(charCode)
    }
    return btoa(unescape(encodeURIComponent(encoded)))
  } catch (e) {
    return ''
  }
}

/**
 * Decodifica un string codificado con XOR (método legacy)
 * @param {string} encodedStr - String codificado en base64
 * @returns {string} - String original
 */
function decodeLegacy(encodedStr) {
  if (!encodedStr) return ''

  try {
    const decoded = decodeURIComponent(escape(atob(encodedStr)))

    let original = ''
    for (let i = 0; i < decoded.length; i++) {
      const charCode = decoded.charCodeAt(i) ^ LEGACY_ENCODING_KEY.charCodeAt(i % LEGACY_ENCODING_KEY.length)
      original += String.fromCharCode(charCode)
    }
    return original
  } catch (e) {
    return ''
  }
}

/**
 * Guarda un valor en localStorage de forma segura
 * @param {string} key - Clave de almacenamiento
 * @param {any} value - Valor a guardar (sera serializado a JSON)
 * @returns {Promise<boolean>} - true si se guardo correctamente
 */
export async function setSecureItem(key, value) {
  try {
    const jsonStr = JSON.stringify(value)

    // Intentar cifrado AES primero
    if (cryptoAvailable) {
      const encrypted = await encryptAES(jsonStr)
      if (encrypted) {
        // Prefijo 'v2:' para identificar datos cifrados con AES
        localStorage.setItem(STORAGE_PREFIX + key, 'v2:' + encrypted)
        return true
      }
    }

    // Fallback a método legacy
    const encoded = encodeLegacy(jsonStr)
    localStorage.setItem(STORAGE_PREFIX + key, encoded)
    return true
  } catch (e) {
    return false
  }
}

/**
 * Obtiene un valor de localStorage de forma segura
 * @param {string} key - Clave de almacenamiento
 * @param {any} defaultValue - Valor por defecto si no existe
 * @returns {Promise<any>} - Valor deserializado o defaultValue
 */
export async function getSecureItem(key, defaultValue = null) {
  try {
    const stored = localStorage.getItem(STORAGE_PREFIX + key)
    if (!stored) return defaultValue

    let decrypted = null

    // Detectar formato de cifrado
    if (stored.startsWith('v2:')) {
      // Formato AES-GCM (v2)
      decrypted = await decryptAES(stored.slice(3))
    }

    // Si no se pudo descifrar con AES, intentar legacy
    if (!decrypted) {
      const legacyData = stored.startsWith('v2:') ? null : stored
      if (legacyData) {
        decrypted = decodeLegacy(legacyData)

        // Migrar datos legacy a formato nuevo si es posible
        if (decrypted && cryptoAvailable) {
          const parsed = JSON.parse(decrypted)
          await setSecureItem(key, parsed) // Re-guardar con AES
        }
      }
    }

    if (!decrypted) return defaultValue

    return JSON.parse(decrypted)
  } catch (e) {
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
    // Error silenciado
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
    // Error silenciado
  }
}

/**
 * Migra datos existentes de localStorage normal a secureStorage
 * @param {string} oldKey - Clave original en localStorage
 * @param {string} newKey - Nueva clave para secureStorage
 * @returns {Promise<boolean>} - true si se migro correctamente
 */
export async function migrateToSecure(oldKey, newKey) {
  try {
    const oldData = localStorage.getItem(oldKey)
    if (oldData) {
      const parsed = JSON.parse(oldData)
      await setSecureItem(newKey, parsed)
      localStorage.removeItem(oldKey)
      return true
    }
    return false
  } catch (e) {
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
