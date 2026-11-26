/**
 * Rut-B7 (#1554, decisión del dueño): una ruta no se completa con paradas sin marcar. Cada
 * parada se marca entregada o no entregada, y recién ahí se cierra la ruta. El server lo frena
 * (`recorridos_estado_transicion`); la pantalla del chofer lo dice antes.
 *
 * Devuelve el aviso para el chofer, o null si no queda ninguna parada por marcar.
 */
export function avisoParadasSinMarcar(sinMarcar: number): string | null {
  if (!Number.isFinite(sinMarcar) || sinMarcar <= 0) return null;
  const paradas = sinMarcar === 1 ? 'Te queda 1 parada sin marcar' : `Te quedan ${sinMarcar} paradas sin marcar`;
  return `${paradas}: marcá cada una como entregada o no entregada. La ruta se cierra cuando estén todas marcadas.`;
}
