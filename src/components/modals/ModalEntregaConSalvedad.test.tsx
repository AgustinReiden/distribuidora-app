/**
 * Caracterización de ModalEntregaConSalvedad, escrita antes del rediseño de UI.
 *
 * Era un `<div className="fixed inset-0">` hecho a mano; desde WP-27 (#720) es
 * un `ModalBase` (Radix) con `bodyBare`. Tiene DOS pasos (selección ->
 * confirmación) en el mismo montaje. Lo que tenía que sobrevivir a la
 * migración está acá:
 *
 *  - el ida y vuelta entre pasos sin perder lo seleccionado,
 *  - las validaciones por item, con el nombre del producto adelante,
 *  - el payload EXACTO de `onSave` (incluido `devolverStock`, que sale del
 *    motivo, y el orden regalos-primero: si la salvedad del producto que
 *    dispara la promo entra antes, la línea del regalo ya no existe),
 *  - que `onMarcarEntregado` corre DESPUÉS de las salvedades y sólo si todas
 *    entraron,
 *  - y el resumen de regalos que devuelve el dry-run de la promo (mig 174).
 *
 * Lo que la migración cambió a propósito está en "cerrar": Escape ahora cierra,
 * pero sólo si no hay nada tildado (`entregaSalvedadTieneCambios`).
 */
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { RegaloSimulado } from '../../hooks/queries/useSimularSalvedadesQuery'
import type { PedidoDB, RegistrarSalvedadResult } from '../../types'

let regalosSimulados: RegaloSimulado[] = []
let simulando = false

/**
 * Con qué `enabled` se llamó al dry-run en cada render, en orden.
 *
 * El hook va mockeado entero, así que el `enabled: paso === 'confirmacion'`
 * (ModalEntregaConSalvedad.tsx:97) se perdería: el RPC de la mig 174 se
 * dispararía en cada tecla del paso 1 y ningún test se pondría rojo. Se
 * registra el tercer argumento para poder aseverarlo.
 */
const enabledPorRender: (boolean | undefined)[] = []

vi.mock('../../hooks/queries', () => ({
  useSimularSalvedadesPromoImpactoQuery: (
    _pedidoId: unknown,
    _salvedades: unknown,
    opciones?: { enabled?: boolean },
  ) => {
    enabledPorRender.push(opciones?.enabled)
    return { data: regalosSimulados, isLoading: simulando }
  },
}))

import ModalEntregaConSalvedad, {
  type ModalEntregaConSalvedadProps,
} from './ModalEntregaConSalvedad'

type OnSave = ModalEntregaConSalvedadProps['onSave']
type OnMarcarEntregado = ModalEntregaConSalvedadProps['onMarcarEntregado']

const PEDIDO = {
  id: '42',
  cliente_id: '9',
  estado: 'preparado',
  total: 6500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur' },
  items: [
    {
      id: '101',
      pedido_id: '42',
      producto_id: '1',
      producto: { nombre: 'Aceite Girasol 900ml' },
      cantidad: 5,
      precio_unitario: 1000,
    },
    {
      id: '102',
      pedido_id: '42',
      producto_id: '2',
      producto: { nombre: 'Fideos 500g' },
      cantidad: 3,
      precio_unitario: 500,
    },
    {
      id: '103',
      pedido_id: '42',
      producto_id: '3',
      producto: { nombre: 'Vaso' },
      descripcion_regalo: 'Vaso de regalo 3x2',
      es_bonificacion: true,
      cantidad: 2,
      precio_unitario: 0,
    },
  ],
} as unknown as PedidoDB

const OK: RegistrarSalvedadResult[] = [{ success: true }]

function renderModal(over: { onSave?: Mock<OnSave> } = {}) {
  const onSave: Mock<OnSave> = over.onSave ?? vi.fn<OnSave>().mockResolvedValue(OK)
  const onMarcarEntregado: Mock<OnMarcarEntregado> = vi
    .fn<OnMarcarEntregado>()
    .mockResolvedValue(undefined)
  const onClose: Mock<() => void> = vi.fn()
  render(
    <ModalEntregaConSalvedad
      pedido={PEDIDO}
      onSave={onSave}
      onMarcarEntregado={onMarcarEntregado}
      onClose={onClose}
    />,
  )
  return { onSave, onMarcarEntregado, onClose, user: userEvent.setup() }
}

