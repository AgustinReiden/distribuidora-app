/**
 * Lo que decide el gate de clientes inactivos (scripts/check-clientes-activo.mjs, gate 3 de
 * #1520). Puro y sin dependencias: el script corre en CI sin node_modules, y los casos viven en
 * src/test/clientesActivo.test.ts.
 */

/**
 * `auditoria` es la respuesta de auditoria_pedidos_cliente_activo() (mig 480): `sin_activo` son
 * las firmas de las funciones que insertan en pedidos sin nombrar `clientes` y `activo` en una
 * misma sentencia. `permitidas` es el mapa firma → motivo de
 * scripts/clientes-activo-permitidas.json.
 *
 * Devuelve las que faltan (rojo) y las permitidas que ya no hacen falta (aviso).
 */
export function hallazgosClientesActivo(auditoria, permitidas = {}) {
  const sinActivo = new Set(auditoria?.sin_activo ?? []);
  return {
    faltan: [...sinActivo].filter((firma) => !Object.hasOwn(permitidas, firma)).sort(),
    sobrantes: Object.keys(permitidas).filter((firma) => !sinActivo.has(firma)).sort(),
  };
}
