/**
 * Decodificador de Google Encoded Polyline Algorithm Format (precisión 5).
 *
 * Google Routes API devuelve la geometría de la ruta como un string codificado
 * (`encodedPolyline`). Lo decodificamos a [lat, lng][] — el formato que Leaflet
 * <Polyline positions> espera directamente, sin transformación.
 *
 * Sin dependencia npm: el algoritmo son ~25 líneas. Referencia:
 * https://developers.google.com/maps/documentation/utilities/polylinealgorithm
 */

export type LatLngTuple = [number, number];

/**
 * Decodifica un único string encoded a un array de coordenadas [lat, lng].
 * Precisión 5 (factor 1e5), el default de Google `ENCODED_POLYLINE`.
 */
export function decodePolyline(encoded: string): LatLngTuple[] {
  if (!encoded) return [];
  const points: LatLngTuple[] = [];
  let index = 0;
  let lat = 0;
  let lng = 0;
  const len = encoded.length;

  while (index < len) {
    let result = 0;
    let shift = 0;
    let byte: number;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    const dlat = result & 1 ? ~(result >> 1) : result >> 1;
    lat += dlat;

    result = 0;
    shift = 0;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    const dlng = result & 1 ? ~(result >> 1) : result >> 1;
    lng += dlng;

    points.push([lat / 1e5, lng / 1e5]);
  }
  return points;
}

/**
 * Decodifica y concatena varias polylines (una por tramo de la optimización).
 * El último punto de un tramo coincide con el primero del siguiente (parada
 * "puente"); el solapamiento de 1 punto es visualmente nulo.
 */
export function decodePolylines(encoded: string[] | null | undefined): LatLngTuple[] {
  if (!encoded || encoded.length === 0) return [];
  return encoded.flatMap(decodePolyline);
}
