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

// Los precios que hay hoy en la base (FRG2-3): por defecto, los mismos que el caché.
// `preciosEnBase` pisa por id; lo que no está acá se lee igual que el producto de abajo.
const preciosEnBase = new Map<string, { precio: number; precio_sin_iva: number }>()
const leerPreciosVigentes = vi.fn(async (ids: readonly string[]) =>
  ids.flatMap(id => {
    const p = preciosEnBase.get(id) ?? { precio: 1000, precio_sin_iva: 900 }
    return [{ id, precio: p.precio, precio_sin_iva: p.precio_sin_iva }]
  }))
vi.mock('../../hooks/queries/preciosVigentes', () => ({
  leerPreciosVigentes: (ids: readonly string[]) => leerPreciosVigentes(ids),
}))

// Las condiciones mayoristas (#1561, CAT-7): por defecto, ninguna.
let grupos: unknown[] = []
let gruposEstado: { isSuccess: boolean; isError: boolean } = { isSuccess: true, isError: false }
// Lo que hay hoy en la base: por defecto, lo mismo que el caché.
const gruposRefetch = vi.fn(async () => ({ data: grupos }))
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({
  useGruposPrecioQuery: () => ({ data: grupos, ...gruposEstado, refetch: gruposRefetch }),
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
  // B20 (D17): un porcentaje no lleva miles; la tecla del punto es la coma y el menos entra.
  it('el porcentaje tipeado «-2.5» se ve «-2,5»', async () => {
    const { default: userEvent } = await import('@testing-library/user-event')
    renderModal()
    const campo = screen.getByLabelText(/porcentaje de aumento o rebaja/i) as HTMLInputElement
    await userEvent.type(campo, '-2.5')
    expect(campo.value).toBe('-2,5')
  })

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

// #1561: después de una corrida nunca queda seleccionado, con «Aplicar» habilitado, un
// producto que ya se aumentó. Una escala que no se cambió no es un producto sin aumentar.
describe('ModalActualizacionMasivaPrecios — lo que queda después de aplicar', () => {
  const otro = { ...producto, id: 'p2', nombre: 'Yerba 1kg', codigo: 'YER1' } as unknown as ProductoDB

  function aplicarALosDos(onClose = vi.fn()) {
    render(
      <ModalActualizacionMasivaPrecios productos={[producto, otro]} proveedores={[]} categorias={['aceites']} onClose={onClose} />
    )
    fireEvent.click(screen.getByRole('checkbox', { name: /seleccionar aceite 900ml/i }))
    fireEvent.click(screen.getByRole('checkbox', { name: /seleccionar yerba 1kg/i }))
    fireEvent.change(screen.getByLabelText(/porcentaje de aumento o rebaja/i), { target: { value: '10' } })
    fireEvent.click(screen.getByRole('button', { name: /^aplicar$/i }))
    return onClose
  }

  it('si entraron todos y sólo una escala no se cambió, cierra y avisa sin error', async () => {
    notifyWarning.mockClear(); notifyError.mockClear(); notifySuccess.mockClear()
    mutateAsync.mockResolvedValueOnce({
      success: true, actualizados: 2, escalas_actualizadas: 0, errores: [], trabados: [],
      escalas_sin_cambiar: ['La escala de 12 u. de «Aceites» no se cambió: la condición tiene más de 1000 productos'],
    })
    const onClose = aplicarALosDos()
    fireEvent.click(await screen.findByRole('button', { name: /^confirmar$/i }))

    await waitFor(() => expect(onClose).toHaveBeenCalled())
    expect(notifyWarning).toHaveBeenCalledWith(
      '2 producto(s) actualizado(s). 1 escala(s) mayorista(s) no se cambiaron: '
      + 'La escala de 12 u. de «Aceites» no se cambió: la condición tiene más de 1000 productos.'
    )
    expect(notifyError).not.toHaveBeenCalled()
    expect(notifySuccess).not.toHaveBeenCalled()
  })

  it('si algunos cambiaron y otros no entraron sin poder reintentarse, la selección queda vacía', async () => {
    notifyWarning.mockClear(); notifyError.mockClear()
    const err = Object.assign(new Error('Se actualizaron 1 producto(s), pero 1 no: Producto ID p2 no encontrado en la sucursal activa'), {
      status: 409, actualizados: 1,
    })
    mutateAsync.mockRejectedValueOnce(err)
    const onClose = aplicarALosDos()
    fireEvent.click(await screen.findByRole('button', { name: /^confirmar$/i }))

    await waitFor(() => expect(notifyWarning).toHaveBeenCalledWith(err.message))
    expect(notifyError).not.toHaveBeenCalled()
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('checkbox', { name: /seleccionar aceite 900ml/i })).not.toBeChecked()
    expect(screen.getByRole('checkbox', { name: /seleccionar yerba 1kg/i })).not.toBeChecked()
    expect(screen.getByRole('button', { name: /^aplicar$/i })).toBeDisabled()
  })

  it('si no cambió nada, la selección queda como estaba y es un error', async () => {
    notifyWarning.mockClear(); notifyError.mockClear()
    mutateAsync.mockRejectedValueOnce(new Error('se requiere rol admin'))
    aplicarALosDos()
    fireEvent.click(await screen.findByRole('button', { name: /^confirmar$/i }))

    await waitFor(() => expect(notifyError).toHaveBeenCalledWith('se requiere rol admin'))
    expect(screen.getByRole('checkbox', { name: /seleccionar aceite 900ml/i })).toBeChecked()
    expect(screen.getByRole('checkbox', { name: /seleccionar yerba 1kg/i })).toBeChecked()
  })
})

// FRG2-3 (#1599): el aumento calcula sobre el caché (hasta 10 minutos) y manda precios
// absolutos: pisaba el cambio de otro admin. Al confirmar se relee la base; si algún precio
// cambió desde que se abrió, se avisa y no se aplica hasta que se confirme sobre los nuevos.
describe('ModalActualizacionMasivaPrecios — precios que cambiaron desde que se abrió (FRG2-3)', () => {
  async function aplicarDiez() {
    render(<ModalActualizacionMasivaPrecios productos={[producto]} proveedores={[]} categorias={['aceites']} onClose={vi.fn()} />)
    fireEvent.click(screen.getByRole('checkbox', { name: /seleccionar aceite 900ml/i }))
    fireEvent.change(screen.getByLabelText(/porcentaje de aumento o rebaja/i), { target: { value: '10' } })
    fireEvent.click(screen.getByRole('button', { name: /^aplicar$/i }))
    fireEvent.click(await screen.findByRole('button', { name: /^confirmar$/i }))
  }

  it('si el precio de la base ya no es el que se vio, avisa cuál y de cuánto a cuánto, y no aplica', async () => {
    grupos = []
    mutateAsync.mockClear(); notifyWarning.mockClear()
    preciosEnBase.clear()
    preciosEnBase.set('p1', { precio: 1200, precio_sin_iva: 1000 })
    await aplicarDiez()

    const aviso = await screen.findByRole('alert')
    expect(aviso.textContent).toMatch(/Aceite 900ml/)
    expect(aviso.textContent).toMatch(/de \$\s?1\.000(,00)? a \$\s?1\.200(,00)?/)
    expect(aviso.textContent).toMatch(/No se aplicó nada/)
    expect(mutateAsync).not.toHaveBeenCalled()
    expect(notifyWarning).toHaveBeenCalled()
  })

  it('el aviso de la pantalla dice «No se aplicó nada» una sola vez: el toast no lo repite', async () => {
    grupos = []
    mutateAsync.mockClear(); notifyWarning.mockClear()
    preciosEnBase.clear()
    preciosEnBase.set('p1', { precio: 1200, precio_sin_iva: 1000 })
    await aplicarDiez()

    await screen.findByRole('alert')
    const toast = String(notifyWarning.mock.calls[0][0])
    expect(toast).not.toMatch(/No se aplicó nada/)
    expect(toast).toMatch(/revisá el aviso/)
  })

  it('al volver a confirmar, aplica sobre los precios nuevos de la base', async () => {
    grupos = []
    mutateAsync.mockClear()
    preciosEnBase.clear()
    preciosEnBase.set('p1', { precio: 1200, precio_sin_iva: 1000 })
    await aplicarDiez()
    await screen.findByRole('alert')
    expect(mutateAsync).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: /^aplicar$/i }))
    fireEvent.click(await screen.findByRole('button', { name: /^confirmar$/i }))
    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    // 1200 + 10 % = 1320, no 1100 (el caché decía 1000).
    expect(mutateAsync.mock.calls[0][0].items[0].precio_final).toBe(1320)
    preciosEnBase.clear()
  })

  it('si cambió otra vez entre la primera confirmación y la segunda, vuelve a avisar', async () => {
    grupos = []
    mutateAsync.mockClear()
    preciosEnBase.clear()
    preciosEnBase.set('p1', { precio: 1200, precio_sin_iva: 1000 })
    await aplicarDiez()
    await screen.findByRole('alert')

    preciosEnBase.set('p1', { precio: 1500, precio_sin_iva: 1240 })
    fireEvent.click(screen.getByRole('button', { name: /^aplicar$/i }))
    fireEvent.click(await screen.findByRole('button', { name: /^confirmar$/i }))
    await waitFor(() => expect(screen.getByRole('alert').textContent).toMatch(/de \$\s?1\.200(,00)? a \$\s?1\.500(,00)?/))
    expect(mutateAsync).not.toHaveBeenCalled()
    preciosEnBase.clear()
  })

  it('un producto que la base ya no devuelve se saca de la selección y no se aplica', async () => {
    grupos = []
    mutateAsync.mockClear()
    preciosEnBase.clear()
    leerPreciosVigentes.mockResolvedValueOnce([])
    await aplicarDiez()
    const aviso = await screen.findByRole('alert')
    expect(aviso.textContent).toMatch(/ya no está en esta sucursal/)
    expect(mutateAsync).not.toHaveBeenCalled()
    expect(screen.getByRole('checkbox', { name: /seleccionar aceite 900ml/i })).not.toBeChecked()
  })

  it('con los mismos precios en la base aplica de una', async () => {
    grupos = []
    mutateAsync.mockClear()
    preciosEnBase.clear()
    await aplicarDiez()
    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    expect(screen.queryByText(/No se aplicó nada/)).toBeNull()
  })

  it('si no se pueden verificar los precios, no aplica y lo dice', async () => {
    grupos = []
    mutateAsync.mockClear(); notifyError.mockClear()
    leerPreciosVigentes.mockRejectedValueOnce(new Error('Sin conexión: no se pudieron verificar los precios actuales.'))
    await aplicarDiez()
    await waitFor(() => expect(notifyError).toHaveBeenCalledWith(expect.stringMatching(/no se pudieron verificar/i)))
    expect(mutateAsync).not.toHaveBeenCalled()
  })
})

