/**
 * Tests de CARACTERIZACIÓN de `ModalFiltroFecha` — el modal de rango de fechas
 * de /pedidos (y de cualquier pantalla que lo reuse).
 *
 * El contrato que fijan, que es el que el rediseño no puede romper:
 *
 *  - Es un modal con estado LOCAL: escribir en los inputs no filtra nada.
 *    Recién "Aplicar" devuelve el rango por `onApply` y después cierra.
 *  - "Limpiar" no borra los inputs: emite `{ null, null }` y cierra. La
 *    limpieza visible la produce el desmontaje, no el handler.
 *  - Cerrar sin aplicar no emite nada.
 *
 * Los dos `<input type="date">` no tienen `id`/`htmlFor` ni `aria-label`: los
 * `<label>` "Desde" y "Hasta" son hermanos sueltos, así que no hay nombre
 * accesible con el que pedirlos. Se los toma por su tipo (ver `inputsFecha`) y
 * queda anotado como hallazgo de accesibilidad para el rediseño.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent, { type UserEvent } from '@testing-library/user-event'

import ModalFiltroFecha from './ModalFiltroFecha'

// =============================================================================
// HELPERS
// =============================================================================

function renderModal(filtros: { fechaDesde: string | null; fechaHasta: string | null }) {
  const onApply = vi.fn()
  const onClose = vi.fn()

  render(<ModalFiltroFecha filtros={filtros} onApply={onApply} onClose={onClose} />)

  return { onApply, onClose }
}

/**
 * Los dos inputs de fecha, en orden (Desde, Hasta).
 *
 * El modal vive en un portal de Radix, así que se buscan desde `document`.
 * No hay query por rol ni por label porque el componente no les da ninguno:
 * los `<label>` "Desde" y "Hasta" no están asociados a ningún input.
 */
function inputsFecha(): HTMLInputElement[] {
  return Array.from(document.querySelectorAll<HTMLInputElement>('input[type="date"]'))
}

/** Escribe una fecha completa en un `input[type=date]`. */
async function escribirFecha(user: UserEvent, input: HTMLInputElement, valor: string): Promise<void> {
  await user.clear(input)
  await user.type(input, valor)
}

// =============================================================================
// RENDER
// =============================================================================

