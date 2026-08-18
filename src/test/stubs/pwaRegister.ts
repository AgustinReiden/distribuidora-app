/**
 * Stub de `virtual:pwa-register` para los tests.
 *
 * El modulo virtual lo genera `vite-plugin-pwa` durante el build; bajo vitest
 * el id virtual no resuelve y el archivo que lo importe ni siquiera carga. Se
 * mapea con un alias en `test.alias` (vite.config.js).
 *
 * Devuelve una funcion inerte a proposito: los tests que necesitan controlar
 * el registro mockean este modulo con `vi.mock('virtual:pwa-register')`.
 */
export function registerSW(): (recargarPagina?: boolean) => Promise<void> {
  return async () => {}
}

export default registerSW