/** La fila de un item se tilda clickeando su nombre: el handler vive en el div. */
async function tildarItem(user: ReturnType<typeof userEvent.setup>, nombre: string) {
  await user.click(screen.getByText(nombre))
}

/**
 * El campo de cantidad de la fila expandida.
 *
 * BUG: la etiqueta "Cantidad con problema" es un `<label>` sin `htmlFor` y el
 * input no está anidado, así que no hay asociación accesible. Sólo hay una fila
 * expandida por vez, así que se lo ubica por rol (el otro `textbox` visible es
 * el textarea de descripción, que sí tiene placeholder).
 */
const inputCantidadAfectada = (): HTMLElement => screen.getAllByRole('textbox')[0]

/**
 * La X del header.
 *
 * Antes de WP-27 no tenía `aria-label` ni texto y su nombre accesible era
 * vacío; la X de `ModalBase` se llama "Cerrar", y por ese nombre se la busca.
 */
const botonCerrar = (): HTMLElement => screen.getByRole('button', { name: 'Cerrar' })

/** Lleva el modal al paso de confirmación con una salvedad válida sobre el aceite. */
async function llegarAConfirmacion(user: ReturnType<typeof userEvent.setup>) {
  await tildarItem(user, 'Aceite Girasol 900ml')
  await user.clear(inputCantidadAfectada())
  await user.type(inputCantidadAfectada(), '2')
  await user.selectOptions(screen.getByRole('combobox'), 'cliente_rechaza')
  await user.click(screen.getByRole('button', { name: /continuar/i }))
}

beforeEach(() => {
  regalosSimulados = []
  simulando = false
  enabledPorRender.length = 0
})

