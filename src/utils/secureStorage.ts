/**
 * Secure Storage - Wrapper para localStorage con cifrado AES-GCM
 *
 * Usa Web Crypto API (AES-GCM) exclusivamente para cifrado.
 * Mantiene compatibilidad de LECTURA con datos legacy (XOR) para migración,
 * pero NO escribe nuevos datos con XOR (inseguro).
 *
 * SECURITY: Si Web Crypto API no está disponible, los datos sensibles
 * NO se almacenan. Esto es intencional para evitar almacenamiento inseguro.
 */

import { logger } from './logger'

const STORAGE_PREFIX = 'distribuidora_secure_'
const KEY_STORAGE_NAME = 'distribuidora_crypto_key'

// Clave legacy SOLO para lectura de datos existentes (migración)
// NO usar para escribir nuevos datos
const LEGACY_ENCODING_KEY = 'D1str1bu1d0r4_2024_S3cur3'

// Detectar si Web Crypto API está disponible
const cryptoAvailable = typeof window !== 'undefined' &&
  window.crypto &&
  window.crypto.subtle &&
  typeof window.crypto.subtle.encrypt === 'function'

/**
 * Genera o recupera la clave de cifrado única del dispositivo
 */
async function getCryptoKey(): Promise<CryptoKey | null> {
  if (!cryptoAvailable) return null

  try {
    // Intentar recuperar clave existente
    const storedKey = localStorage.getItem(KEY_STORAGE_NAME)

    if (storedKey) {
      const keyData = JSON.parse(storedKey) as globalThis.JsonWebKey
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
    logger.warn('Error inicializando crypto key:', e)
    return null
  }
}

// Cache de la clave para evitar regenerarla
let cachedKey: CryptoKey | null = null
async function getKey(): Promise<CryptoKey | null> {
  if (cachedKey) return cachedKey
  cachedKey = await getCryptoKey()
  return cachedKey
}

/**
 * Cifra datos usando AES-GCM
 */
async function encryptAES(plaintext: string): Promise<string | null> {
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
    logger.warn('Error cifrando:', e)
    return null
  }
}

/**
 * Descifra datos usando AES-GCM
 */
async function decryptAES(ciphertext: string): Promise<string | null> {
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
  } catch {
    // Fallo silencioso - puede ser datos legacy
    return null
  }
}

/**
 * @deprecated NO USAR - XOR encoding es criptográficamente débil.
 * Esta función solo existe para migración de datos legacy.
 * Nuevos datos deben usar AES-GCM exclusivamente.
 */
function _encodeLegacy_DEPRECATED(str: string): string {
  if (!str) return ''

  try {
    let encoded = ''
    for (let i = 0; i < str.length; i++) {
      const charCode = str.charCodeAt(i) ^ LEGACY_ENCODING_KEY.charCodeAt(i % LEGACY_ENCODING_KEY.length)
      encoded += String.fromCharCode(charCode)
    }
    return btoa(unescape(encodeURIComponent(encoded)))
  } catch {
    return ''
  }
}

// Mantener referencia para que TypeScript no marque como unused
// pero prevenir uso accidental
void _encodeLegacy_DEPRECATED

/**
 * Decodifica un string codificado con XOR (método legacy).
 * SOLO para lectura de datos existentes y migración a AES-GCM.
 *
 * @internal Solo usar para migración de datos legacy
 */
function decodeLegacy(encodedStr: string): string {
  if (!encodedStr) return ''

  try {
    const decoded = decodeURIComponent(escape(atob(encodedStr)))

    let original = ''
    for (let i = 0; i < decoded.length; i++) {
      const charCode = decoded.charCodeAt(i) ^ LEGACY_ENCODING_KEY.charCodeAt(i % LEGACY_ENCODING_KEY.length)
      original += String.fromCharCode(charCode)
    }
    return original
  } catch {
    return ''
  }
}

