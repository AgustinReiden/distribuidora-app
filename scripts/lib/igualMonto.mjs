/** `numeric` puede venir como number o como string según el tamaño. */
export const num = (v) => (v === null || v === undefined ? null : Number(v));

/**
 * Los montos que la base devuelve son `numeric` exactos (el SQL redondea a 4
 * decimales); el script los recalcula en JS como `double`, que arrastra error de
 * representación (643210.6200000001 vs 643210.62). Se comparan con una tolerancia
 * muy por debajo de la menor diferencia real (0,0001). `null` sólo iguala a `null`.
 */
export const EPSILON_MONTO = 1e-6;

export const igual = (a, b) => {
  const x = num(a);
  const y = num(b);
  if (x === null || y === null) return x === y;
  return Math.abs(x - y) <= EPSILON_MONTO;
};