describe('ModalEntregaConSalvedad — paso de selección', () => {
  it('lista los items del pedido y no deja continuar sin elegir ninguno', () => {
    renderModal()

    expect(screen.getByRole('heading', { name: 'Entrega con Salvedad' })).toBeInTheDocument()
    expect(screen.getByText('Pedido #42 - Kiosco Sur')).toBeVisible()
    expect(screen.getByText('Aceite Girasol 900ml')).toBeVisible()
    expect(screen.getByText('Fideos 500g')).toBeVisible()
    expect(screen.getByRole('button', { name: /continuar/i })).toBeDisabled()
  })

  /**
   * Antes de WP-27 el contenedor era un `<div fixed>` sin `role="dialog"`: no
   * había diálogo ni nombre que anunciar. Ahora hay UNO, que se llama como el
   * título visible (no uno inventado ni ninguno), y el pedido sigue a la vista.
   */
  it('es un dialog cuyo nombre es "Entrega con Salvedad"', () => {
    renderModal()

    const dialogos = screen.getAllByRole('dialog')
    expect(dialogos).toHaveLength(1)
    expect(screen.getByRole('dialog', { name: 'Entrega con Salvedad' })).toBe(dialogos[0])
    expect(screen.getByRole('heading', { name: 'Entrega con Salvedad' })).toBeInTheDocument()
    expect(within(dialogos[0]).getByText('Pedido #42 - Kiosco Sur')).toBeVisible()
  })

  /**
   * Lo modal no se asevera con el atributo `aria-modal`: Radix 1.1.15 no lo
   * pone (#800). Lo que hace es marcar `aria-hidden` todo lo que queda fuera
   * del diálogo —un lector de pantalla no se escapa a la vista de atrás—, y es
   * eso lo que se fija acá.
   */
  it('es modal: la vista de atrás sale del árbol accesible', () => {
    render(
      <>
        <button type="button">Vista de fondo</button>
        <ModalEntregaConSalvedad
          pedido={PEDIDO}
          onSave={vi.fn<OnSave>()}
          onMarcarEntregado={vi.fn<OnMarcarEntregado>()}
          onClose={vi.fn()}
        />
      </>,
    )

    expect(screen.getByRole('dialog', { name: 'Entrega con Salvedad' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Vista de fondo' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Vista de fondo', hidden: true })).toBeInTheDocument()
  })

  it('el dry-run de promos está APAGADO en el paso 1 y sólo se enciende al confirmar', async () => {
    const { user } = renderModal()

    // El RPC de la mig 174 no se dispara mientras se eligen items: se dispara
    // una vez, con el lote completo, al pasar al resumen.
    expect(enabledPorRender.length).toBeGreaterThan(0)
    expect(enabledPorRender.every(e => e === false)).toBe(true)

    await tildarItem(user, 'Aceite Girasol 900ml')
    await user.clear(inputCantidadAfectada())
    await user.type(inputCantidadAfectada(), '2')
    await user.selectOptions(screen.getByRole('combobox'), 'cliente_rechaza')

    expect(enabledPorRender.every(e => e === false)).toBe(true)

    await user.click(screen.getByRole('button', { name: /continuar/i }))

    expect(enabledPorRender[enabledPorRender.length - 1]).toBe(true)

    // Y volver lo vuelve a apagar.
    await user.click(screen.getByRole('button', { name: /volver/i }))

    expect(enabledPorRender[enabledPorRender.length - 1]).toBe(false)
  })

  /**
   * BUG: la fila de un item es un `<div onClick>` sin `role` ni `tabIndex`
   * (ModalEntregaConSalvedad.tsx:266-268), y el "checkbox" es un `<div>`
   * pintado, no un `<input type="checkbox">`. O sea: con el teclado solo NO se
   * puede tildar un item, y la entrega con salvedad entera queda fuera de
   * alcance. Se asevera lo de HOY; migrar a controles de verdad lo pone rojo, y
   * ahí el test se actualiza al comportamiento nuevo.
   */
  it('hoy un item NO se puede tildar con el teclado', async () => {
    const { user } = renderModal()

    expect(screen.queryAllByRole('checkbox')).toHaveLength(0)

    // Se recorre todo el orden de tabulación del modal apretando Enter en cada
    // parada: ninguna abre el detalle de un item.
    for (let i = 0; i < 10; i++) {
      await user.tab()
      await user.keyboard('{Enter}')
    }

    expect(screen.queryByText('Cantidad con problema')).toBeNull()
    expect(screen.getByRole('button', { name: /continuar/i })).toBeDisabled()
  })

  it('el regalo se muestra como tal, no como una línea cobrable', () => {
    renderModal()

    // El nombre del regalo es su `descripcion_regalo`, no el del producto.
    expect(screen.getByText('Vaso de regalo 3x2')).toBeVisible()
    expect(screen.getByText('REGALO')).toBeVisible()
    expect(screen.getByText(/2 ud\. de regalo - si cae la promo se ajusta solo/i)).toBeVisible()
  })

  it('tildar un item abre su detalle con cantidad, motivo y descripción', async () => {
    const { user } = renderModal()

    await tildarItem(user, 'Aceite Girasol 900ml')

    expect(screen.getByText('Cantidad con problema')).toBeVisible()
    expect(screen.getByRole('combobox')).toBeInTheDocument()
    expect(screen.getByPlaceholderText('Detalle adicional...')).toBeVisible()
    expect(screen.getByRole('button', { name: /continuar/i })).toBeEnabled()
  })

  it('la cantidad afectada arranca en la del item y muestra cuántas se entregan', async () => {
    const { user } = renderModal()

    await tildarItem(user, 'Aceite Girasol 900ml')
    expect(screen.getByText(/se entregaran: 0 unidades/i)).toBeVisible()

    await user.clear(inputCantidadAfectada())
    await user.type(inputCantidadAfectada(), '2')

    expect(screen.getByText(/se entregaran: 3 unidades/i)).toBeVisible()
  })

  it('un regalo no ofrece "Diferencia de Precio" como motivo', async () => {
    const { user } = renderModal()

    await tildarItem(user, 'Vaso de regalo 3x2')

    const motivos = within(screen.getByRole('combobox')).getAllByRole('option')
    expect(motivos.map(o => o.textContent)).toEqual([
      'Seleccionar motivo...',
      'Faltante de Stock',
      'Producto Dañado',
      'Cliente Rechaza',
      'Error en Pedido',
      'Producto Vencido',
      'Otro',
    ])
  })
})

