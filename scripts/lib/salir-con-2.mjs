/**
 * Importarlo al principio de un gate: una excepción sin atrapar (psql caído, un archivo que falta)
 * termina el proceso con exit 2 («no pude mirar»), no con el 1 de «encontré algo». Los controles
 * negativos de scripts/ci/gates-muerden.sh se apoyan en esa diferencia.
 */
process.on('uncaughtException', (e) => {
  console.error(`El gate no pudo correr: ${e?.message ?? e}`);
  process.exit(2);
});
process.on('unhandledRejection', (e) => {
  console.error(`El gate no pudo correr: ${e?.message ?? e}`);
  process.exit(2);
});
