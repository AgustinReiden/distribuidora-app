/**
 * El desplegable de "Reglas de comisión" tuvo dos bugs encadenados. El primero:
 * salía de un padrón filtrado por `rol = 'preventista'`, así que a un admin o a
 * un encargado no había forma de asignarle un %. El segundo, al arreglar mal el
 * primero: pasó a salir de quien vendió EN EL PERÍODO CONSULTADO, así que la
 * lista cambiaba al cambiar el rango de fechas y un admin sin ventas seguía sin
 * aparecer.
 *
 * Ahora el piso es el padrón de quienes PUEDEN vender. La regla de armado vive
 * en `vendedoresElegibles` y tiene sus propios tests; acá se prueba el cableado
 * del container montando el modal de verdad y mirando el `<select>`, que es lo
 * que estaba roto.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ComisionesResultado } from '../../hooks/queries/useComisionesQuery'

const mockCalcular = vi.fn()
const mockPadron = vi.fn()

vi.mock('../../hooks/queries', () => ({
  useCalcularComisionesQuery: () => mockCalcular(),
  useVendedoresComisionablesQuery: () => mockPadron(),
  useComisionReglasQuery: () => ({ data: [], isLoading: false }),
  useGuardarComisionReglaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useDesactivarComisionReglaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: true }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn() }),
}))

// La vista no es lo que se prueba acá: sólo hace falta el botón que abre el modal.
vi.mock('../vistas/VistaComisiones', () => ({
  default: ({ onAbrirReglas }: { onAbrirReglas?: () => void }) => (
    <button type="button" onClick={onAbrirReglas}>Reglas de comisión</button>
  ),
}))

import ComisionesContainer from './ComisionesContainer'

/** Vendedor tal como lo devuelve el RPC: sin rol, porque el cálculo no lo mira. */
function vendedor(id: string, nombre: string, base: number) {
  return {
    id,
    nombre,
    email: `${id}@x.com`,
    base,
    comision: base * 0.02,
    items: 1,
    items_sin_desglose: 0,
    base_sin_desglose: 0,
    por_origen: [],
  }
}

function resultadoCon(preventistas: ComisionesResultado['preventistas']): ComisionesResultado {
  return {
    desde: '2026-01-01',
    hasta: '2026-09-07',
    comision_default: 2,
    preventistas,
    totales: { base: 0, comision: 0, items: 0, items_sin_desglose: 0, base_sin_desglose: 0 },
  }
}

/**
 * El modal se carga con `lazyWithReload`, así que la PRIMERA prueba del archivo
 * paga el `import()` dinámico y las demás lo toman del caché del módulo. Con el
 * millisegundo por defecto de `findBy` eso da un test que pasa solo o en
 * caliente y cae en frío o con la máquina cargada: verde cinco corridas
 * seguidas y rojo en el pre-commit. El timeout largo es por la carga del
 * chunk, no por la aserción.
 */
async function abrirReglas() {
  const user = userEvent.setup()
  render(<ComisionesContainer />)
  await user.click(await screen.findByRole('button', { name: 'Reglas de comisión' }))
  return screen.findByRole('combobox', { name: 'Vendedor' }, { timeout: 15000 })
}

describe('ComisionesContainer › desplegable de reglas', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockPadron.mockReturnValue({ data: [] })
  })

  it('un admin y un encargado que vendieron aparecen en el desplegable', async () => {
    // Los dos casos reales: Jony es encargado y es el que más comisión
    // acumula; ninguno de los dos tiene rol 'preventista'.
    mockCalcular.mockReturnValue({
      data: resultadoCon([
        vendedor('u-encargado', 'Jony', 361000),
        vendedor('u-admin', 'Agustin', 39000),
      ]),
      isLoading: false,
      error: null,
    })

    const select = await abrirReglas()

    expect(within(select).getByRole('option', { name: 'Jony' })).toBeInTheDocument()
    expect(within(select).getByRole('option', { name: 'Agustin' })).toBeInTheDocument()
  })

  it('incluye al preventista del padrón que todavía no vendió en el período', async () => {
    mockCalcular.mockReturnValue({
      data: resultadoCon([vendedor('u-admin', 'Agustin', 39000)]),
      isLoading: false,
      error: null,
    })
    mockPadron.mockReturnValue({
      data: [{ id: 'u-prev', nombre: 'Nuevo Preventista', email: 'np@x.com' }],
    })

    const select = await abrirReglas()

    expect(within(select).getByRole('option', { name: 'Nuevo Preventista' })).toBeInTheDocument()
    expect(within(select).getByRole('option', { name: 'Agustin' })).toBeInTheDocument()
  })

  it('no duplica a quien está en las dos fuentes', async () => {
    mockCalcular.mockReturnValue({
      data: resultadoCon([vendedor('u-prev', 'Ana', 1000)]),
      isLoading: false,
      error: null,
    })
    mockPadron.mockReturnValue({ data: [{ id: 'u-prev', nombre: 'Ana', email: 'ana@x.com' }] })

    const select = await abrirReglas()

    expect(within(select).getAllByRole('option', { name: 'Ana' })).toHaveLength(1)
  })

  it('un admin que NO vendió en el período aparece igual en el desplegable', async () => {
    // Es el bug que arregla este cambio: antes la fuente era quien vendió en el
    // período, así que Julio —2 pedidos en todo el año— aparecía o desaparecía
    // según el mes que estuvieras mirando.
    mockCalcular.mockReturnValue({
      data: resultadoCon([vendedor('u-vendio', 'Marcelo', 33000)]),
      isLoading: false,
      error: null,
    })
    mockPadron.mockReturnValue({
      data: [
        { id: 'u-julio', nombre: 'Julio', email: 'julio@x.com' },
        { id: 'u-vendio', nombre: 'Marcelo', email: 'm@x.com' },
      ],
    })

    const select = await abrirReglas()

    expect(within(select).getByRole('option', { name: 'Julio' })).toBeInTheDocument()
  })

  it('rescata a quien vendió pero ya no está en el padrón', async () => {
    // Christian: preventista inactivo con $804.249 acumulados. Sale del padrón
    // por `activo = false` y hay que poder editarle la regla igual.
    mockCalcular.mockReturnValue({
      data: resultadoCon([vendedor('u-christian', 'Christian', 40212490)]),
      isLoading: false,
      error: null,
    })
    mockPadron.mockReturnValue({ data: [{ id: 'u-otro', nombre: 'Ana', email: 'a@x.com' }] })

    const select = await abrirReglas()

    expect(within(select).getByRole('option', { name: 'Christian' })).toBeInTheDocument()
  })

  it('mantiene la opción «Todos» para la regla general', async () => {
    mockCalcular.mockReturnValue({
      data: resultadoCon([vendedor('u1', 'Ana', 1000)]),
      isLoading: false,
      error: null,
    })

    const select = await abrirReglas()

    expect(within(select).getByRole('option', { name: 'Todos' })).toBeInTheDocument()
  })

  it('ordena por nombre y no por monto vendido', async () => {
    mockCalcular.mockReturnValue({
      data: resultadoCon([
        vendedor('u1', 'Zulema', 500000),
        vendedor('u2', 'Ana', 1000),
      ]),
      isLoading: false,
      error: null,
    })

    const select = await abrirReglas()
    const nombres = within(select)
      .getAllByRole('option')
      .map(o => o.textContent)

    expect(nombres).toEqual(['Todos', 'Ana', 'Zulema'])
  })
})
