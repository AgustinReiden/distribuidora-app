/**
 * Caracterización de ModalMermaStock, escrita antes del rediseño de UI.
 *
 * Era un `<div className="fixed inset-0">` hecho a mano; desde WP-26 (#719) es
 * un `ModalBase` (Radix). Lo que tenía que sobrevivir a la migración está acá:
 * los textos que se ven, el payload EXACTO de `onSave` (viaja la cantidad, no
 * el saldo — #518 / mig 232), qué motivos se ofrecen y cuál no (`promociones`
 * nunca), y qué pasa cuando el guardado falla.
 *
 * El schema `modalMermaSchema` está co-locado a propósito (regla de CLAUDE.md
 * sobre chunks desincronizados del PWA) y está exportado, así que se cubre
 * directo: los mensajes son parte del contrato aunque la UI no los alcance.
 */
import { useState } from 'react'
import { describe, it, expect, vi, type Mock } from 'vitest'
import { act, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalMermaStock, { modalMermaSchema, type ModalMermaStockProps } from './ModalMermaStock'
import type { Producto } from '../../types'

type OnSave = ModalMermaStockProps['onSave']

const PRODUCTO = {
  id: 'p-1',
  nombre: 'Aceite Girasol 900ml',
  codigo: 'ACE900',
  stock: 100,
} as unknown as Producto

function renderModal(
  props: { producto?: Producto | null; onSave?: Mock<OnSave> } = {},
) {
  const onSave: Mock<OnSave> = props.onSave ?? vi.fn<OnSave>(() => Promise.resolve())
  const onClose: Mock<() => void> = vi.fn()
  render(
    <ModalMermaStock
      producto={props.producto === undefined ? PRODUCTO : props.producto}
      onSave={onSave}
      onClose={onClose}
    />,
  )
  return { onSave, onClose, user: userEvent.setup() }
}

/**
 * El campo de cantidad, por su etiqueta visible. Hasta #801 el `<label>` no
 * tenía `htmlFor` y había que ubicarlo como el primer `textbox`.
 */
const inputCantidad = (): HTMLElement => screen.getByLabelText(/cantidad a dar de baja/i)

/**
 * La X del header.
 *
 * Antes de WP-26 no tenía `aria-label` ni texto y su nombre accesible era
 * vacío; la X de `ModalBase` se llama "Cerrar", y por ese nombre se la busca.
 */
const botonCerrar = (): HTMLElement => screen.getByRole('button', { name: 'Cerrar' })

describe('ModalMermaStock — qué se ve', () => {
  it('no renderiza nada sin producto', () => {
    renderModal({ producto: null })

    expect(screen.queryByRole('heading', { name: /baja de stock/i })).toBeNull()
  })

  it('muestra el producto, su código y el stock actual', () => {
    renderModal()

    expect(screen.getByRole('heading', { name: 'Baja de Stock' })).toBeInTheDocument()
    expect(screen.getByText('Registrar merma o perdida')).toBeVisible()
    expect(screen.getByText('Aceite Girasol 900ml')).toBeVisible()
    expect(screen.getByText('Codigo: ACE900')).toBeVisible()
    expect(screen.getByText(/stock actual:/i)).toHaveTextContent('100')
  })

  /**
   * Antes de WP-26 el contenedor era un `<div fixed>` sin `role="dialog"`: no
   * había diálogo ni nombre que anunciar. Ahora hay UNO, que se llama como el
   * título visible (no uno inventado ni ninguno) y al que el subtítulo describe.
   */
  it('es un dialog cuyo nombre es "Baja de Stock"', () => {
    renderModal()

    const dialogos = screen.getAllByRole('dialog')
    expect(dialogos).toHaveLength(1)
    expect(screen.getByRole('dialog', { name: 'Baja de Stock' })).toBe(dialogos[0])
    expect(dialogos[0]).toHaveAccessibleDescription('Registrar merma o perdida')
    expect(screen.getByRole('heading', { name: 'Baja de Stock' })).toBeInTheDocument()
    expect(screen.getByText('Registrar merma o perdida')).toBeVisible()
  })

  /**
   * Lo modal se fija por su efecto y no por el atributo `aria-modal` (Radix
   * 1.1.15 no lo pone; lo agrega ui/Dialog desde #800 y lo cubre
   * ui/Dialog.test.tsx). Lo que hace Radix es marcar `aria-hidden` todo lo que
   * queda fuera del diálogo, que es el efecto que se busca (un lector de
   * pantalla no se escapa a la vista de atrás) y lo que se fija acá.
   */
  it('es modal: la vista de atrás sale del árbol accesible', () => {
    render(
      <>
        <button type="button">Vista de fondo</button>
        <ModalMermaStock producto={PRODUCTO} onSave={vi.fn<OnSave>()} onClose={vi.fn()} />
      </>,
    )

    expect(screen.getByRole('dialog', { name: 'Baja de Stock' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Vista de fondo' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Vista de fondo', hidden: true })).toBeInTheDocument()
  })

  it('los campos se nombran por su etiqueta: cantidad y observaciones (#801)', () => {
    renderModal()

    expect(screen.getByRole('textbox', { name: /cantidad a dar de baja/i })).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: /observaciones/i })).toBeInTheDocument()
  })

  it('adelanta el stock que va a quedar después de la baja', async () => {
    const { user } = renderModal()

    expect(screen.getByText(/stock despues de la baja:/i)).toHaveTextContent('99')

    await user.clear(inputCantidad())
    await user.type(inputCantidad(), '30')

    expect(screen.getByText(/stock despues de la baja:/i)).toHaveTextContent('70')
  })

  it('ofrece los motivos cargables a mano y NO ofrece promociones', () => {
    renderModal()

    for (const motivo of [
      /rotura/i,
      /vencimiento/i,
      /robo\/hurto/i,
      /decomiso/i,
      /devolucion defectuosa/i,
      /error de inventario/i,
      /muestra\/degustacion/i,
      /otro motivo/i,
    ]) {
      expect(screen.getByRole('button', { name: motivo })).toBeInTheDocument()
    }

    // `promociones` lo escribe el motor de promos como contrapartida de un
    // regalo, y el reporte gerencial lo EXCLUYE de las mermas (mig 130): una
    // pérdida real cargada con ese motivo se evapora de todos los KPIs.
    expect(screen.queryByRole('button', { name: /promocion/i })).toBeNull()
  })

  it('no promete un guardado local que no existe (#761)', () => {
    renderModal()

    expect(screen.getByRole('button', { name: /^cancelar$/i })).toBeInTheDocument()
    expect(screen.queryByText(/sin conexion/i)).toBeNull()
    expect(screen.queryByText(/localmente/i)).toBeNull()
  })
})