describe('ModalEntregaConSalvedad — validaciones antes de continuar', () => {
  it('sin motivo avisa con el nombre del producto adelante y no cambia de paso', async () => {
    const { user } = renderModal()

    await tildarItem(user, 'Aceite Girasol 900ml')
    await user.click(screen.getByRole('button', { name: /continuar/i }))

    expect(screen.getByText('Aceite Girasol 900ml: Debe seleccionar un motivo')).toBeVisible()
    expect(screen.queryByText('Resumen de la entrega')).toBeNull()
  })

  it('el motivo "Otro" exige una descripción de al menos 10 caracteres', async () => {
    const { user } = renderModal()

    await tildarItem(user, 'Aceite Girasol 900ml')
    await user.selectOptions(screen.getByRole('combobox'), 'otro')
    await user.type(screen.getByPlaceholderText('Detalle adicional...'), 'corto')
    await user.click(screen.getByRole('button', { name: /continuar/i }))

    expect(
      screen.getByText('Aceite Girasol 900ml: Debe especificar una descripción (mínimo 10 caracteres)'),
    ).toBeVisible()
  })
})

describe('ModalEntregaConSalvedad — paso de confirmación', () => {
  it('resume lo entregado, lo afectado y los totales', async () => {
    const { user } = renderModal()

    await llegarAConfirmacion(user)

    expect(screen.getByRole('heading', { name: 'Resumen de la entrega' })).toBeInTheDocument()
    expect(screen.getByText(/3x Fideos 500g/)).toBeVisible()
    expect(
      screen.getByText('Aceite Girasol 900ml: 2 ud. con problema (Cliente Rechaza) - Se entregan 3 ud.'),
    ).toBeVisible()
    expect(screen.getByText('Total original:')).toBeVisible()
    expect(screen.getByText('Monto afectado por salvedades:')).toBeVisible()
    expect(screen.getByText('Total efectivo a cobrar:')).toBeVisible()
  })

  it('Volver regresa a la selección sin perder lo tildado', async () => {
    const { user } = renderModal()

    await llegarAConfirmacion(user)
    await user.click(screen.getByRole('button', { name: /volver/i }))

    expect(screen.queryByText('Resumen de la entrega')).toBeNull()
    // Sigue tildado: el motivo elegido se mantiene en el select de la fila.
    expect(screen.getByRole('combobox')).toHaveValue('cliente_rechaza')
    expect(screen.getByRole('button', { name: /continuar/i })).toBeEnabled()
  })

  it('mientras el dry-run corre avisa que está recalculando los regalos', async () => {
    simulando = true
    const { user } = renderModal()

    await llegarAConfirmacion(user)

    expect(screen.getByText('Recalculando los regalos por promocion...')).toBeVisible()
  })

  it('dice qué pasa con cada regalo cuando la promo se recalcula', async () => {
    regalosSimulados = [
      {
        pedido_item_id: 103,
        promocion_id: 7,
        promo_nombre: '3x2 Aceite',
        producto_id: 3,
        producto_nombre: 'Vaso',
        descripcion_regalo: 'Vaso de regalo 3x2',
        cantidad_actual: 2,
        cantidad_final: 0,
        delta: 2,
        sera_eliminada: true,
      },
    ]
    const { user } = renderModal()

    await llegarAConfirmacion(user)

    expect(
      screen.getByText('Vaso de regalo 3x2: no se entrega - se cae la promo "3x2 Aceite"'),
    ).toBeVisible()
  })
})

