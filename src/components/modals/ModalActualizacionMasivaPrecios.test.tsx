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
const notifyWarning = vi.fn()
const notifyError = vi.fn()
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: notifySuccess, error: notifyError, warning: notifyWarning }),
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

// #1473: el lote saltea los productos trabados y el resto ya quedó guardado. El
// modal no se cierra, avisa, y deja seleccionados sólo los trabados: volver a
// aplicar no le suma el porcentaje otra vez a los que ya cambiaron.
describe('ModalActualizacionMasivaPrecios — productos trabados', () => {
  it('deja seleccionados sólo los trabados y avisa sin cerrar', async () => {
    const otro = { ...producto, id: 'p2', nombre: 'Yerba 1kg', codigo: 'YER1' } as unknown as ProductoDB
    const err = Object.assign(new Error('Se actualizaron 1 producto(s). 1 no se cambiaron…'), {
      status: 409, trabados: [{ producto_id: 'p2', nombre: 'Yerba 1kg' }],
    })
    mutateAsync.mockRejectedValueOnce(err)
    const onClose = vi.fn()
    render(
      <ModalActualizacionMasivaPrecios productos={[producto, otro]} proveedores={[]} categorias={['aceites']} onClose={onClose} />
    )

    fireEvent.click(screen.getByRole('checkbox', { name: /seleccionar aceite 900ml/i }))
    fireEvent.click(screen.getByRole('checkbox', { name: /seleccionar yerba 1kg/i }))
    fireEvent.change(screen.getByLabelText(/porcentaje de aumento o rebaja/i), { target: { value: '10' } })
    fireEvent.click(screen.getByRole('button', { name: /^aplicar$/i }))
    fireEvent.click(await screen.findByRole('button', { name: /^confirmar$/i }))

    await waitFor(() => expect(notifyWarning).toHaveBeenCalledWith(err.message))
    expect(notifyError).not.toHaveBeenCalled()
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('checkbox', { name: /seleccionar aceite 900ml/i })).not.toBeChecked()
    expect(screen.getByRole('checkbox', { name: /seleccionar yerba 1kg/i })).toBeChecked()
  })
})
