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

// Las condiciones mayoristas (#1561, CAT-7): por defecto, ninguna.
let grupos: unknown[] = []
let gruposEstado: { isSuccess: boolean; isError: boolean } = { isSuccess: true, isError: false }
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({
  useGruposPrecioQuery: () => ({ data: grupos, ...gruposEstado, refetch: vi.fn() }),
}))

// La política comercial (#1561, CAT-8): el múltiplo del redondeo.
let politica: { politicas: { multiploRedondeoPrecio: number }; isSuccess: boolean; isError: boolean } =
  { politicas: { multiploRedondeoPrecio: 10 }, isSuccess: true, isError: false }
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ ...politica, refetch: vi.fn() }),
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
    const entrada = mutateAsync.mock.calls[0][0]
    // El neto sale del final (1100 / 1,21), no de redondear el neto aparte (#1561, CAT-8).
    expect(entrada).toEqual({
      items: [{ producto_id: 'p1', precio_neto: 909.09, imp_internos: null, precio_final: 1100 }],
      escalas: [],
    })
  })
})

// #1561 (CAT-7): decisión del dueño, el aumento avisa cuántas escalas tienen los
// productos elegidos y ofrece aplicarles el mismo porcentaje, tildado por defecto.
describe('ModalActualizacionMasivaPrecios — escalas mayoristas', () => {
  const otro = { ...producto, id: 'p2', nombre: 'Yerba 1kg', codigo: 'YER1' } as unknown as ProductoDB
  const condicion = {
    id: 'g1', nombre: 'Almacén', productos: [{ producto_id: 'p1' }, { producto_id: 'p2' }],
    escalas: [{ id: 'e1', grupo_precio_id: 'g1', cantidad_minima: 10, precio_unitario: 900 }],
    escalaMinimos: {},
  }

  async function aplicar(seleccionar: string[]) {
    render(<ModalActualizacionMasivaPrecios productos={[producto, otro]} proveedores={[]} categorias={['aceites']} onClose={vi.fn()} />)
    for (const n of seleccionar) fireEvent.click(screen.getByRole('checkbox', { name: new RegExp(`seleccionar ${n}`, 'i') }))
    fireEvent.change(screen.getByLabelText(/porcentaje de aumento o rebaja/i), { target: { value: '10' } })
  }

  it('con toda la condición elegida ofrece sus escalas tildadas y las manda con el mismo porcentaje', async () => {
    grupos = [condicion]
    mutateAsync.mockClear()
    await aplicar(['aceite 900ml', 'yerba 1kg'])
    const ofrecer = screen.getByRole('checkbox', { name: /aplicarles el mismo porcentaje/i })
    expect(ofrecer).toBeChecked()
    expect(screen.getByText(/tienen/i).textContent).toMatch(/1\s*escala/)

    fireEvent.click(screen.getByRole('button', { name: /^aplicar$/i }))
    expect(await screen.findByText(/y 1 escala\(s\) mayorista\(s\)/i)).toBeVisible()
    fireEvent.click(screen.getByRole('button', { name: /^confirmar$/i }))
    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    const { escalas } = mutateAsync.mock.calls[0][0]
    expect(escalas).toHaveLength(1)
    expect(escalas[0].escala).toEqual({ escala_id: 'e1', precio_unitario: 990, minimos: [] })
  })

  it('destildada, no manda las escalas y el confirm lo dice', async () => {
    grupos = [condicion]
    mutateAsync.mockClear()
    await aplicar(['aceite 900ml', 'yerba 1kg'])
    fireEvent.click(screen.getByRole('checkbox', { name: /aplicarles el mismo porcentaje/i }))
    fireEvent.click(screen.getByRole('button', { name: /^aplicar$/i }))
    expect(await screen.findByText(/las escalas mayoristas quedan como están/i)).toBeVisible()
    fireEvent.click(screen.getByRole('button', { name: /^confirmar$/i }))
    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    expect(mutateAsync.mock.calls[0][0].escalas).toEqual([])
  })

  it('con la condición elegida a medias avisa que su escala no se toca', async () => {
    grupos = [condicion]
    await aplicar(['aceite 900ml'])
    expect(screen.queryByRole('checkbox', { name: /aplicarles el mismo porcentaje/i })).toBeNull()
    expect(screen.getByText(/de Almacén no se tocan/i)).toBeVisible()
  })

  it('si las condiciones no cargan, no deja aplicar y ofrece reintentar', async () => {
    grupos = []
    gruposEstado = { isSuccess: false, isError: true }
    await aplicar(['aceite 900ml'])
    expect(screen.getByRole('alert').textContent).toMatch(/no se pudieron cargar las condiciones mayoristas/i)
    expect(screen.getByRole('button', { name: /^aplicar$/i })).toBeDisabled()
    gruposEstado = { isSuccess: true, isError: false }
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

// #1561 (CAT-8): el múltiplo del redondeo sale de la política comercial de la sucursal.
describe('ModalActualizacionMasivaPrecios — el múltiplo de la política', () => {
  async function aplicarDiez() {
    render(<ModalActualizacionMasivaPrecios productos={[producto]} proveedores={[]} categorias={['aceites']} onClose={vi.fn()} />)
    fireEvent.click(screen.getByRole('checkbox', { name: /seleccionar aceite 900ml/i }))
    fireEvent.change(screen.getByLabelText(/porcentaje de aumento o rebaja/i), { target: { value: '7' } })
  }

  it('redondea al múltiplo de la política y lo dice', async () => {
    grupos = []
    politica = { politicas: { multiploRedondeoPrecio: 50 }, isSuccess: true, isError: false }
    mutateAsync.mockClear()
    await aplicarDiez()
    expect(screen.getByText(/múltiplos de \$50/)).toBeVisible()
    fireEvent.click(screen.getByRole('button', { name: /^aplicar$/i }))
    fireEvent.click(await screen.findByRole('button', { name: /^confirmar$/i }))
    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    // 1000 + 7 % = 1070 → a múltiplo de 50 da 1050 o 1100, y los dos se mueven menos que el 7 %: 1050.
    expect(mutateAsync.mock.calls[0][0].items[0].precio_final).toBe(1050)
    politica = { politicas: { multiploRedondeoPrecio: 10 }, isSuccess: true, isError: false }
  })

  it('si la política no carga, no deja aplicar y ofrece reintentar', async () => {
    grupos = []
    politica = { politicas: { multiploRedondeoPrecio: 10 }, isSuccess: false, isError: true }
    await aplicarDiez()
    expect(screen.getByRole('alert').textContent).toMatch(/no se pudo cargar la política comercial/i)
    expect(screen.getByRole('button', { name: /^aplicar$/i })).toBeDisabled()
    politica = { politicas: { multiploRedondeoPrecio: 10 }, isSuccess: true, isError: false }
  })
})
