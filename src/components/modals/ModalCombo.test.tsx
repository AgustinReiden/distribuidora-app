/**
 * ModalCombo (#1191): el form valida lo mismo que `guardar_combo` y lo muestra
 * antes de guardar; la vista previa calcula "sin combo" con el producto más caro
 * de cada lugar; y `onSave` recibe el `ComboFormInput` que espera la mutación.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalCombo from './ModalCombo'
import type { ComboAdmin } from '../../hooks/queries/useCombosQuery'
import type { ProductoDB } from '../../types'

const PRODUCTOS = [
  { id: '1', nombre: 'Coca 2,25', precio: 1000, stock: 10, activo: true },
  { id: '2', nombre: 'Coca Zero 2,25', precio: 1200, stock: 10, activo: true },
  { id: '3', nombre: 'Fernet 750', precio: 5000, stock: 10, activo: true },
  { id: '4', nombre: 'Sprite Vieja', precio: 100, stock: 0, activo: false },
] as unknown as ProductoDB[]

/** Combo válido de base: 2× (Coca o Coca Zero) + 1× Fernet a $7.000. */
function comboBase(extra: Partial<ComboAdmin> = {}): ComboAdmin {
  return {
    id: '9',
    nombre: 'Combo Fernet',
    activo: true,
    fechaInicio: '2026-10-01',
    fechaFin: null,
    precio: 7000,
    combinaEscalas: false,
    prioridad: 0,
    topeCombos: null,
    productoAMoverId: null,
    componentes: [
      { cantidad: 2, productos: ['1', '2'] },
      { cantidad: 1, productos: ['3'] },
    ],
    ...extra,
  }
}

function renderModal(combo: ComboAdmin | null = comboBase(), onSave = vi.fn().mockResolvedValue(undefined)) {
  const onClose = vi.fn()
  render(<ModalCombo combo={combo} productos={PRODUCTOS} onSave={onSave} onClose={onClose} />)
  return { onSave, onClose }
}

const guardar = () => screen.getByRole('button', { name: /^(Actualizar|Crear combo)$/ })

async function reemplazar(label: string | RegExp, valor: string) {
  const input = screen.getByLabelText(label)
  await userEvent.clear(input)
  if (valor) await userEvent.type(input, valor)
}

async function guardarYVerError(mensaje: string | RegExp, onSave: ReturnType<typeof vi.fn>) {
  await userEvent.click(guardar())
  const alerta = await screen.findByRole('alert')
  expect(within(alerta).getByText(mensaje)).toBeInTheDocument()
  expect(onSave).not.toHaveBeenCalled()
}

describe('ModalCombo · vista previa', () => {
  it('"sin combo" usa el producto más caro de cada lugar y muestra el descuento', () => {
    renderModal()
    // 2 × $1.200 (la Coca Zero, la más cara del lugar) + 1 × $5.000 = $7.400
    expect(screen.getByTestId('combo-sin-combo').textContent).toMatch(/Sin combo:\s*\$\s*7\.400,00/)
    // 1 − 7000/7400 = 5,4 %
    expect(screen.getByTestId('combo-descuento').textContent).toBe('Descuento: 5,4%')
    expect(screen.queryByTestId('combo-no-conviene')).not.toBeInTheDocument()
  })

  it('avisa que no conviene si el precio iguala o supera al "sin combo"', async () => {
    renderModal()
    await reemplazar('Precio del combo', '7400')
    expect(screen.getByTestId('combo-no-conviene')).toHaveTextContent(
      'Con este precio el combo no conviene: no se va a aplicar'
    )
    expect(screen.queryByTestId('combo-descuento')).not.toBeInTheDocument()

    await reemplazar('Precio del combo', '9000')
    expect(screen.getByTestId('combo-no-conviene')).toBeInTheDocument()

    await reemplazar('Precio del combo', '3700')
    expect(screen.queryByTestId('combo-no-conviene')).not.toBeInTheDocument()
    expect(screen.getByTestId('combo-descuento').textContent).toBe('Descuento: 50%')
  })

  it('se recalcula al cambiar la cantidad de un lugar', async () => {
    renderModal()
    await reemplazar('Cantidad (lugar 2)', '3')
    // 2 × 1.200 + 3 × 5.000 = 17.400
    expect(screen.getByTestId('combo-sin-combo').textContent).toMatch(/\$\s*17\.400,00/)
  })

  it('sin precio no muestra descuento ni advertencia', async () => {
    renderModal()
    await reemplazar('Precio del combo', '')
    expect(screen.queryByTestId('combo-descuento')).not.toBeInTheDocument()
    expect(screen.queryByTestId('combo-no-conviene')).not.toBeInTheDocument()
  })
})

