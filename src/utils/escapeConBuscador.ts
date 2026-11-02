/**
 * Radix escucha Escape en captura, antes que el buscador (`ui/Combobox`): con su lista abierta,
 * Escape tiene que cerrar sólo la lista y no el modal que la contiene (ver ModalCompra). Se pasa
 * como `onEscapeKeyDown` del `ModalBase`.
 */
export function noCerrarConBuscadorAbierto(event: KeyboardEvent): void {
  const enfocado = document.activeElement
  const buscadorAbierto = enfocado?.getAttribute('role') === 'combobox' &&
    enfocado.getAttribute('aria-expanded') === 'true'
  if (buscadorAbierto) event.preventDefault()
}
