/**
 * Qué se le dice al usuario cuando una consulta falla (1563-b6).
 *
 * `QueryCache.onError` decía "Verificá tu conexión" para TODO: también para un permiso
 * denegado (42501) o un embed roto (PGRST201), donde la conexión estaba bien y el usuario
 * perdía el tiempo mirando la señal. Las cuatro cosas que se distinguen:
 *
 *  - sin conexión: no hubo servidor (o no se pudo hablar con él);
 *  - sin permiso: el servidor contestó que no (RLS, `42501`, 401/403);
 *  - sesión vencida: el JWT ya no vale (`PGRST301`/`PGRST303`);
 *  - error del servidor: lo demás (una consulta rota, la base caída, un bug).
 *
 * Nunca se muestra el código ni el texto crudo del server: eso va al log, no a la pantalla.
 */
import { esErrorDeJwt } from './errorDeSupabase'
import { esFalloDeRed, esGatewayCaido } from './falloDeRed'
import { getErrorMessage } from './errorHandling'

export type CausaDeConsultaFallida = 'sin_conexion' | 'sin_permiso' | 'sesion_vencida' | 'error_del_servidor'

export const MENSAJES_DE_CONSULTA_FALLIDA: Record<CausaDeConsultaFallida, string> = {
  sin_conexion: 'No se pudo cargar la información. Verificá tu conexión.',
  sin_permiso: 'No tenés permiso para ver esta información. Si creés que es un error, avisale al administrador.',
  sesion_vencida: 'Tu sesión venció. Cerrá sesión y volvé a entrar para seguir.',
  error_del_servidor: 'No se pudo cargar la información por un problema del servidor. Probá de nuevo en unos minutos.',
}

function statusDe(error: unknown): number | undefined {
  const e = error as { status?: unknown; context?: { status?: unknown } } | null | undefined
  const status = e?.status ?? e?.context?.status
  return typeof status === 'number' ? status : undefined
}

export function causaDeConsultaFallida(error: unknown): CausaDeConsultaFallida {
  // Sin señal del dispositivo, lo que sea que haya fallado es la conexión.
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return 'sin_conexion'

  const code = (error as { code?: unknown } | null | undefined)?.code
  const status = statusDe(error)

  if (esErrorDeJwt(error) || status === 401) return 'sesion_vencida'
  if (code === '42501' || status === 403 || /permission denied|row-level security/i.test(getErrorMessage(error))) {
    return 'sin_permiso'
  }

  // Un gateway caído (HTTP_5xx) es un fallo del servidor, no de la señal del usuario: se
  // descarta antes de preguntar por la red, que lo cuenta como "sin servidor".
  if (esGatewayCaido(error)) return 'error_del_servidor'
  if (typeof code === 'string' && code !== '') return 'error_del_servidor'
  if (esFalloDeRed(error)) return 'sin_conexion'
  return 'error_del_servidor'
}

export function mensajeDeConsultaFallida(error: unknown): string {
  return MENSAJES_DE_CONSULTA_FALLIDA[causaDeConsultaFallida(error)]
}
