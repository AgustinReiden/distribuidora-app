/**
 * Si el total que guardó el server para un alta es el que mandó el front, con la tolerancia
 * de un centavo del alta (`crear_pedido_completo` acepta `p_total` a un centavo de la suma
 * de las líneas y, desde 1559-b1, guarda la suma). Se compara en centavos enteros: en coma
 * flotante `Math.abs(99.99 - 100)` da 0.010000000000005116 y un `< 0.01` lo dejaba afuera.
 */
export function mismoTotalDelAlta(guardado: number, enviado: number): boolean {
  return Math.abs(Math.round(guardado * 100) - Math.round(enviado * 100)) <= 1
}
