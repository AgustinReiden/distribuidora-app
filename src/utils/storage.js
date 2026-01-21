/* eslint-disable no-unused-vars */
/**
 * Utilidades para acceso seguro a localStorage
 * Con manejo de errores y validación de datos
 */

/**
 * Lee un valor de localStorage de forma segura
 * @param {string} key - Clave a leer
 * @param {*} defaultValue - Valor por defecto si no existe o hay error
 * @returns {*} Valor parseado o defaultValue
 */
export function getStorageItem(key, defaultValue = null) {
  try {
    if (typeof window === 'undefined') return defaultValue;

    const item = localStorage.getItem(key);
    if (item === null) return defaultValue;

    return JSON.parse(item);
  } catch (error) {
    // Intentar limpiar el valor corrupto
    try {
      localStorage.removeItem(key);
    } catch {
      // Ignorar error de limpieza
    }
    return defaultValue;
  }
}

/**
 * Guarda un valor en localStorage de forma segura
 * @param {string} key - Clave a guardar
 * @param {*} value - Valor a guardar (será serializado a JSON)
 * @returns {boolean} true si se guardó correctamente
 */
export function setStorageItem(key, value) {
  try {
    if (typeof window === 'undefined') return false;

    localStorage.setItem(key, JSON.stringify(value));
    return true;
  } catch (error) {
    // Si es error de cuota, intentar liberar espacio
    if (error.name === 'QuotaExceededError') {
      try {
        // Limpiar notificaciones antiguas si existen
        const notifications = getStorageItem('notifications', []);
        if (Array.isArray(notifications) && notifications.length > 10) {
          setStorageItem('notifications', notifications.slice(0, 10));
        }
      } catch {
        // Ignorar
      }
    }
    return false;
  }
}

/**
 * Elimina un valor de localStorage de forma segura
 * @param {string} key - Clave a eliminar
 * @returns {boolean} true si se eliminó correctamente
 */
export function removeStorageItem(key) {
  try {
    if (typeof window === 'undefined') return false;

    localStorage.removeItem(key);
    return true;
  } catch (error) {
    return false;
  }
}

/**
 * Verifica si localStorage está disponible
 * @returns {boolean}
 */
export function isStorageAvailable() {
  try {
    const testKey = '__storage_test__';
    localStorage.setItem(testKey, 'test');
    localStorage.removeItem(testKey);
    return true;
  } catch {
    return false;
  }
}
