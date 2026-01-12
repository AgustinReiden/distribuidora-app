/**
 * Base compartida para todos los hooks de Supabase
 */
import { supabase } from '../../lib/supabase'

// Sistema de notificación de errores centralizado
let errorNotifier = null

export const setErrorNotifier = (notifier) => {
  errorNotifier = notifier
}

export const notifyError = (message) => {
  if (errorNotifier) {
    errorNotifier(message)
  }
}

export { supabase }
