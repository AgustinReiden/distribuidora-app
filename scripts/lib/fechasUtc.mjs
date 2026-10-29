/**
 * Compara lo que devuelve `auditoria_fechas_utc()` (mig 410, #1250) contra la
 * lista de `scripts/fechas-utc-permitidas.json`. Pura, para poder testearla sin
 * base: la usa `scripts/check-fechas-utc.mjs`.
 *
 * Las funciones se comparan por NOMBRE, no por firma: cambiarle los parámetros
 * a una función de la lista no la convierte en nueva.
 *
 * Devuelve cuatro listas. Las "nuevas" usan el día UTC y no están permitidas;
 * las "sobrantes" están permitidas y ya no lo usan, y hay que sacarlas de la
 * lista para que no vuelvan a entrar sin que nadie lo note. Cualquiera de las
 * cuatro no vacía pone el gate en rojo.
 */
export function evaluarFechasUtc(auditoria, permitidas) {
  const funciones = auditoria?.funciones ?? [];
  const defaults = auditoria?.defaults ?? [];
  const okFunciones = permitidas?.funciones ?? {};
  const okDefaults = permitidas?.defaults ?? {};

  const nombres = new Set(funciones.map((f) => f.nombre));
  const columnas = new Set(defaults.map((d) => d.columna));

  return {
    funcionesNuevas: funciones.filter((f) => !Object.hasOwn(okFunciones, f.nombre)),
    funcionesSobrantes: Object.keys(okFunciones).filter((n) => !nombres.has(n)).sort(),
    defaultsNuevos: defaults.filter((d) => !Object.hasOwn(okDefaults, d.columna)),
    defaultsSobrantes: Object.keys(okDefaults).filter((c) => !columnas.has(c)).sort(),
  };
}

export function hayFallas(r) {
  return (
    r.funcionesNuevas.length +
      r.funcionesSobrantes.length +
      r.defaultsNuevos.length +
      r.defaultsSobrantes.length >
    0
  );
}