describe('ModalCombo · alertas de margen y descuento (#1194)', () => {
  // Costos: Coca 600, Coca Zero 700, Fernet 3.500. Peor caso: 2 × 700 + 3.500 = 4.900.
  const CON_COSTOS = [
    { id: '1', nombre: 'Coca 2,25', precio: 1000, precio_sin_iva: 1000, costo_promedio: 600, stock: 10, activo: true },
    { id: '2', nombre: 'Coca Zero 2,25', precio: 1200, precio_sin_iva: 1200, costo_promedio: 700, stock: 10, activo: true },
    { id: '3', nombre: 'Fernet 750', precio: 5000, precio_sin_iva: 5000, costo_promedio: 3500, stock: 10, activo: true },
  ] as unknown as ProductoDB[]

  function renderConCostos(verCostos: boolean, onSave = vi.fn().mockResolvedValue(undefined)) {
    render(
      <ModalCombo
        combo={comboBase()}
        productos={CON_COSTOS}
        onSave={onSave}
        onClose={vi.fn()}
        umbrales={{ margenMinimoPct: 10, descuentoMaximoPct: 30 }}
        verCostos={verCostos}
      />,
    )
    return onSave
  }

  it('muestra el margen con el costo más alto de cada lugar', () => {
    renderConCostos(true)
    // (7.000 − 4.900) / 7.000 = 30 %
    expect(screen.getByTestId('combo-margen')).toHaveTextContent(/Margen: 30% \(costo \$\s*4\.900,00\)/)
    expect(screen.queryByTestId('combo-alerta-margen_bajo')).not.toBeInTheDocument()
  })

  it('avisa margen bajo, pero deja guardar igual (precio fijo con alerta)', async () => {
    const onSave = renderConCostos(true)
    await reemplazar('Precio del combo', '5200')
    expect(screen.getByTestId('combo-alerta-margen_bajo')).toHaveTextContent('Margen bajo: 5,8%, el tope es 10%')
    await userEvent.click(guardar())
    expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ precio: 5200 }))
  })

  it('avisa margen negativo y descuento alto', async () => {
    renderConCostos(true)
    await reemplazar('Precio del combo', '4000')
    expect(screen.getByTestId('combo-alerta-margen_negativo')).toBeInTheDocument()
    expect(screen.getByTestId('combo-alerta-descuento_alto')).toHaveTextContent('Descuento alto: 45,9%, el tope es 30%')
  })

  it('sin permiso para ver costos no hay margen', () => {
    renderConCostos(false)
    expect(screen.queryByTestId('combo-margen')).not.toBeInTheDocument()
  })
})

