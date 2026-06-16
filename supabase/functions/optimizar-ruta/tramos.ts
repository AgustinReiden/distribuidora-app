// Lógica pura de partición y unión de tramos para la optimización de rutas.
//
// Google Routes API computeRoutes admite máximo 25 waypoints intermedios por
// request. Para rutas de 50+ pedidos se parte por barrido angular alrededor
// del depósito (sweep clásico de VRP) y se encadenan los tramos con paradas
// "puente": la última parada de un tramo es el destino de su request y el
// origen del request siguiente. Recorrido resultante:
//   depósito → tramo 1 → puente → tramo 2 → … → depósito
//
// Separado de index.ts para poder testearlo sin red (tests/optimizar_ruta.test.ts).

export interface PedidoRuta {
  pedido_id: string;
  cliente_id?: string;
  cliente_nombre?: string;
  nombre_fantasia?: string;
  direccion?: string;
  latitud: number;
  longitud: number;
}

export interface LatLng {
  latitude: number;
  longitude: number;
}

export interface Tramo {
  origen: LatLng;
  destino: LatLng;
  /** Paradas que van como `intermediates` del request (Google las reordena). */
  intermedios: PedidoRuta[];
  /** Parada visitada como destino del tramo (null en el último: vuelve al depósito). */
  puente: PedidoRuta | null;
}

export interface GoogleRoute {
  distanceMeters?: number;
  duration?: string;
  optimizedIntermediateWaypointIndex?: number[];
  legs?: Array<{ distanceMeters?: number; duration?: string }>;
  /** Geometría de la ruta sobre las calles (encoded polyline, precisión 5). */
  polyline?: { encodedPolyline?: string };
}

export interface OrdenOptimizadoItem {
  pedido_id: string;
  orden: number;
  cliente: string;
  direccion: string;
  distancia_metros?: number;
  distancia_km?: number;
  duracion_minutos?: number;
  sin_coordenadas?: boolean;
}

export interface RutaUnida {
  ordenOptimizado: OrdenOptimizadoItem[];
  distanciaTotalMetros: number;
  duracionTotalSegundos: number;
  /** Encoded polylines, una por tramo en orden (la ruta real sobre calles). */
  polylines: string[];
}

/** Máximo de intermedios por request (25 de Google, con margen). */
export const MAX_INTERMEDIOS = 23;

const toLatLng = (p: PedidoRuta): LatLng => ({ latitude: p.latitud, longitude: p.longitud });

/**
 * Parte los pedidos en tramos encadenados de ≤ MAX_INTERMEDIOS intermedios.
 * Arranca en el depósito y termina en `destino` (punto de llegada configurable;
 * por defecto = depósito, idéntico al comportamiento histórico). El barrido
 * angular sigue siendo alrededor del depósito (origen).
 */
export function partirEnTramos(
  deposito: LatLng,
  pedidos: PedidoRuta[],
  destino: LatLng = deposito,
): Tramo[] {
  if (pedidos.length === 0) return [];

  // Barrido angular: ordenar por ángulo respecto del depósito y partir en
  // bloques contiguos de tamaño parejo. Dentro de cada bloque optimiza Google.
  const ordenadas = [...pedidos].sort((a, b) => {
    const angA = Math.atan2(a.latitud - deposito.latitude, a.longitud - deposito.longitude);
    const angB = Math.atan2(b.latitud - deposito.latitude, b.longitud - deposito.longitude);
    return angA - angB;
  });

  const numTramos = Math.ceil(ordenadas.length / MAX_INTERMEDIOS);
  const tamano = Math.ceil(ordenadas.length / numTramos);
  const bloques: PedidoRuta[][] = [];
  for (let i = 0; i < ordenadas.length; i += tamano) {
    bloques.push(ordenadas.slice(i, i + tamano));
  }

  return bloques.map((bloque, i) => {
    const esUltimo = i === bloques.length - 1;
    const puente = esUltimo ? null : bloque[bloque.length - 1];
    const intermedios = esUltimo ? bloque : bloque.slice(0, -1);
    const puenteAnterior = i > 0 ? bloques[i - 1][bloques[i - 1].length - 1] : null;
    return {
      origen: puenteAnterior ? toLatLng(puenteAnterior) : deposito,
      // El último tramo termina en el punto de llegada (destino), no en el depósito.
      destino: puente ? toLatLng(puente) : destino,
      intermedios,
      puente,
    };
  });
}

const parseDuracion = (s: string | undefined): number =>
  parseInt(String(s ?? "0s").replace("s", "")) || 0;

/**
 * Une las respuestas de Google de cada tramo en una sola ruta global con
 * orden incremental y totales de distancia/duración (incluye la vuelta al
 * depósito del último tramo).
 */
export function unirTramos(tramos: Tramo[], rutas: GoogleRoute[]): RutaUnida {
  const ordenOptimizado: OrdenOptimizadoItem[] = [];
  const polylines: string[] = [];
  let distanciaTotalMetros = 0;
  let duracionTotalSegundos = 0;

  tramos.forEach((tramo, i) => {
    const ruta = rutas[i] ?? {};
    const legs = ruta.legs ?? [];
    const optimizedOrder = ruta.optimizedIntermediateWaypointIndex ?? [];

    const encoded = ruta.polyline?.encodedPolyline;
    if (encoded) polylines.push(encoded);

    // Orden de visita del tramo: intermedios (reordenados por Google si hubo
    // optimización) y el puente al final si existe.
    const visitados = optimizedOrder.length > 0
      ? optimizedOrder.map((idx) => tramo.intermedios[idx]).filter(Boolean)
      : [...tramo.intermedios];
    if (tramo.puente) visitados.push(tramo.puente);

    visitados.forEach((pedido, j) => {
      const leg = legs[j] ?? {};
      const distanciaMetros = leg.distanceMeters ?? 0;
      const duracionSegundos = parseDuracion(leg.duration);
      distanciaTotalMetros += distanciaMetros;
      duracionTotalSegundos += duracionSegundos;
      ordenOptimizado.push({
        pedido_id: pedido.pedido_id,
        orden: ordenOptimizado.length + 1,
        cliente: pedido.cliente_nombre ?? pedido.nombre_fantasia ?? "Sin nombre",
        direccion: pedido.direccion ?? "",
        distancia_metros: distanciaMetros,
        distancia_km: Math.round(distanciaMetros / 10) / 100,
        duracion_minutos: Math.round(duracionSegundos / 60),
      });
    });

    // Último tramo: el leg final va al punto de llegada (destino o depósito) y
    // no corresponde a ninguna parada. Se suma solo a los totales.
    if (!tramo.puente && legs.length > visitados.length) {
      const lastLeg = legs[legs.length - 1];
      distanciaTotalMetros += lastLeg.distanceMeters ?? 0;
      duracionTotalSegundos += parseDuracion(lastLeg.duration);
    }
  });

  return { ordenOptimizado, distanciaTotalMetros, duracionTotalSegundos, polylines };
}