/**
 * Guarda un valor en localStorage de forma segura usando AES-GCM.
 *
 * SECURITY: Si Web Crypto API no está disponible, NO almacena datos.
 * Esto previene almacenamiento inseguro de datos sensibles.
 *
 * @returns true si se guardó exitosamente, false si no hay crypto disponible
 */
export async function setSecureItem<T>(key: string, value: T): Promise<boolean> {
  try {
    // SECURITY: Solo permitir cifrado AES-GCM, NO XOR fallback
    if (!cryptoAvailable) {
      logger.warn(
        '[secureStorage] Web Crypto API no disponible. ' +
        'Datos sensibles NO almacenados para prevenir almacenamiento inseguro.'
      )
      return false
    }

    const jsonStr = JSON.stringify(value)
    const encrypted = await encryptAES(jsonStr)

    if (encrypted) {
      // Prefijo 'v2:' para identificar datos cifrados con AES
      localStorage.setItem(STORAGE_PREFIX + key, 'v2:' + encrypted)
      return true
    }

    logger.warn('[secureStorage] Falló el cifrado AES, datos no almacenados')
    return false
  } catch (e) {
    logger.error('[secureStorage] Error guardando datos seguros:', e)
    return false
  }
}

/**
 * Obtiene un valor de localStorage de forma segura.
 * Soporta lectura de datos legacy (XOR) y los migra automáticamente a AES-GCM.
 */
export async function getSecureItem<T>(key: string, defaultValue: T): Promise<T> {
  try {
    const stored = localStorage.getItem(STORAGE_PREFIX + key)
    if (!stored) return defaultValue

    let decrypted: string | null = null

    // Detectar formato de cifrado
    if (stored.startsWith('v2:')) {
      // Formato AES-GCM (v2) - preferido
      decrypted = await decryptAES(stored.slice(3))
    }

    // Si no se pudo descifrar con AES, intentar legacy (solo para migración)
    if (!decrypted) {
      const legacyData = stored.startsWith('v2:') ? null : stored
      if (legacyData) {
        decrypted = decodeLegacy(legacyData)

        // Migrar datos legacy a formato nuevo si es posible
        if (decrypted && cryptoAvailable) {
          logger.info(
            `[secureStorage] Migrando datos legacy "${key}" a AES-GCM. ` +
            'Los datos XOR serán reemplazados con cifrado seguro.'
          )
          const parsed = JSON.parse(decrypted) as T
          await setSecureItem(key, parsed) // Re-guardar con AES
        } else if (decrypted && !cryptoAvailable) {
          logger.warn(
            `[secureStorage] Datos legacy encontrados para "${key}" pero ` +
            'Web Crypto API no disponible para migración.'
          )
        }
      }
    }

    if (!decrypted) return defaultValue

    return JSON.parse(decrypted) as T
  } catch {
    return defaultValue
  }
}

/**
 * Elimina un valor de localStorage seguro
 */
export function removeSecureItem(key: string): void {
  try {
    localStorage.removeItem(STORAGE_PREFIX + key)
  } catch {
    // Error silenciado
  }
}

/**
 * Verifica si existe un valor en localStorage seguro
 */
export function hasSecureItem(key: string): boolean {
  return localStorage.getItem(STORAGE_PREFIX + key) !== null
}

/**
 * Limpia todos los items seguros de localStorage
 */
export function clearSecureStorage(): void {
  try {
    const keys = Object.keys(localStorage)
    keys.forEach(key => {
      if (key.startsWith(STORAGE_PREFIX)) {
        localStorage.removeItem(key)
      }
    })
  } catch {
    // Error silenciado
  }
}

/**
 * Migra datos existentes de localStorage normal a secureStorage
 */
export async function migrateToSecure<T>(oldKey: string, newKey: string): Promise<boolean> {
  try {
    const oldData = localStorage.getItem(oldKey)
    if (oldData) {
      const parsed = JSON.parse(oldData) as T
      await setSecureItem(newKey, parsed)
      localStorage.removeItem(oldKey)
      return true
    }
    return false
  } catch {
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