describe('ModalCombo · validación (las mismas reglas del server)', () => {
  it('exige nombre', async () => {
    const { onSave } = renderModal()
    await reemplazar('Nombre', '')
    await guardarYVerError('Poné un nombre para el combo', onSave)
  })

  it('exige un precio mayor a 0', async () => {
    const { onSave } = renderModal()
    await reemplazar('Precio del combo', '0')
    await guardarYVerError('El precio del combo tiene que ser mayor a $0', onSave)
  })

  it('exige precio cuando está vacío', async () => {
    const { onSave } = renderModal()
    await reemplazar('Precio del combo', '')
    await guardarYVerError('Poné el precio del combo (mayor a $0)', onSave)
  })

  it('admite hasta 2 decimales en el precio', async () => {
    const { onSave } = renderModal()
    await reemplazar('Precio del combo', '6999,999')
    await guardarYVerError('El precio admite hasta 2 decimales', onSave)
  })

  it('exige fecha de inicio', async () => {
    const { onSave } = renderModal()
    fireEvent.change(screen.getByLabelText('Fecha inicio'), { target: { value: '' } })
    await guardarYVerError('Elegí la fecha de inicio', onSave)
  })

  it('la fecha de fin no puede ser anterior a la de inicio', async () => {
    const { onSave } = renderModal()
    fireEvent.change(screen.getByLabelText('Fecha fin (opcional)'), { target: { value: '2026-09-30' } })
    await guardarYVerError('La fecha de fin no puede ser anterior a la de inicio', onSave)
  })

  it('el tope tiene que ser un entero mayor a 0', async () => {
    const { onSave } = renderModal()
    await reemplazar('Tope de combos (opcional)', '0')
    await guardarYVerError('El tope de combos tiene que ser un entero mayor a 0', onSave)
    await reemplazar('Tope de combos (opcional)', '2,5')
    await userEvent.click(guardar())
    expect(await screen.findByText('El tope de combos tiene que ser un entero mayor a 0')).toBeInTheDocument()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('exige al menos un lugar', async () => {
    const { onSave } = renderModal()
    await userEvent.click(screen.getByRole('button', { name: 'Quitar lugar 2' }))
    await userEvent.click(screen.getByRole('button', { name: 'Quitar lugar 1' }))
    await guardarYVerError('Agregá al menos un lugar al combo', onSave)
  })

  it('admite hasta 20 lugares', async () => {
    const lugares = Array.from({ length: 21 }, () => ({ cantidad: 1, productos: ['1'] }))
    const { onSave } = renderModal(comboBase({ componentes: lugares }))
    await guardarYVerError('Un combo admite hasta 20 lugares', onSave)
  })

  it('no deja agregar un lugar 21 desde el botón', () => {
    const lugares = Array.from({ length: 20 }, (_, i) => ({ cantidad: 1, productos: [String((i % 3) + 1)] }))
    renderModal(comboBase({ componentes: lugares }))
    expect(screen.getByRole('button', { name: /Agregar lugar/ })).toBeDisabled()
  })

  it.each([
    ['0', 'cantidad cero'],
    ['1001', 'cantidad mayor a 1000'],
    ['1,5', 'cantidad decimal'],
    ['', 'cantidad vacía'],
  ])('la cantidad de un lugar es un entero entre 1 y 1000 (%s: %s)', async (valor) => {
    const { onSave } = renderModal()
    await reemplazar('Cantidad (lugar 1)', valor)
    await guardarYVerError('La cantidad de cada lugar tiene que ser un entero entre 1 y 1000', onSave)
  })

  it('cada lugar necesita al menos un producto', async () => {
    const { onSave } = renderModal()
    await userEvent.click(screen.getByRole('button', { name: /Agregar lugar/ }))
    await guardarYVerError('Cada lugar necesita al menos un producto', onSave)
  })

  it('un producto no puede repetirse en el combo', async () => {
    const { onSave } = renderModal(
      comboBase({
        componentes: [
          { cantidad: 1, productos: ['1'] },
          { cantidad: 1, productos: ['1', '3'] },
        ],
      })
    )
    await guardarYVerError('Un producto no puede estar dos veces en el combo', onSave)
  })

  it('suma al menos 2 unidades en total', async () => {
    const { onSave } = renderModal(comboBase({ componentes: [{ cantidad: 1, productos: ['1', '2'] }] }))
    await guardarYVerError('El combo tiene que sumar al menos 2 unidades en total', onSave)
  })

  it('el producto a mover tiene que ser uno del combo', async () => {
    // El 4 no está en ningún lugar: el combo se guardó así o se le quitó el producto.
    const { onSave } = renderModal(comboBase({ productoAMoverId: '4' }))
    await guardarYVerError('El producto a mover tiene que ser uno de los productos del combo', onSave)
  })

  it('junta todos los errores a la vez', async () => {
    const { onSave } = renderModal()
    await reemplazar('Nombre', '')
    await reemplazar('Precio del combo', '0')
    await userEvent.click(guardar())
    const alerta = await screen.findByRole('alert')
    expect(within(alerta).getByText('Poné un nombre para el combo')).toBeInTheDocument()
    expect(within(alerta).getByText('El precio del combo tiene que ser mayor a $0')).toBeInTheDocument()
    expect(onSave).not.toHaveBeenCalled()
  })
})

describe('ModalCombo · productos', () => {
  it('sólo ofrece productos activos y marca el inactivo ya elegido', async () => {
    renderModal(comboBase({ componentes: [{ cantidad: 2, productos: ['4'] }, { cantidad: 1, productos: ['3'] }] }))
    expect(screen.getByText('(inactivo)')).toBeInTheDocument()

    await userEvent.type(screen.getByLabelText('Buscar producto del lugar 2'), 'Sprite')
    expect(await screen.findByText('Sin resultados')).toBeInTheDocument()
  })

  it('agregar y quitar productos de un lugar', async () => {
    renderModal(comboBase({ componentes: [{ cantidad: 2, productos: ['1'] }, { cantidad: 1, productos: ['3'] }] }))
    await userEvent.type(screen.getByLabelText('Buscar producto del lugar 1'), 'zero')
    await userEvent.click(await screen.findByRole('button', { name: /Coca Zero 2,25/ }))
    expect(screen.getByRole('button', { name: 'Quitar Coca Zero 2,25' })).toBeInTheDocument()

    await userEvent.click(screen.getByRole('button', { name: 'Quitar Coca Zero 2,25' }))
    expect(screen.queryByRole('button', { name: 'Quitar Coca Zero 2,25' })).not.toBeInTheDocument()
  })
})

describe('ModalCombo · guardado', () => {
  it('arma el ComboFormInput de un combo nuevo', async () => {
    const { onSave } = renderModal(null)

    await userEvent.type(screen.getByLabelText('Nombre'), '  Combo Fernet  ')
    await userEvent.type(screen.getByLabelText('Precio del combo'), '6.500,50')
    fireEvent.change(screen.getByLabelText('Fecha inicio'), { target: { value: '2026-10-15' } })
    fireEvent.change(screen.getByLabelText('Fecha fin (opcional)'), { target: { value: '2026-12-31' } })

    // Lugar 1: 2 × (Coca o Coca Zero)
    await reemplazar('Cantidad (lugar 1)', '2')
    await userEvent.type(screen.getByLabelText('Buscar producto del lugar 1'), 'Coca')
    await userEvent.click(await screen.findByRole('button', { name: /^Coca 2,25/ }))
    await userEvent.type(screen.getByLabelText('Buscar producto del lugar 1'), 'zero')
    await userEvent.click(await screen.findByRole('button', { name: /Coca Zero/ }))

    // Lugar 2: 1 × Fernet
    await userEvent.click(screen.getByRole('button', { name: /Agregar lugar/ }))
    await userEvent.type(screen.getByLabelText('Buscar producto del lugar 2'), 'fernet')
    await userEvent.click(await screen.findByRole('button', { name: /Fernet 750/ }))

    await userEvent.click(screen.getByLabelText('Se combina con escalas mayoristas'))
    await reemplazar('Prioridad', '3')
    await reemplazar('Tope de combos (opcional)', '40')
    await userEvent.selectOptions(screen.getByLabelText('Producto a mover (opcional)'), '3')

    await userEvent.click(screen.getByRole('button', { name: 'Crear combo' }))

    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0]).toEqual({
      nombre: 'Combo Fernet',
      precio: 6500.5,
      fechaInicio: '2026-10-15',
      fechaFin: '2026-12-31',
      activo: true,
      combinaEscalas: true,
      prioridad: 3,
      topeCombos: 40,
      productoAMoverId: '3',
      componentes: [
        { cantidad: 2, productos: ['1', '2'] },
        { cantidad: 1, productos: ['3'] },
      ],
    })
  })

  it('al editar conserva id y activo, y manda nulos para lo opcional vacío', async () => {
    const { onSave } = renderModal(comboBase({ activo: false }))
    await userEvent.click(screen.getByRole('button', { name: 'Actualizar' }))

    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0]).toEqual({
      id: '9',
      nombre: 'Combo Fernet',
      precio: 7000,
      fechaInicio: '2026-10-01',
      fechaFin: null,
      activo: false,
      combinaEscalas: false,
      prioridad: 0,
      topeCombos: null,
      productoAMoverId: null,
      componentes: [
        { cantidad: 2, productos: ['1', '2'] },
        { cantidad: 1, productos: ['3'] },
      ],
    })
  })

  it('muestra el error del server y deja el modal abierto para corregir', async () => {
    const onSave = vi.fn().mockRejectedValue(new Error('Ya hay un combo con ese nombre'))
    const { onClose } = renderModal(comboBase(), onSave)
    await userEvent.click(guardar())
    expect(await screen.findByText('Ya hay un combo con ese nombre')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
    expect(guardar()).not.toBeDisabled()
  })
})