// #1599 (1599-b7): un producto sin precio no cambia con un porcentaje (el RPC conserva el
// valor previo) pero se contaba como «actualizado»: ni se manda ni se cuenta.
describe('ModalActualizacionMasivaPrecios — productos sin precio', () => {
  const sinPrecio = {
    ...producto, id: 'p3', nombre: 'Sal fina 1kg', codigo: 'SAL1', precio: 0, precio_sin_iva: null,
  } as unknown as ProductoDB

  it('no manda el producto sin precio, lo avisa y cuenta sólo los que cambian', async () => {
    grupos = []
    mutateAsync.mockClear()
    render(<ModalActualizacionMasivaPrecios productos={[producto, sinPrecio]} proveedores={[]} categorias={['aceites']} onClose={vi.fn()} />)
    fireEvent.click(screen.getByRole('checkbox', { name: /seleccionar aceite 900ml/i }))
    fireEvent.click(screen.getByRole('checkbox', { name: /seleccionar sal fina 1kg/i }))
    fireEvent.change(screen.getByLabelText(/porcentaje de aumento o rebaja/i), { target: { value: '10' } })

    expect(screen.getByText(/1 sin precio: no se tocan/)).toBeVisible()
    fireEvent.click(screen.getByRole('button', { name: /^aplicar$/i }))
    expect(await screen.findByText(/Vas a actualizar 1 producto\(s\).*1 seleccionado\(s\) sin precio quedan afuera/)).toBeVisible()
    fireEvent.click(screen.getByRole('button', { name: /^confirmar$/i }))

    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    expect(mutateAsync.mock.calls[0][0].items.map((i: { producto_id: string }) => i.producto_id)).toEqual(['p1'])
  })

  it('si todo lo seleccionado está sin precio, no deja aplicar', () => {
    grupos = []
    render(<ModalActualizacionMasivaPrecios productos={[sinPrecio]} proveedores={[]} categorias={['aceites']} onClose={vi.fn()} />)
    fireEvent.click(screen.getByRole('checkbox', { name: /seleccionar sal fina 1kg/i }))
    fireEvent.change(screen.getByLabelText(/porcentaje de aumento o rebaja/i), { target: { value: '10' } })

    expect(screen.getByRole('button', { name: /^aplicar$/i })).toBeDisabled()
  })
})

