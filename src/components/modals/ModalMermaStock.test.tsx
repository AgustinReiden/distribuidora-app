/**
 * Caracterización de ModalMermaStock antes del rediseño de UI.
 *
 * Hoy es un `<div className="fixed inset-0">` hecho a mano. Lo que tiene que
 * sobrevivir a la migración a `ModalBase` (Radix) está acá: los textos que se
 * ven, el payload EXACTO de `onSave` (viaja la cantidad, no el saldo — #518 /
 * mig 232), qué motivos se ofrecen y cuál no (`promociones` nunca), y qué pasa
 * cuando el guardado falla.
 *
 * El schema `modalMermaSchema` está co-locado a propósito (regla de CLAUDE.md
 * sobre chunks desincronizados del PWA) y está exportado, así que se cubre
 * directo: los mensajes son parte del contrato aunque la UI no los alcance.
 */
import { describe, it, expect, vi, type Mock } from 'vitest'
import { render, screen } from '@testing-library/react'
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
  props: { producto?: Producto | null; isOffline?: boolean; onSave?: Mock<OnSave> } = {},
) {
  const onSave: Mock<OnSave> = props.onSave ?? vi.fn<OnSave>(() => Promise.resolve())
  const onClose: Mock<() => void> = vi.fn()
  render(
    <ModalMermaStock
      producto={props.producto === undefined ? PRODUCTO : props.producto}
      onSave={onSave}
      onClose={onClose}
      isOffline={props.isOffline}
    />,
  )
  return { onSave, onClose, user: userEvent.setup() }
}

/**
 * El campo de cantidad.
 *
 * BUG: la etiqueta visible "Cantidad a dar de baja *" es un `<label>` sin
 * `htmlFor` y el input no está anidado adentro, así que no hay asociación:
 * `getByLabelText(/cantidad a dar de baja/i)` no lo encuentra y un lector de
 * pantalla anuncia el campo sin nombre. Se lo ubica por rol y posición (es el
 * primer `textbox`; el segundo es el textarea de observaciones). Se asevera el
 * comportamiento ACTUAL: al migrar a ModalBase conviene atar el label y este
 * helper puede pasar a `getByLabelText`.
 */
const inputCantidad = (): HTMLElement => screen.getAllByRole('textbox')[0]

/**
 * La X del header.
 *
 * BUG: no tiene `aria-label` ni texto, así que su nombre accesible es vacío —
 * el único botón del modal en esa condición. `ModalBase` ya la rotula
 * ("Cerrar"), de modo que al migrar esto se arregla solo.
 */
function botonCerrarSinNombre(): HTMLElement {
  const sinNombre = screen
    .getAllByRole('button')
    .filter(b => (b.textContent ?? '').trim() === '' && !b.getAttribute('aria-label'))
  expect(sinNombre).toHaveLength(1)
  return sinNombre[0]
}

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
   * BUG (a arreglar en la migración): el contenedor es un `<div fixed>` sin
   * `role="dialog"` ni `aria-modal`, así que no hay diálogo ni nombre que
   * anunciar. Se fija con qué nombre tiene que quedar al pasar a `ModalBase`:
   * el título visible, no uno inventado ni ninguno.
   */
  it('hoy no hay role="dialog"; el nombre a heredar es "Baja de Stock"', () => {
    renderModal()

    expect(screen.queryAllByRole('dialog')).toHaveLength(0)
    expect(screen.getByRole('heading', { name: 'Baja de Stock' })).toBeInTheDocument()
    expect(screen.getByText('Registrar merma o perdida')).toBeVisible()
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

  it('sin isOffline no aparece ningún aviso de conexión', () => {
    renderModal()

    expect(screen.getByRole('button', { name: /^cancelar$/i })).toBeInTheDocument()
    expect(screen.queryByText(/sin conexion/i)).toBeNull()
  })

  it('con isOffline avisa que se guarda localmente', () => {
    renderModal({ isOffline: true })

    expect(screen.getByText(/sin conexion\. se guardara localmente y sincronizara despues\./i))
      .toBeVisible()
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

    await user.click(botonCerrarSinNombre())

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onSave).not.toHaveBeenCalled()
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
