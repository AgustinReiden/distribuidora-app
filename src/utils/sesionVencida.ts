/**
 * Diagnóstico del error "No se pudo determinar la sucursal activa".
 *
 * Ese mensaje sale de los RPCs cuando `current_sucursal_id()` devuelve NULL, y
 * confunde: culpa a la sucursal cuando casi siempre el problema es el token.
 *
 * `current_sucursal_id()` (mig 061) resuelve así:
 *   1. lee el header X-Sucursal-ID;
 *   2. si está, verifica contra `usuario_sucursales` USANDO auth.uid();
 *   3. si esa verificación falla → devuelve NULL.
 *
 * El front nunca manda una sucursal ajena: SucursalContext sólo activa una de
 * las que el usuario tiene asignadas. Así que para alguien con su sucursal
 * cargada, el paso 2 sólo falla si `auth.uid()` es NULL — o sea, el JWT no era
 * válido en ese instante (venció, o el servicio de auth se reinició y hubo una
 * ventana sin refresh). El header sigue puesto porque vive en memoria del tab.
 *
 * Se ve como algo intermitente: el mismo preventista carga pedidos bien antes y
 * después, y en el medio uno falla hablando de sucursales.
 */
import { supabase } from '../lib/supabase';

/** El pedido NO se creó: el RPC valida la sucursal antes de escribir nada. */
export const MENSAJE_SESION_RENOVADA =
  'Tu sesión se había vencido y la renovamos. Tocá Confirmar de nuevo — el pedido no se guardó.';

export const MENSAJE_SESION_CAIDA =
  'Tu sesión venció. Cerrá sesión y volvé a entrar para seguir cargando pedidos.';

/**
 * true si el mensaje de error apunta a un problema de sesión disfrazado.
 * Se acepta el de sucursal porque, con el front validando el header, es el
 * síntoma habitual de un token inválido.
 */
export function pareceSesionVencida(mensaje?: string | null): boolean {
  const m = (mensaje ?? '').toLowerCase();
  if (!m) return false;
  return (
    m.includes('no se pudo determinar la sucursal activa') ||
    m.includes('jwt expired') ||
    m.includes('token is expired') ||
    m.includes('invalid claim')
  );
}

/**
 * Traduce el error a algo accionable e intenta renovar la sesión en el acto,
 * para que el reintento del usuario funcione. Si el mensaje no es de sesión lo
 * devuelve tal cual.
 *
 * NO reintenta el pedido solo: la creación online no lleva clave de
 * idempotencia, así que un reintento automático podría duplicarlo.
 */
export async function explicarErrorDeSesion(mensaje: string): Promise<string> {
  if (!pareceSesionVencida(mensaje)) return mensaje;
  try {
    const { data, error } = await supabase.auth.refreshSession();
    return error || !data.session ? MENSAJE_SESION_CAIDA : MENSAJE_SESION_RENOVADA;
  } catch {
    return MENSAJE_SESION_CAIDA;
  }
}
