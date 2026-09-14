/**
 * Utilidades de direcciones.
 */

/**
 * Preserva la altura (número de calle) que tipeó el usuario cuando Google la
 * pierde: con frecuencia geocodifica a nivel calle (sin número) para pasajes y
 * calles poco frecuentes, devolviendo solo el nombre. Inserta el número en la
 * línea de la calle (primer segmento, antes de la primera coma) en vez de
 * reemplazar el `route`, porque Google abrevia el tipo de vía en el
 * `formatted_address` ("Pje. Juan Padros") mientras el route es "Pasaje Juan
 * Padros", y el reemplazo directo nunca matcheaba → la altura se perdía.
 *
 * Idempotente: no agrega el número si la línea de la calle ya lo contiene.
 *
 * Toma el ÚLTIMO número del input, no el primero: una calle puede tener un
 * número en el nombre ("Av. 25 de Mayo 1450", "9 de Julio 300") y la altura
 * que tipeó el usuario siempre va al final.
 *
 * @param direccion    dirección devuelta por Google (formatted_address o description)
 * @param inputOriginal lo que tipeó el usuario (de donde se extrae la altura)
 */
export function preservarAlturaEnDireccion(direccion: string, inputOriginal: string): string {
  const numberMatches = [...inputOriginal.matchAll(/\b(\d{1,5})\b/g)];
  if (numberMatches.length === 0) return direccion;
  const altura = numberMatches[numberMatches.length - 1][1];
  const partes = direccion.split(',');
  if (!partes[0]) return direccion;
  // Si la línea de la calle ya incluye esa altura, no duplicar.
  if (new RegExp(`\\b${altura}\\b`).test(partes[0])) return direccion;
  partes[0] = `${partes[0].trim()} ${altura}`;
  return partes.join(',');
}