describe('ModalEntregaConSalvedad — confirmar la entrega', () => {
  it('manda la salvedad con devolverStock derivado del motivo y después marca entregado', async () => {
    const { user, onSave, onMarcarEntregado, onClose } = renderModal()

    await tildarItem(user, 'Aceite Girasol 900ml')
    await user.clear(inputCantidadAfectada())
    await user.type(inputCantidadAfectada(), '2')
    await user.selectOptions(screen.getByRole('combobox'), 'cliente_rechaza')
    await user.click(screen.getByRole('button', { name: /continuar/i }))
    await user.click(screen.getByRole('button', { name: /confirmar entrega/i }))

    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0]).toEqual([
      {
        pedidoId: '42',
        pedidoItemId: '101',
        cantidadAfectada: 2,
        motivo: 'cliente_rechaza',
        descripcion: undefined,
        // 'cliente_rechaza' devuelve la mercadería: el stock vuelve.
        devolverStock: true,
        clientRequestId: expect.any(String),
      },
    ])
    expect(onMarcarEntregado).toHaveBeenCalledTimes(1)
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('un motivo que NO devuelve mercadería viaja con devolverStock en false', async () => {
    const { user, onSave } = renderModal()

    await tildarItem(user, 'Aceite Girasol 900ml')
    await user.selectOptions(screen.getByRole('combobox'), 'producto_danado')
    await user.click(screen.getByRole('button', { name: /continuar/i }))
    await user.click(screen.getByRole('button', { name: /confirmar entrega/i }))

    expect(onSave.mock.calls[0][0][0]).toMatchObject({
      motivo: 'producto_danado',
      devolverStock: false,
      cantidadAfectada: 5,
    })
  })

  it('los regalos van PRIMERO en el lote, aunque se tilden después', async () => {
    const { user, onSave } = renderModal({
      onSave: vi.fn().mockResolvedValue([{ success: true }, { success: true }]),
    })

    await tildarItem(user, 'Aceite Girasol 900ml')
    await user.selectOptions(screen.getByRole('combobox'), 'cliente_rechaza')
    await tildarItem(user, 'Vaso de regalo 3x2')
    await user.selectOptions(screen.getByRole('combobox'), 'faltante_stock')
    await user.click(screen.getByRole('button', { name: /continuar/i }))
    await user.click(screen.getByRole('button', { name: /confirmar entrega/i }))

    // Al revés, la línea del regalo ya no existiría cuando le toca el turno:
    // la resync del servidor la baja al registrar la salvedad del producto.
    expect(onSave.mock.calls[0][0].map((s: { pedidoItemId: string }) => s.pedidoItemId))
      .toEqual(['103', '101'])
  })

  it('el mismo lote reintentado reusa el clientRequestId (idempotencia, mig 049)', async () => {
    const onSave = vi
      .fn()
      .mockResolvedValueOnce([{ success: false, error: 'Load failed' }])
      .mockResolvedValueOnce(OK)
    const { user } = renderModal({ onSave })

    await tildarItem(user, 'Aceite Girasol 900ml')
    await user.selectOptions(screen.getByRole('combobox'), 'cliente_rechaza')
    await user.click(screen.getByRole('button', { name: /continuar/i }))
    await user.click(screen.getByRole('button', { name: /confirmar entrega/i }))
    await user.click(screen.getByRole('button', { name: /confirmar entrega/i }))

    expect(onSave).toHaveBeenCalledTimes(2)
    expect(onSave.mock.calls[0][0][0].clientRequestId)
      .toBe(onSave.mock.calls[1][0][0].clientRequestId)
  })

  it('si una salvedad falla, avisa y NO marca el pedido entregado', async () => {
    const onSave = vi.fn().mockResolvedValue([{ success: false, error: 'stock insuficiente' }])
    const { user, onMarcarEntregado, onClose } = renderModal({ onSave })

    await tildarItem(user, 'Aceite Girasol 900ml')
    await user.selectOptions(screen.getByRole('combobox'), 'cliente_rechaza')
    await user.click(screen.getByRole('button', { name: /continuar/i }))
    await user.click(screen.getByRole('button', { name: /confirmar entrega/i }))

    expect(await screen.findByText('Error al registrar 1 salvedad(es): stock insuficiente'))
      .toBeVisible()
    expect(onMarcarEntregado).not.toHaveBeenCalled()
    expect(onClose).not.toHaveBeenCalled()
  })

  it('un regalo que la promo ya sacó del pedido no cuenta como error', async () => {
    const onSave = vi
      .fn()
      .mockResolvedValue([{ success: false, codigo: 'item_no_encontrado', error: 'no existe' }])
    const { user, onMarcarEntregado, onClose } = renderModal({ onSave })

    await tildarItem(user, 'Vaso de regalo 3x2')
    await user.selectOptions(screen.getByRole('combobox'), 'faltante_stock')
    await user.click(screen.getByRole('button', { name: /continuar/i }))
    await user.click(screen.getByRole('button', { name: /confirmar entrega/i }))

    expect(screen.queryByText(/error al registrar/i)).toBeNull()
    expect(onMarcarEntregado).toHaveBeenCalledTimes(1)
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})

describe('ModalEntregaConSalvedad — cerrar', () => {
  it('Cancelar cierra sin guardar nada', async () => {
    const { user, onSave, onMarcarEntregado, onClose } = renderModal()

    await user.click(screen.getByRole('button', { name: /^cancelar$/i }))

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onSave).not.toHaveBeenCalled()
    expect(onMarcarEntregado).not.toHaveBeenCalled()
  })

  it('la X del header también cierra', async () => {
    const { user, onClose } = renderModal()

    await user.click(botonCerrar())

    expect(onClose).toHaveBeenCalledTimes(1)
  })

  // El modal hecho a mano no cerraba con Escape. Con ModalBase (Radix) Escape
  // cierra, pero sólo si no hay nada que perder: sin ningún item tildado, como
  // acá. Con algo tildado se lo traga (tests de abajo).
  it('sin nada tildado, Escape cierra sin guardar nada', async () => {
    const { user, onSave, onMarcarEntregado, onClose } = renderModal()

    await user.keyboard('{Escape}')

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onSave).not.toHaveBeenCalled()
    expect(onMarcarEntregado).not.toHaveBeenCalled()
  })

  it('con un item tildado, Escape NO cierra y lo cargado sigue ahí', async () => {
    const { user, onClose } = renderModal()

    await tildarItem(user, 'Aceite Girasol 900ml')
    await user.selectOptions(screen.getByRole('combobox'), 'cliente_rechaza')
    await user.keyboard('{Escape}')

    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('dialog', { name: 'Entrega con Salvedad' })).toBeInTheDocument()
    expect(screen.getByRole('combobox')).toHaveValue('cliente_rechaza')
    expect(screen.getByRole('button', { name: /continuar/i })).toBeEnabled()
  })

  it('destildar todo vuelve a dejar cerrar con Escape', async () => {
    const { user, onClose } = renderModal()

    await tildarItem(user, 'Aceite Girasol 900ml')
    await tildarItem(user, 'Aceite Girasol 900ml')
    await user.keyboard('{Escape}')

    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('en el paso de confirmación, Escape NO cierra', async () => {
    const { user, onSave, onClose } = renderModal()

    await llegarAConfirmacion(user)
    await user.keyboard('{Escape}')

    expect(onClose).not.toHaveBeenCalled()
    expect(onSave).not.toHaveBeenCalled()
    expect(screen.getByRole('heading', { name: 'Resumen de la entrega' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /confirmar entrega/i })).toBeEnabled()
  })

  it('con un item tildado, la X cierra igual (es un click deliberado)', async () => {
    const { user, onSave, onClose } = renderModal()

    await tildarItem(user, 'Aceite Girasol 900ml')
    await user.click(botonCerrar())

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('con un item tildado, Cancelar cierra igual', async () => {
    const { user, onSave, onClose } = renderModal()

    await tildarItem(user, 'Aceite Girasol 900ml')
    await user.click(screen.getByRole('button', { name: /^cancelar$/i }))

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('en el paso de confirmación, la X cierra igual sin guardar', async () => {
    const { user, onSave, onMarcarEntregado, onClose } = renderModal()

    await llegarAConfirmacion(user)
    await user.click(botonCerrar())

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onSave).not.toHaveBeenCalled()
    expect(onMarcarEntregado).not.toHaveBeenCalled()
  })
})