describe('ModalMermaStock — validación', () => {
  it('sin motivo elegido el botón de guardar está deshabilitado', () => {
    renderModal()

    expect(screen.getByRole('button', { name: /registrar baja/i })).toBeDisabled()
  })

  it('elegir un motivo habilita el guardado', async () => {
    const { user } = renderModal()

    await user.click(screen.getByRole('button', { name: /rotura/i }))

    expect(screen.getByRole('button', { name: /registrar baja/i })).toBeEnabled()
  })

  // BUG: la guarda "no exceder stock" del handler es inalcanzable con el mouse.
  // `NumberInput` tiene `max={producto.stock}` y clampa en el blur, y el click
  // sobre "Registrar Baja" produce ese blur ANTES del submit: la cantidad que
  // llega al handler ya viene recortada, así que el mensaje "No puede dar de
  // baja mas de N unidades (stock actual)" nunca se muestra. Se asevera lo que
  // pasa HOY (se guarda el stock completo, en silencio), no lo que debería.
  it('tipear más unidades que el stock guarda el stock completo, sin avisar', async () => {
    const { user, onSave } = renderModal()

    await user.click(screen.getByRole('button', { name: /rotura/i }))
    await user.clear(inputCantidad())
    await user.type(inputCantidad(), '500')
    await user.click(screen.getByRole('button', { name: /registrar baja/i }))

    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0]).toMatchObject({ cantidad: 100 })
    expect(screen.queryByText(/no puede dar de baja mas de/i)).toBeNull()
  })

  it('muestra el mensaje del servidor cuando el guardado falla y no cierra', async () => {
    const onSave = vi.fn<OnSave>().mockRejectedValue(new Error('El stock es 3 y la baja es de 5'))
    const { user, onClose } = renderModal({ onSave })

    await user.click(screen.getByRole('button', { name: /vencimiento/i }))
    await user.click(screen.getByRole('button', { name: /registrar baja/i }))

    expect(await screen.findByText('El stock es 3 y la baja es de 5')).toBeVisible()
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: /registrar baja/i })).toBeEnabled()
  })

  /**
   * El mismo caso, con la forma de error que llega DE VERDAD.
   *
   * El test de arriba rechaza con `new Error(...)` y por eso pasaba en verde
   * mientras en producción se veía "Error al registrar la merma": supabase-js
   * no lanza `Error`, lanza un objeto plano, y el `err instanceof Error` que
   * tenía este catch daba false para todos los errores reales. Se vio en un
   * iPhone con 4G de una barra: el modal y el toast mostraron sus dos literales
   * de fallback a la vez. Ver src/utils/errorDeSupabase.ts.
   */
  it('muestra el mensaje aunque el error NO sea una instancia de Error', async () => {
    const plano = { message: 'Acceso denegado: se requiere rol admin', details: '', hint: '', code: '42501' }
    const onSave = vi.fn<OnSave>().mockRejectedValue(plano)
    const { user, onClose } = renderModal({ onSave })

    await user.click(screen.getByRole('button', { name: /rotura/i }))
    await user.click(screen.getByRole('button', { name: /registrar baja/i }))

    expect(await screen.findByText('Acceso denegado: se requiere rol admin')).toBeVisible()
    expect(screen.queryByText(/error al registrar la merma/i)).toBeNull()
    expect(onClose).not.toHaveBeenCalled()
  })
})

