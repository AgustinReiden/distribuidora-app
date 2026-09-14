/**
 * `ModalConfirmacion` se renderizaba como hermano de `</ModalBase>` (un Dialog
 * de Radix portaleado): quedaba detrás del overlay y "Aplicar" no hacía nada
 * visible. Este test prueba que el confirm aparece en el documento y que
 * confirmar dispara la mutación — lo que un test que solo mire el JSX no
 * puede garantizar, porque Radix portalea el contenido fuera del árbol.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import ModalActualizacionMasivaPrecios from './ModalActualizacionMasivaPrecios'
import type { ProductoDB } from '../../types'

const mutateAsync = vi.fn().mockResolvedValue({ actualizados: 1, errores: [] })

vi.mock('../../hooks/queries', () => ({
  useActualizarPreciosMasivoMutation: () => ({
    mutateAsync,
    isPending: false,
  }),
}))

const notifySuccess = vi.fn()
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: notifySuccess, error: vi.fn() }),
}))

const producto = {
  id: 'p1',
  nombre: 'Aceite 900ml',
  codigo: 'ACE900',
  precio: 1000,
  precio_sin_iva: 900,
  impuestos_internos: 4.1667,
  proveedor_id: null,
  categoria: 'aceites',
} as unknown as ProductoDB

function renderModal() {
  return render(
    <ModalActualizacionMasivaPrecios
      productos={[producto]}
      proveedores={[]}
      categorias={['aceites']}
      onClose={vi.fn()}
    />
  )
}

describe('ModalActualizacionMasivaPrecios — confirmación', () => {
  it('el confirm se renderiza visible y "Aplicar" dispara la actualización', async () => {
    renderModal()

    fireEvent.click(screen.getByRole('checkbox', { name: /seleccionar aceite 900ml/i }))
    fireEvent.change(screen.getByLabelText(/porcentaje de aumento o rebaja/i), {
      target: { value: '10' },
    })
    fireEvent.click(screen.getByRole('button', { name: /^aplicar$/i }))

    // Si el confirm quedara detrás del overlay (el bug), este texto no
    // aparecería como visible en el documento.
    expect(await screen.findByText(/confirmar actualización/i)).toBeVisible()

    // El mensaje ya no promete tocar impuestos internos (redacción vieja:
    // "modifica precio neto, final e impuestos internos").
    const mensaje = screen.getByText(/precio neto y precio final/i)
    expect(mensaje).toBeVisible()
    expect(mensaje.textContent).not.toMatch(/final e impuestos internos/i)

    fireEvent.click(screen.getByRole('button', { name: /^confirmar$/i }))

    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    const items = mutateAsync.mock.calls[0][0]
    expect(items).toEqual([
      { producto_id: 'p1', precio_neto: 990, imp_internos: null, precio_final: 1100 },
    ])
  })
})
