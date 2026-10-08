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

/**
 * Sube cuando cambia la forma de lo guardado, para descartar lo viejo.
 * v2 (#1003): la ruta ya no trae `costo_unitario_al_crear` en cada ítem. Las v1
 * sí lo traían: `migrarRutasDeEsquemaViejo` las pasa a v2 sin el costo.
 */
const ESQUEMA = 'v2';
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
 * una fecha no aceptada o si el JSON quedó corrupto — en todos esos casos es
 * preferible "no tengo ruta" a mostrar una que no corresponde.
 *
 * `fechasAceptadas` recibe una fecha o una lista: en la madrugada
 * `fechaDeRuta()` acepta hoy Y ayer (la ruta puede seguir en curso cruzando la
 * medianoche), y hay que leer con el mismo criterio con el que se guardó — si
 * no, un `guardarRuta` con `fecha: ayer` nunca calza contra un `leerRuta` que
 * sólo pide `hoy`. `MAX_EDAD_MS` ya cubre no revivir una ruta de anteayer.
 */
export function leerRuta<T>(
  sucursalId: number | null,
  transportistaId: string,
  fechasAceptadas: string | string[],
): RutaCacheada<T> | null {
  if (!transportistaId) return null;
  const fechas = Array.isArray(fechasAceptadas) ? fechasAceptadas : [fechasAceptadas];
  try {
    const crudo = localStorage.getItem(clave(sucursalId, transportistaId));
    if (!crudo) return null;
    const payload = JSON.parse(crudo) as RutaCacheada<T>;
    if (!payload?.datos || typeof payload.guardadoEn !== 'number') return null;
    if (!fechas.includes(payload.fecha)) return null;
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

/**
 * Borra TODAS las rutas cacheadas, de cualquier sucursal o chofer.
 *
 * Para logout en un dispositivo compartido: `olvidarRuta` sólo conoce al
 * chofer que se está yendo, pero puede haber quedado la de otro que ya cerró
 * sesión antes sin pasar por acá (o cuya sucursal en ese momento no se puede
 * reconstruir). Este barrido cubre eso.
 */
export function olvidarTodasLasRutas(): void {
  try {
    const claves: string[] = [];
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      if (key?.startsWith(`${PREFIJO}:`)) {
        claves.push(key);
      }
    }
    claves.forEach(key => localStorage.removeItem(key));
  } catch (e) {
    logger.warn('[rutaOfflineCache] No se pudo barrer las rutas cacheadas:', e);
  }
}

/** Esquema anterior, el único que se migra (el resto se descarta). */
const ESQUEMA_ANTERIOR = 'v1';

/** Saca `costo_unitario_al_crear` de cada ítem de `datos.paradas[*].items[*]`. */
function sinCostoEnItems(datos: Record<string, unknown>): Record<string, unknown> {
  if (!Array.isArray(datos.paradas)) return datos;
  return {
    ...datos,
    paradas: datos.paradas.map(parada => {
      if (!parada || typeof parada !== 'object' || !Array.isArray((parada as { items?: unknown }).items)) return parada;
      return {
        ...(parada as Record<string, unknown>),
        items: (parada as { items: unknown[] }).items.map(item => {
          if (!item || typeof item !== 'object') return item;
          // eslint-disable-next-line @typescript-eslint/no-unused-vars
          const { costo_unitario_al_crear, ...resto } = item as Record<string, unknown>;
          return resto;
        }),
      };
    }),
  };
}

/**
 * Migra las rutas cacheadas de un esquema viejo al actual y borra las viejas.
 *
 * Las v1 traían el costo de cada ítem (#1003), así que no pueden quedar en el
 * teléfono. Pero tampoco se las puede simplemente descartar: el service worker
 * es 'prompt' (sin skipWaiting), y el bundle viejo sigue guardando
 * `ruta-activa:v1:*` hasta que se activa el nuevo. Si el chofer reabre la PWA
 * sin señal, el bundle nuevo busca la v2, no la encuentra y se queda sin la
 * ruta offline —paradas, direcciones, totales a cobrar—, que es justo para lo
 * que existe esta caché. Por eso cada `ruta-activa:v1:<resto>` válida pasa a
 * `ruta-activa:v2:<resto>` sin `costo_unitario_al_crear`, con el mismo
 * `guardadoEn` y `fecha` (no la revive: `MAX_EDAD_MS` sigue contando desde el
 * guardado original). Si ya hay una v2 en esa clave, la v2 manda. Una v1
 * corrupta se borra sin migrar, y cualquier otra versión ajena se borra.
 *
 * Se llama una vez al arrancar la app. Nunca lanza.
 */
export function migrarRutasDeEsquemaViejo(): void {
  try {
    const claves: string[] = [];
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      if (key?.startsWith(`${PREFIJO}:`) && !key.startsWith(`${PREFIJO}:${ESQUEMA}:`)) {
        claves.push(key);
      }
    }
    for (const key of claves) {
      try {
        const prefijoAnterior = `${PREFIJO}:${ESQUEMA_ANTERIOR}:`;
        if (key.startsWith(prefijoAnterior)) {
          const destino = `${PREFIJO}:${ESQUEMA}:${key.slice(prefijoAnterior.length)}`;
          if (localStorage.getItem(destino) === null) {
            const payload = JSON.parse(localStorage.getItem(key) ?? 'null') as Partial<RutaCacheada<unknown>> | null;
            if (
              payload && typeof payload === 'object' &&
              payload.datos && typeof payload.datos === 'object' &&
              typeof payload.guardadoEn === 'number' && typeof payload.fecha === 'string'
            ) {
              const migrada: RutaCacheada<unknown> = {
                datos: sinCostoEnItems(payload.datos as Record<string, unknown>),
                guardadoEn: payload.guardadoEn,
                fecha: payload.fecha,
              };
              localStorage.setItem(destino, JSON.stringify(migrada));
            }
          }
        }
      } catch (e) {
        // Corrupta o sin lugar para la v2: no se migra, pero la v1 igual se va.
        logger.warn('[rutaOfflineCache] No se pudo migrar una ruta de esquema viejo:', e);
      }
      try {
        localStorage.removeItem(key);
      } catch { /* nada que hacer */ }
    }
  } catch (e) {
    logger.warn('[rutaOfflineCache] No se pudo migrar las rutas de esquema viejo:', e);
  }
}