// FRG2-3 (resto, #1599): las escalas mayoristas se leen de la base al confirmar, no del caché.
describe('ModalActualizacionMasivaPrecios — escalas que cambiaron desde que se abrió', () => {
  const condicion = (precioEscala: number) => ({
    id: 'g1', nombre: 'Almacén', productos: [{ producto_id: 'p1' }],
    escalas: [{ id: 'e1', grupo_precio_id: 'g1', cantidad_minima: 10, precio_unitario: precioEscala }],
    escalaMinimos: {},
  })

  async function confirmar() {
    render(<ModalActualizacionMasivaPrecios productos={[producto]} proveedores={[]} categorias={['aceites']} onClose={vi.fn()} />)
    fireEvent.click(screen.getByRole('checkbox', { name: /seleccionar aceite 900ml/i }))
    fireEvent.change(screen.getByLabelText(/porcentaje de aumento o rebaja/i), { target: { value: '10' } })
    fireEvent.click(screen.getByRole('button', { name: /^aplicar$/i }))
    fireEvent.click(await screen.findByRole('button', { name: /^confirmar$/i }))
  }

  it('si la escala cambió en la base, avisa y no aplica nada', async () => {
    grupos = [condicion(900)]
    preciosEnBase.clear()
    mutateAsync.mockClear(); notifyWarning.mockClear()
    gruposRefetch.mockResolvedValueOnce({ data: [condicion(950)] })
    await confirmar()

    const aviso = await screen.findByRole('alert')
    expect(aviso.textContent).toMatch(/Cambiaron las escalas mayoristas/)
    expect(aviso.textContent).toMatch(/No se aplicó nada/)
    expect(mutateAsync).not.toHaveBeenCalled()
    expect(notifyWarning).toHaveBeenCalledWith(expect.stringMatching(/condiciones mayoristas/))
  })

  it('si no cambió, aplica con las escalas', async () => {
    grupos = [condicion(900)]
    preciosEnBase.clear()
    mutateAsync.mockClear()
    await confirmar()

    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    expect(mutateAsync.mock.calls[0][0].escalas).toHaveLength(1)
  })

  it('si no se puede releer la condición, no aplica y lo dice', async () => {
    grupos = [condicion(900)]
    preciosEnBase.clear()
    mutateAsync.mockClear(); notifyError.mockClear()
    gruposRefetch.mockRejectedValueOnce(new Error('red'))
    await confirmar()

    await waitFor(() => expect(notifyError).toHaveBeenCalledWith(expect.stringMatching(/condiciones mayoristas actuales/)))
    expect(mutateAsync).not.toHaveBeenCalled()
  })
})
