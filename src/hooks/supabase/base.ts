/**
 * Base compartida para todos los hooks de Supabase
 * Proporciona cliente Supabase y sistema de notificación de errores
 * @module hooks/supabase/base
 */
import { supabase } from '../../lib/supabase'

/**
 * Function type for error notification
 */
export type ErrorNotifier = (message: string) => void

/**
 * Función de notificación de errores (se configura desde App.jsx)
 * @private
 */
let errorNotifier: ErrorNotifier | null = null

/**
 * Configura el notificador de errores global
 * Típicamente se llama desde App.jsx con toast.error
 *
 * @param notifier - Función que maneja la notificación de errores
 * @example
 * // En App.jsx
 * import { setErrorNotifier } from './hooks/supabase/base'
 * import toast from 'react-hot-toast'
 *
 * useEffect(() => {
 *   setErrorNotifier((msg) => toast.error(msg))
 * }, [])
 */
export const setErrorNotifier = (notifier: ErrorNotifier): void => {
  errorNotifier = notifier
}

/**
 * Notifica un error al usuario usando el notificador configurado
 * Si no hay notificador configurado, el error se ignora silenciosamente
 *
 * @param message - Mensaje de error a mostrar al usuario
 * @example
 * try {
 *   await supabase.from('table').select()
 * } catch (error) {
 *   notifyError('Error al cargar datos: ' + error.message)
 * }
 */
export const notifyError = (message: string): void => {
  if (errorNotifier) {
    errorNotifier(message)
  }
}

/**
 * Cliente de Supabase pre-configurado
 * @see {@link https://supabase.com/docs/reference/javascript}
 */
export { supabase }
