/**
 * La ficha de producto y el stock: qué manda y qué NO.
 *
 * EL INCIDENTE (Taco Pozo, 19/08/2026 — COCA COLA X 3LTS X 6UND)
 * -------------------------------------------------------------
 * El admin cargó la compra de 20 unidades (6 → 26). El preventista vendió las
 * 20 en los cuatro pedidos de los ONE BLOCK y el stock volvió a 6. Correcto.
 * 29 segundos después el admin guardó la ficha, que seguía abierta con el
 * snapshot viejo, y el form mandó `stock: 26` como valor absoluto: las 20
 * unidades vendidas reaparecieron. El admin las siguió viendo en stock sin
 * entender por qué. (De regalo se revirtió el precio, por el mismo snapshot.)
 *
 * El stock no es un campo de la ficha: es un saldo que mueven los pedidos y
 * las compras mientras el modal está abierto. Lo que se fija acá es que solo
 * viaje cuando el admin lo edita a mano, y que cuando viaja lleve el valor
 * esperado para que el update pueda abortar en vez de pisar.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalProducto from './ModalProducto'
import type { ProductoDB } from '../../types'

vi.mock('../../hooks/queries', () => ({
  useMarcasQuery: () => ({ data: [] }),
}))

// Solo se monta en edición y arrastra la query de grupos de precio.
vi.mock('../productos/ProductoCondicionesMayoristas', () => ({
  default: () => null,
}))

const COCA: ProductoDB = {
  id: '340',
  nombre: 'COCA COLA X 3LTS X 6UND',
  precio: 26700,
  stock: 26,
  stock_minimo: 10,
  categoria: 'GASEOSAS',
  costo_sin_iva: 24300,
  porcentaje_iva: 21,
  condicion_iva: 'gravado',
} as unknown as ProductoDB

function renderFicha(producto: ProductoDB | null = COCA) {
  const onSave = vi.fn()
  render(
    <ModalProducto
      producto={producto}
      categorias={['GASEOSAS']}
      proveedores={[]}
      onSave={onSave}
      onClose={vi.fn()}
      guardando={false}
      esAdmin
    />,
  )
  return { onSave }
}

const guardar = () => screen.getByRole('button', { name: /Guardar/ })

/**
 * Los `<label>` de la ficha no están asociados a su input (sin `htmlFor`), así
 * que `getByLabelText` no los encuentra: se busca el label por texto exacto y
 * se baja al input de su mismo bloque.
 */
function campo(textoLabel: RegExp): HTMLInputElement {
  const label = screen.getByText(textoLabel, { selector: 'label' })
  const input = label.parentElement?.querySelector('input')
  if (!input) throw new Error(`No hay input para el label ${textoLabel}`)
  return input as HTMLInputElement
}

const campoStock = () => campo(/^Stock \*$/)
const campoPrecio = () => campo(/^Precio Final/)
const campoNombre = () => campo(/^Nombre \*$/)

describe('ModalProducto — el stock solo viaja si lo tocaste', () => {
  beforeEach(() => vi.clearAllMocks())

  it('editar el precio no manda el stock (el saldo queda como está en la base)', async () => {
    const { onSave } = renderFicha()

    const precio = campoPrecio()
    await userEvent.clear(precio)
    await userEvent.type(precio, '25500')
    await userEvent.click(guardar())

    expect(onSave).toHaveBeenCalledTimes(1)
    const payload = onSave.mock.calls[0][0]
    expect(payload.stock).toBeUndefined()
    expect(payload.stock_esperado).toBeUndefined()
    expect(Number(payload.precio)).toBe(25500)
  })

  it('cambiar el stock a mano lo manda con el valor esperado (compare-and-swap)', async () => {
    const { onSave } = renderFicha()

    await userEvent.clear(campoStock())
    await userEvent.type(campoStock(), '30')
    await userEvent.click(guardar())

    expect(onSave).toHaveBeenCalledTimes(1)
    const payload = onSave.mock.calls[0][0]
    expect(Number(payload.stock)).toBe(30)
    expect(payload.stock_esperado).toBe(26)
  })

  it('reescribir el mismo número no cuenta como ajuste', async () => {
    const { onSave } = renderFicha()

    await userEvent.clear(campoStock())
    await userEvent.type(campoStock(), '26')
    await userEvent.click(guardar())

    const payload = onSave.mock.calls[0][0]
    expect(payload.stock).toBeUndefined()
    expect(payload.stock_esperado).toBeUndefined()
  })

  it('en el alta el stock sí es un campo del form: viaja siempre y sin CAS', async () => {
    const { onSave } = renderFicha(null)

    await userEvent.type(campoNombre(), 'AGUA ECO 2LTS X 6UND')
    const precio = campoPrecio()
    await userEvent.clear(precio)
    await userEvent.type(precio, '9000')
    await userEvent.clear(campoStock())
    await userEvent.type(campoStock(), '12')
    await userEvent.click(guardar())

    expect(onSave).toHaveBeenCalledTimes(1)
    const payload = onSave.mock.calls[0][0]
    expect(Number(payload.stock)).toBe(12)
    expect(payload.stock_esperado).toBeUndefined()
  })

  it('avisa que la ficha no mueve el saldo, y describe el ajuste cuando lo hay', async () => {
    renderFicha()
    expect(screen.getByText(/Lo mueven solos las compras y los pedidos/i)).toBeInTheDocument()

    await userEvent.clear(campoStock())
    await userEvent.type(campoStock(), '30')
    expect(screen.getByText(/Ajuste manual: 26 → 30/)).toBeInTheDocument()
  })
})
