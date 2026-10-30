/**
 * Compara lo que devuelve `auditoria_fechas_utc()` (migs 410 y la de #1298)
 * contra la lista de `scripts/fechas-utc-permitidas.json`. Pura, para poder
 * testearla sin base: la usa `scripts/check-fechas-utc.mjs`.
 *
 * Cada sección se compara por su clave. Las funciones van por FIRMA (#1298): por
 * nombre, una sobrecarga nueva de una función permitida pasaba sin que nadie la
 * viera. El precio es que cambiarle los parámetros a una de la lista obliga a
 * actualizar la lista en el mismo PR. Los defaults van por `tabla.columna`, y las
 * vistas, policies y CHECKs por su nombre (`tabla.policy`, `tabla.constraint`).
 *
 * Por sección devuelve dos listas. Las "nuevas" usan el día UTC y no están
 * permitidas; las "sobrantes" están permitidas y ya no lo usan, y hay que
 * sacarlas de la lista para que no vuelvan a entrar sin que nadie lo note.
 * Cualquiera no vacía pone el gate en rojo.
 */
export const SECCIONES = [
  { seccion: 'funciones', clave: 'firma' },
  { seccion: 'defaults', clave: 'columna' },
  { seccion: 'vistas', clave: 'nombre' },
  { seccion: 'policies', clave: 'nombre' },
  { seccion: 'checks', clave: 'nombre' },
];

export function evaluarFechasUtc(auditoria, permitidas) {
  const r = {};
  for (const { seccion, clave } of SECCIONES) {
    const hallados = auditoria?.[seccion] ?? [];
    const ok = permitidas?.[seccion] ?? {};
    const claves = new Set(hallados.map((h) => h[clave]));
    r[seccion] = {
      nuevas: hallados.filter((h) => !Object.hasOwn(ok, h[clave])),
      sobrantes: Object.keys(ok).filter((k) => !claves.has(k)).sort(),
    };
  }
  return r;
}

export function hayFallas(r) {
  return SECCIONES.some(({ seccion }) => r[seccion].nuevas.length + r[seccion].sobrantes.length > 0);
}

/**
 * Las secciones que el RPC no devuelve. Si falta alguna, la base no tiene la
 * migración de #1298 y el gate no puede decir nada de esa parte.
 */
export function seccionesFaltantes(auditoria) {
  return SECCIONES.map((s) => s.seccion).filter((s) => !Array.isArray(auditoria?.[s]));
}