describe('ModalFiltroFecha — render', () => {
  it('se abre titulado y con los dos campos del rango', () => {
    renderModal({ fechaDesde: null, fechaHasta: null })

    expect(screen.getByRole('dialog', { name: /filtrar por fecha/i })).toBeInTheDocument()
    expect(screen.getByText('Desde')).toBeInTheDocument()
    expect(screen.getByText('Hasta')).toBeInTheDocument()
    expect(inputsFecha()).toHaveLength(2)
  })

  it('precarga el rango que ya venía filtrado', () => {
    renderModal({ fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' })

    const [desde, hasta] = inputsFecha()
    expect(desde).toHaveValue('2026-04-01')
    expect(hasta).toHaveValue('2026-04-15')
  })

  it('sin rango previo arranca con los dos campos vacíos', () => {
    renderModal({ fechaDesde: null, fechaHasta: null })

    const [desde, hasta] = inputsFecha()
    expect(desde).toHaveValue('')
    expect(hasta).toHaveValue('')
  })

  it('ofrece "Limpiar" y "Aplicar", y ningún otro botón de acción', () => {
    renderModal({ fechaDesde: null, fechaHasta: null })

    expect(screen.getByRole('button', { name: 'Limpiar' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Aplicar' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /guardar|confirmar|cancelar/i })).not.toBeInTheDocument()
  })
})

// =============================================================================
// APLICAR
// =============================================================================

describe('ModalFiltroFecha — "Aplicar"', () => {
  it('devuelve el rango que se escribió y cierra', async () => {
    const user = userEvent.setup()
    const { onApply, onClose } = renderModal({ fechaDesde: null, fechaHasta: null })

    const [desde, hasta] = inputsFecha()
    await escribirFecha(user, desde, '2026-05-01')
    await escribirFecha(user, hasta, '2026-05-31')
    await user.click(screen.getByRole('button', { name: 'Aplicar' }))

    expect(onApply).toHaveBeenCalledTimes(1)
    expect(onApply).toHaveBeenCalledWith({ fechaDesde: '2026-05-01', fechaHasta: '2026-05-31' })
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('escribir no filtra nada por sí solo: el estado es local hasta "Aplicar"', async () => {
    const user = userEvent.setup()
    const { onApply } = renderModal({ fechaDesde: null, fechaHasta: null })

    const [desde] = inputsFecha()
    await escribirFecha(user, desde, '2026-05-01')

    expect(desde).toHaveValue('2026-05-01')
    expect(onApply).not.toHaveBeenCalled()
  })

  it('con los dos campos vacíos aplica un rango nulo (no strings vacíos)', async () => {
    const user = userEvent.setup()
    const { onApply } = renderModal({ fechaDesde: null, fechaHasta: null })

    await user.click(screen.getByRole('button', { name: 'Aplicar' }))

    expect(onApply).toHaveBeenCalledWith({ fechaDesde: null, fechaHasta: null })
  })

  it('acepta media punta: sólo "Desde"', async () => {
    const user = userEvent.setup()
    const { onApply } = renderModal({ fechaDesde: null, fechaHasta: null })

    await escribirFecha(user, inputsFecha()[0], '2026-05-01')
    await user.click(screen.getByRole('button', { name: 'Aplicar' }))

    expect(onApply).toHaveBeenCalledWith({ fechaDesde: '2026-05-01', fechaHasta: null })
  })

  it('acepta media punta: sólo "Hasta"', async () => {
    const user = userEvent.setup()
    const { onApply } = renderModal({ fechaDesde: null, fechaHasta: null })

    await escribirFecha(user, inputsFecha()[1], '2026-05-31')
    await user.click(screen.getByRole('button', { name: 'Aplicar' }))

    expect(onApply).toHaveBeenCalledWith({ fechaDesde: null, fechaHasta: '2026-05-31' })
  })

  it('reaplica sin tocar nada el rango que ya venía', async () => {
    const user = userEvent.setup()
    const { onApply } = renderModal({ fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' })

    await user.click(screen.getByRole('button', { name: 'Aplicar' }))

    expect(onApply).toHaveBeenCalledWith({ fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' })
  })

  // BUG: nadie valida que "Desde" sea anterior a "Hasta". El modal acepta el
  // rango invertido, lo aplica y cierra; la lista contesta vacía y no hay nada
  // en pantalla que explique por qué. Se asevera el comportamiento ACTUAL.
  it('BUG: acepta un rango invertido sin avisar nada', async () => {
    const user = userEvent.setup()
    const { onApply, onClose } = renderModal({ fechaDesde: null, fechaHasta: null })

    await escribirFecha(user, inputsFecha()[0], '2026-05-31')
    await escribirFecha(user, inputsFecha()[1], '2026-05-01')
    await user.click(screen.getByRole('button', { name: 'Aplicar' }))

    expect(onApply).toHaveBeenCalledWith({ fechaDesde: '2026-05-31', fechaHasta: '2026-05-01' })
    expect(onClose).toHaveBeenCalledTimes(1)
    expect(screen.queryByText(/posterior|inválid|error/i)).not.toBeInTheDocument()
  })
})

// =============================================================================
// LIMPIAR
// =============================================================================

describe('ModalFiltroFecha — "Limpiar"', () => {
  it('borra el rango y cierra', async () => {
    const user = userEvent.setup()
    const { onApply, onClose } = renderModal({ fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' })

    await user.click(screen.getByRole('button', { name: 'Limpiar' }))

    expect(onApply).toHaveBeenCalledTimes(1)
    expect(onApply).toHaveBeenCalledWith({ fechaDesde: null, fechaHasta: null })
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('ignora lo que se haya escrito recién: limpia igual', async () => {
    const user = userEvent.setup()
    const { onApply } = renderModal({ fechaDesde: null, fechaHasta: null })

    await escribirFecha(user, inputsFecha()[0], '2026-05-01')
    await user.click(screen.getByRole('button', { name: 'Limpiar' }))

    expect(onApply).toHaveBeenCalledWith({ fechaDesde: null, fechaHasta: null })
  })

  it('no vacía los inputs: lo que se ve limpio es el modal desmontado', async () => {
    const user = userEvent.setup()
    renderModal({ fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' })

    await user.click(screen.getByRole('button', { name: 'Limpiar' }))

    // El componente no cierra por sí mismo: sigue montado con los valores
    // viejos hasta que el padre deje de renderizarlo.
    expect(inputsFecha()[0]).toHaveValue('2026-04-01')
  })
})

// =============================================================================
// CERRAR SIN APLICAR
// =============================================================================

describe('ModalFiltroFecha — cerrar no aplica', () => {
  it('la X del header cierra sin emitir el rango', async () => {
    const user = userEvent.setup()
    const { onApply, onClose } = renderModal({ fechaDesde: null, fechaHasta: null })

    await escribirFecha(user, inputsFecha()[0], '2026-05-01')
    await user.click(screen.getByRole('button', { name: 'Cerrar' }))

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onApply).not.toHaveBeenCalled()
  })

  it('Escape cierra sin emitir el rango', async () => {
    const user = userEvent.setup()
    const { onApply, onClose } = renderModal({ fechaDesde: null, fechaHasta: null })

    await escribirFecha(user, inputsFecha()[1], '2026-05-31')
    await user.keyboard('{Escape}')

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onApply).not.toHaveBeenCalled()
  })
})
