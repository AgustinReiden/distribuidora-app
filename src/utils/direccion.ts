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
 * @param direccion    dirección devuelta por Google (formatted_address o description)
 * @param inputOriginal lo que tipeó el usuario (de donde se extrae la altura)
 */
export function preservarAlturaEnDireccion(direccion: string, inputOriginal: string): string {
  const numberMatch = inputOriginal.match(/\b(\d{1,5})\b/);
  if (!numberMatch) return direccion;
  const altura = numberMatch[1];
  const partes = direccion.split(',');
  if (!partes[0]) return direccion;
  // Si la línea de la calle ya incluye esa altura, no duplicar.
  if (new RegExp(`\\b${altura}\\b`).test(partes[0])) return direccion;
  partes[0] = `${partes[0].trim()} ${altura}`;
  return partes.join(',');
}
