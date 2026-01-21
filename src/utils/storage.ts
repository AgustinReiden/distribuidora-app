/**
 * Utilidades para acceso seguro a localStorage
 * Con manejo de errores y validación de datos
 */

/**
 * Lee un valor de localStorage de forma segura
 */
export function getStorageItem<T>(key: string, defaultValue: T): T {
  try {
    if (typeof window === 'undefined') return defaultValue;

    const item = localStorage.getItem(key);
    if (item === null) return defaultValue;

    return JSON.parse(item) as T;
  } catch {
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
 */
export function setStorageItem<T>(key: string, value: T): boolean {
  try {
    if (typeof window === 'undefined') return false;

    localStorage.setItem(key, JSON.stringify(value));
    return true;
  } catch (error) {
    // Si es error de cuota, intentar liberar espacio
    if (error instanceof Error && error.name === 'QuotaExceededError') {
      try {
        // Limpiar notificaciones antiguas si existen
        const notifications = getStorageItem<unknown[]>('notifications', []);
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
 */
export function removeStorageItem(key: string): boolean {
  try {
    if (typeof window === 'undefined') return false;

    localStorage.removeItem(key);
    return true;
  } catch {
    return false;
  }
}

/**
 * Verifica si localStorage está disponible
 */
export function isStorageAvailable(): boolean {
  try {
    const testKey = '__storage_test__';
    localStorage.setItem(testKey, 'test');
    localStorage.removeItem(testKey);
    return true;
  } catch {
    return false;
  }
}
