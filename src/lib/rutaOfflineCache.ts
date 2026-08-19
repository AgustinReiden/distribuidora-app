/**
 * Cache local de la ruta del día del transportista.
 *
 * POR QUÉ ESTO Y NO UN PERSISTER GLOBAL DE TANSTACK QUERY
 * -------------------------------------------------------
 * La pantalla del chofer dependía 100% de la red: no hay ningún persister
 * configurado, así que el cache vive solo en memoria con `gcTime` de 30 min.
 * Cuando iOS descarta la PWA en segundo plano —cosa que hace— el chofer volvía
 * a abrirla sin señal y se quedaba sin paradas, sin direcciones y sin los
 * totales a cobrar, con el camión cargado.
 *
 * La solución obvia era `persistQueryClient` con una allowlist. Se descartó:
 *
 *  1. `useRecorridoActivoQuery` YA es autosuficiente. Embebe cliente (nombre,
 *     dirección, lat/lng, teléfono, horarios) e items con su producto. Con esa
 *     sola query el chofer tiene la pantalla completa; no hace falta persistir
 *     `pedidos`, `clientes` ni `productos`.
 *  2. Un persister global obliga a mantener una allowlist para no volcar a
 *     localStorage cosas que no deben estar ahí (caja, rendiciones, reportes).
 *     Esa allowlist es una lista negra disfrazada: cada query nueva que alguien
 *     agregue es una fuga potencial hasta que se acuerden de excluirla.
 *  3. Evita dos dependencias nuevas en un repo cuyo gate de CI es
 *     `npm audit --audit-level=high`.
 *
 * Guardar una sola cosa, a propósito y con nombre, es más chico y más fácil de
 * razonar que guardar todo y after acordarse de tapar agujeros.
 *
 * MULTI-TENANT: la clave incluye sucursal y transportista. Un chofer que opera
 * en dos sucursales no puede ver la ruta de la otra por reusar la misma clave.
 */
import { logger } from '../utils/logger';

/** Sube cuando cambia la forma de lo guardado, para descartar lo viejo. */
const ESQUEMA = 'v1';
const PREFIJO = 'ruta-activa';

/** Más viejo que esto no se muestra ni offline: una ruta de anteayer engaña. */
const MAX_EDAD_MS = 36 * 60 * 60 * 1000;

export interface RutaCacheada<T> {
  /** Payload de `useRecorridoActivoQuery` tal cual. */
  datos: T;
  /** Cuándo se guardó (epoch ms). La pantalla lo muestra. */
  guardadoEn: number;
  /** Fecha de la ruta (YYYY-MM-DD), para no revivir la de otro día. */
  fecha: string;
}

function clave(sucursalId: number | null, transportistaId: string): string {
  return `${PREFIJO}:${ESQUEMA}:${sucursalId ?? 'sin-sucursal'}:${transportistaId}`;
}

/**
 * Guarda la ruta. Nunca lanza: que falle el cache no puede romper la pantalla
 * que sí tiene datos frescos en la mano.
 */
export function guardarRuta<T>(
  sucursalId: number | null,
  transportistaId: string,
  fecha: string,
  datos: T,
): void {
  if (!transportistaId) return;
  try {
    const payload: RutaCacheada<T> = { datos, guardadoEn: Date.now(), fecha };
    localStorage.setItem(clave(sucursalId, transportistaId), JSON.stringify(payload));
  } catch (e) {
    // QuotaExceededError es el caso real (una ruta larga con muchos items).
    // Se limpia lo propio y se sigue: el chofer online no se entera.
    logger.warn('[rutaOfflineCache] No se pudo guardar la ruta:', e);
    try {
      localStorage.removeItem(clave(sucursalId, transportistaId));
    } catch { /* nada que hacer */ }
  }
}

/**
 * Lee la ruta guardada. Devuelve `null` si no hay, si está vencida, si es de
 * otra fecha o si el JSON quedó corrupto — en todos esos casos es preferible
 * "no tengo ruta" a mostrar una ruta que no es la de hoy.
 */
export function leerRuta<T>(
  sucursalId: number | null,
  transportistaId: string,
  fechaEsperada: string,
): RutaCacheada<T> | null {
  if (!transportistaId) return null;
  try {
    const crudo = localStorage.getItem(clave(sucursalId, transportistaId));
    if (!crudo) return null;
    const payload = JSON.parse(crudo) as RutaCacheada<T>;
    if (!payload?.datos || typeof payload.guardadoEn !== 'number') return null;
    if (payload.fecha !== fechaEsperada) return null;
    if (Date.now() - payload.guardadoEn > MAX_EDAD_MS) return null;
    return payload;
  } catch (e) {
    logger.warn('[rutaOfflineCache] Cache de ruta ilegible, se descarta:', e);
    return null;
  }
}

/** Borra la ruta guardada de ese chofer (logout, cambio de sucursal). */
export function olvidarRuta(sucursalId: number | null, transportistaId: string): void {
  try {
    localStorage.removeItem(clave(sucursalId, transportistaId));
  } catch { /* nada que hacer */ }
}
