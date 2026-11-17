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

/** Renovamos la sesión y el mismo error volvió: no era el token (1600-b16). */
export const MENSAJE_SUCURSAL_NO_RESUELTA =
  'No se pudo determinar tu sucursal activa, y renovar la sesión no lo arregló. Cerrá sesión y volvé a entrar; si sigue igual, avisale al administrador: puede que tu usuario ya no tenga esa sucursal asignada o esté desactivado.';

/** El pedido NO se creó y la sesión no se pudo renovar por falta de señal: no es que haya vencido. */
export const MENSAJE_SESION_SIN_CONEXION =
  'No se pudo renovar tu sesión porque no hay conexión. Revisá la señal y tocá Confirmar de nuevo — el pedido no se guardó.';

// Pura y sin supabase: vive aparte para que importarla no cree el cliente
// (rechazoDeNegocio la usa, y lo importan módulos que se testean sin .env).
import { pareceSesionVencida } from './pareceSesionVencida';
import { esFalloDeRed } from './falloDeRed';
export { pareceSesionVencida };

const ES_ERROR_DE_SUCURSAL = /no se pudo determinar la sucursal activa/i;

/**
 * Cuándo se renovó la sesión por este error por última vez. «No se pudo determinar la sucursal
 * activa» sale de `current_sucursal_id()` y casi siempre es el token, pero también sale cuando al
 * usuario ya no le queda esa sucursal o está desactivado: ahí renovar la sesión no cambia nada, y
 * el cartel «la renovamos, tocá Confirmar de nuevo» se repetía sin fin (1600-b16).
 */
let renovadaPorSucursalEn: number | null = null;
const VENTANA_DE_RENOVACION_MS = 10 * 60 * 1000;

/** Para los tests: el módulo guarda la última renovación. */
export function olvidarRenovacionDeSesion(): void {
  renovadaPorSucursalEn = null;
}


/**
 * Traduce el error a algo accionable e intenta renovar la sesión en el acto,
 * para que el reintento del usuario funcione. Si el mensaje no es de sesión lo
 * devuelve tal cual.
 *
 * NO reintenta el pedido sola: el alta online sí lleva clave de idempotencia
 * (`altaIdRef` en PedidosContainer, igual que el replay offline) así que un
 * reintento automático no lo duplicaría, pero dispararía la escritura sin que
 * la usuaria haya vuelto a tocar Confirmar sobre lo que tiene en pantalla —
 * eso queda en sus manos.
 */
export async function explicarErrorDeSesion(mensaje: string): Promise<string> {
  if (!pareceSesionVencida(mensaje)) return mensaje;
  const porSucursal = ES_ERROR_DE_SUCURSAL.test(mensaje);

  // Ya se renovó hace un rato por este mismo error y volvió: no es el token.
  if (porSucursal && renovadaPorSucursalEn !== null && Date.now() - renovadaPorSucursalEn < VENTANA_DE_RENOVACION_MS) {
    // No se resetea: la ventana se deja vencer sola. Si se reseteara, el siguiente intento
    // volvería a renovar y el cartel alternaría entre «la renovamos» y «no se resolvió».
    return MENSAJE_SUCURSAL_NO_RESUELTA;
  }

  try {
    const { data, error } = await supabase.auth.refreshSession();
    if (error || !data.session) {
      // Sin señal no se pudo ni preguntar: no es que la sesión haya vencido.
      return esFalloDeRed(error) ? MENSAJE_SESION_SIN_CONEXION : MENSAJE_SESION_CAIDA;
    }
    if (porSucursal) renovadaPorSucursalEn = Date.now();
    return MENSAJE_SESION_RENOVADA;
  } catch (err) {
    return esFalloDeRed(err) ? MENSAJE_SESION_SIN_CONEXION : MENSAJE_SESION_CAIDA;
  }
}

/**
 * Renueva el token en el acto. `true` si quedó una sesión válida.
 *
 * Lo usa el replay offline: al reconectar, el primer pedido de la cola suele
 * pegarle a un JWT vencido y volver con "No se pudo determinar la sucursal
 * activa". Ese reintento no es un fallo de la operación —el RPC valida la
 * sucursal antes de escribir nada, así que el pedido no se creó— y por eso no
 * tiene que gastar uno de los reintentos de la cola.
 *
 * El try/catch cubre al cliente sin `auth` (los tests lo mockean así) y a
 * cualquier excepción del SDK: acá una renovación fallida es "no se pudo", no
 * un error que deba propagarse.
 */
export async function renovarSesion(): Promise<boolean> {
  try {
    const { data, error } = await supabase.auth.refreshSession();
    return !error && Boolean(data?.session);
  } catch {
    return false;
  }
}