describe('ModalMermaStock — guardar y cerrar', () => {
  it('guarda la CANTIDAD (no el saldo) con el motivo, su label y las observaciones', async () => {
    const { user, onSave, onClose } = renderModal()

    await user.clear(inputCantidad())
    await user.type(inputCantidad(), '7')
    await user.click(screen.getByRole('button', { name: /robo\/hurto/i }))
    await user.type(
      screen.getByPlaceholderText(/detalle adicional sobre la baja/i),
      'Faltaron 7 del pallet del lunes',
    )
    await user.click(screen.getByRole('button', { name: /registrar baja/i }))

    expect(onSave).toHaveBeenCalledTimes(1)
    // El payload NO lleva `stockNuevo`: ese absoluto salía de un snapshot y dos
    // bajas simultáneas se pisaban (#518). El stock lo resuelve la mig 232.
    expect(onSave.mock.calls[0][0]).toEqual({
      productoId: 'p-1',
      productoNombre: 'Aceite Girasol 900ml',
      productoCodigo: 'ACE900',
      cantidad: 7,
      motivo: 'robo',
      motivoLabel: 'Robo/Hurto',
      observaciones: 'Faltaron 7 del pallet del lunes',
    })
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('sin observaciones manda el string vacío, no undefined', async () => {
    const { user, onSave } = renderModal()

    await user.click(screen.getByRole('button', { name: /otro motivo/i }))
    await user.click(screen.getByRole('button', { name: /registrar baja/i }))

    expect(onSave.mock.calls[0][0]).toMatchObject({
      cantidad: 1,
      motivo: 'otro',
      motivoLabel: 'Otro motivo',
      observaciones: '',
    })
  })

  it('Cancelar cierra sin guardar', async () => {
    const { user, onSave, onClose } = renderModal()

    await user.click(screen.getByRole('button', { name: /^cancelar$/i }))

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('la X del header también cierra sin guardar', async () => {
    const { user, onSave, onClose } = renderModal()

    await user.click(botonCerrar())

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('Escape cierra sin guardar', async () => {
    const { user, onSave, onClose } = renderModal()

    await user.keyboard('{Escape}')

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('el foco queda dentro del diálogo al abrir', () => {
    renderModal()

    expect(screen.getByRole('dialog', { name: 'Baja de Stock' }))
      .toContainElement(document.activeElement as HTMLElement)
  })

  /**
   * Al cerrar, el foco vuelve al botón que abrió el modal: el usuario de teclado
   * o de lector de pantalla sigue donde estaba. ModalBase monta `<Dialog open>`
   * sin `Dialog.Trigger`, así que la devolución de Radix 1.1.15 (que va al
   * Trigger) no alcanza; la hace `DialogContent` de ui/Dialog, que guarda quién
   * tenía el foco al abrir (#800). Hasta ese arreglo el foco caía en `<body>`,
   * también con el div hecho a mano de antes de WP-26.
   */
  it.each([
    ['Escape', (user: ReturnType<typeof userEvent.setup>) => user.keyboard('{Escape}')],
    ['Cancelar', (user: ReturnType<typeof userEvent.setup>) =>
      user.click(screen.getByRole('button', { name: /^cancelar$/i }))],
  ])('al cerrar con %s el foco vuelve al botón que lo abrió', async (_, cerrar) => {
    function Host() {
      const [abierto, setAbierto] = useState(false)
      return (
        <>
          <button type="button" onClick={() => setAbierto(true)}>Abrir baja</button>
          {abierto && (
            <ModalMermaStock
              producto={PRODUCTO}
              onSave={vi.fn<OnSave>()}
              onClose={() => setAbierto(false)}
            />
          )}
        </>
      )
    }
    render(<Host />)
    const user = userEvent.setup()
    const abrir = screen.getByRole('button', { name: 'Abrir baja' })

    await user.click(abrir)
    expect(screen.getByRole('dialog', { name: 'Baja de Stock' }))
      .toContainElement(document.activeElement as HTMLElement)

    await cerrar(user)
    expect(screen.queryByRole('dialog')).toBeNull()

    // FocusScope decide a dónde va el foco en un `setTimeout(0)` al desmontar:
    // sin dejarlo correr, el foco todavía no volvió y la aserción mediría nada.
    await act(() => new Promise<void>(resolve => setTimeout(resolve, 0)))

    expect(abrir).toHaveFocus()
  })
})

describe('modalMermaSchema — el contrato que la UI no siempre alcanza', () => {
  it('acepta una cantidad entera positiva y coerciona el string del input', () => {
    const resultado = modalMermaSchema.safeParse({ cantidad: '3', motivo: 'rotura' })

    expect(resultado.success).toBe(true)
    expect(resultado.success && resultado.data.cantidad).toBe(3)
  })

  it('rechaza una cantidad decimal', () => {
    const resultado = modalMermaSchema.safeParse({ cantidad: 2.5, motivo: 'rotura' })

    expect(resultado.success).toBe(false)
    expect(resultado.success === false && resultado.error.issues[0].message)
      .toBe('La cantidad debe ser un número entero')
  })

  it('rechaza una cantidad de cero o negativa', () => {
    const resultado = modalMermaSchema.safeParse({ cantidad: 0, motivo: 'rotura' })

    expect(resultado.success).toBe(false)
    expect(resultado.success === false && resultado.error.issues[0].message)
      .toBe('La cantidad debe ser mayor a 0')
  })

  it('exige motivo', () => {
    const resultado = modalMermaSchema.safeParse({ cantidad: 1, motivo: '' })

    expect(resultado.success).toBe(false)
    expect(resultado.success === false && resultado.error.issues[0].message)
      .toBe('Debe seleccionar un motivo')
  })
})
