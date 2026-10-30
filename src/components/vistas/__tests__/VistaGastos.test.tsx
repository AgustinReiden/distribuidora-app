/**
 * VistaGastos (entrega 1): los gastos de un mes por mes imputado, con el total
 * por grupo arriba. Un gasto repartido aparece en cada mes que toca con su cuota.
 * Quién edita y anula lo decide el server; la vista sólo esconde los botones.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaGastos, { type VistaGastosProps } from '../VistaGastos'
import type { Gasto, RubroGasto, Vehiculo } from '../../../types/gastos'
import type { EmpleadoParaElegir } from '../../../types/personal'

const MES = '2026-10-01'

const RUBROS: RubroGasto[] = [
  { id: 2, nombre: 'Seguro', grupo: 'vehiculos', palabras_busqueda: null, pide_litros_km: false, reparto_sugerido_meses: 12, sugiere_mes_anterior: false, activo: true },
  { id: 3, nombre: 'Librería', grupo: 'administracion', palabras_busqueda: null, pide_litros_km: false, reparto_sugerido_meses: null, sugiere_mes_anterior: false, activo: true },
  { id: 9, nombre: 'Oficina central', grupo: 'administracion', palabras_busqueda: null, pide_litros_km: false, reparto_sugerido_meses: null, sugiere_mes_anterior: false, activo: true },
]
const VEHICULOS: Vehiculo[] = [{ id: 7, sucursal_id: 1, patente: 'AC456EF', descripcion: 'Partner', activo: true }]

const TRANSPORTISTAS = [{ id: 'tr-1', nombre: 'Tito Transportista' }]

const gasto = (g: Partial<Gasto> & Pick<Gasto, 'id' | 'rubro_id' | 'monto_total'>): Gasto => {
  const rubro = RUBROS.find(r => r.id === g.rubro_id)!
  return {
    sucursal_id: 1, compartido: false, fecha: '2026-10-15', comprobante: 'ticket', comprobante_numero: null,
    alicuota_iva: null, iva: 0, percepcion_iva: 0, percepcion_iibb: 0, otros_impuestos: 0, neto: g.monto_total,
    costo: g.monto_total, vehiculo_id: null, litros: null, mes_imputado: MES, repartir_meses: 1, mes_fin: MES,
    rendicion_transportista_id: null, rendicion_fecha: null, empleado_id: null, origen_pago: 'oficina', observacion: null, creado_por: 'u-admin', anulado_at: null,
    created_at: '2026-10-15T10:00:00Z', rubro: { id: rubro.id, nombre: rubro.nombre, grupo: rubro.grupo },
    vehiculo: null, ...g,
  }
}

const LIBRERIA = gasto({ id: 1, rubro_id: 3, monto_total: 8500 })
const SEGURO = gasto({
  id: 2, rubro_id: 2, monto_total: 1320000, comprobante: 'recibo', repartir_meses: 12, mes_fin: '2027-09-01',
  vehiculo_id: 7, vehiculo: { id: 7, patente: 'AC456EF', descripcion: 'Partner' },
})
const COMPARTIDO_DE_OTRO = gasto({
  id: 3, rubro_id: 9, monto_total: 20000, compartido: true, creado_por: 'u-tucuman', observacion: 'Contador',
})

function renderVista(props: Partial<VistaGastosProps> = {}) {
  const handlers = {
    onCambiarMes: vi.fn(), onNuevoGasto: vi.fn(), onEditarGasto: vi.fn(), onAnularGasto: vi.fn(),
    onAbrirRubros: vi.fn(), onExportar: vi.fn(),
  }
  render(
    <VistaGastos
      mes={MES}
      gastos={[LIBRERIA, SEGURO]}
      rubros={RUBROS}
      vehiculos={VEHICULOS}
      transportistas={TRANSPORTISTAS}
      empleados={[]}
      rendicionesCerradas={new Set<string>()}
      loading={false}
      usuarioId="u-admin"
      esAdmin
      tieneTodasLasSucursales={false}
      sucursalActual={{ id: 1, nombre: 'Tucumán' }}
      {...handlers}
      {...props}
    />,
  )
  return { ...handlers, user: userEvent.setup() }
}

const total = (grupo: string) => screen.getByTestId(`total-${grupo}`)

describe('VistaGastos — encabezado y totales', () => {
  it('título, período, crumbs y acciones', () => {
    renderVista()

    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('Gastos de octubre 2026')
    expect(screen.getByText('ADMINISTRACIÓN')).toBeInTheDocument()
    expect(screen.getByText('TUCUMÁN')).toBeInTheDocument()
    expect(screen.getByText('2 GASTOS')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Nuevo gasto/ })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Exportar/ })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Rubros/ })).toBeInTheDocument()
  })

  it('el encargado no ve el botón de rubros', () => {
    renderVista({ esAdmin: false, onAbrirRubros: undefined })
    expect(screen.queryByRole('button', { name: /Rubros/ })).not.toBeInTheDocument()
  })

  it('totales del mes con cuotas: el seguro aporta una cuota, no el total', () => {
    renderVista()

    expect(total('vehiculos')).toHaveTextContent(/110\.000,00/)
    expect(total('administracion')).toHaveTextContent(/8\.500,00/)
    expect(total('todos')).toHaveTextContent(/118\.500,00/)
  })
})

describe('VistaGastos — filas', () => {
  it('el repartido dice cuota 1 de 12', () => {
    renderVista()
    expect(screen.getByText('cuota 1 de 12')).toBeInTheDocument()
  })

  it('cada fila muestra rubro, comprobante, vehículo y observación', () => {
    renderVista({ gastos: [LIBRERIA, SEGURO, COMPARTIDO_DE_OTRO] })

    const fila = screen.getByTestId('gasto-2')
    expect(fila).toHaveTextContent('Seguro')
    expect(fila).toHaveTextContent('Recibo')
    expect(fila).toHaveTextContent('AC456EF')
    expect(screen.getByTestId('gasto-3')).toHaveTextContent('Contador')
    expect(screen.getByTestId('gasto-3')).toHaveTextContent('Compartido')
  })

  it('sin gastos en el mes avisa', () => {
    renderVista({ gastos: [] })
    expect(screen.getByText(/No hay gastos/)).toBeInTheDocument()
  })
})

describe('VistaGastos — quién edita y anula', () => {
  it('admin de Taco Pozo ve el compartido de Tucumán sin lápiz ni anular', () => {
    renderVista({ gastos: [COMPARTIDO_DE_OTRO], usuarioId: 'u-tacopozo', tieneTodasLasSucursales: false })

    const fila = screen.getByTestId('gasto-3')
    expect(within(fila).queryByRole('button', { name: /Editar gasto/ })).not.toBeInTheDocument()
    expect(within(fila).queryByRole('button', { name: /Anular gasto/ })).not.toBeInTheDocument()
  })

  it('con todas las sucursales sí puede', () => {
    renderVista({ gastos: [COMPARTIDO_DE_OTRO], usuarioId: 'u-dueno', tieneTodasLasSucursales: true })

    const fila = screen.getByTestId('gasto-3')
    expect(within(fila).getByRole('button', { name: /Editar gasto/ })).toBeInTheDocument()
    expect(within(fila).getByRole('button', { name: /Anular gasto/ })).toBeInTheDocument()
  })

  it('el admin puede con el compartido que cargó él', () => {
    renderVista({ gastos: [COMPARTIDO_DE_OTRO], usuarioId: 'u-tucuman' })
    expect(within(screen.getByTestId('gasto-3')).getByRole('button', { name: /Editar gasto/ })).toBeInTheDocument()
  })

  it('el admin puede con cualquier gasto no compartido de su sucursal', () => {
    renderVista({ usuarioId: 'u-otro-admin' })
    expect(within(screen.getByTestId('gasto-1')).getByRole('button', { name: /Editar gasto/ })).toBeInTheDocument()
  })

  it('el encargado tiene lápiz y anular sólo en los suyos', () => {
    const suyo = gasto({ id: 5, rubro_id: 3, monto_total: 1000, creado_por: 'u-enc' })
    renderVista({ esAdmin: false, usuarioId: 'u-enc', gastos: [suyo, LIBRERIA] })

    expect(within(screen.getByTestId('gasto-5')).getByRole('button', { name: /Editar gasto/ })).toBeInTheDocument()
    expect(within(screen.getByTestId('gasto-5')).getByRole('button', { name: /Anular gasto/ })).toBeInTheDocument()
    expect(within(screen.getByTestId('gasto-1')).queryByRole('button', { name: /Editar gasto/ })).not.toBeInTheDocument()
    expect(within(screen.getByTestId('gasto-1')).queryByRole('button', { name: /Anular gasto/ })).not.toBeInTheDocument()
  })

  it('los botones llaman a editar y anular con el gasto', async () => {
    const { user, onEditarGasto, onAnularGasto } = renderVista()
    const fila = screen.getByTestId('gasto-1')

    await user.click(within(fila).getByRole('button', { name: /Editar gasto/ }))
    await user.click(within(fila).getByRole('button', { name: /Anular gasto/ }))

    expect(onEditarGasto).toHaveBeenCalledWith(LIBRERIA)
    expect(onAnularGasto).toHaveBeenCalledWith(LIBRERIA)
  })
})

describe('VistaGastos — filtros y navegación', () => {
  it('el filtro de grupo deja sólo Vehículos', async () => {
    const { user } = renderVista()
    await user.click(screen.getByRole('button', { name: 'Vehículos' }))

    expect(screen.getByTestId('gasto-2')).toBeInTheDocument()
    expect(screen.queryByTestId('gasto-1')).not.toBeInTheDocument()
    // Los totales de arriba siguen siendo los del mes.
    expect(total('todos')).toHaveTextContent(/118\.500,00/)
  })

  it('el admin filtra por compartidos', async () => {
    const { user } = renderVista({ gastos: [LIBRERIA, COMPARTIDO_DE_OTRO] })
    await user.click(screen.getByRole('button', { name: 'Compartidos' }))

    expect(screen.getByTestId('gasto-3')).toBeInTheDocument()
    expect(screen.queryByTestId('gasto-1')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'De Tucumán' }))
    expect(screen.queryByTestId('gasto-3')).not.toBeInTheDocument()
    expect(screen.getByTestId('gasto-1')).toBeInTheDocument()
  })

  it('el encargado no tiene el filtro de compartidos', () => {
    renderVista({ esAdmin: false })
    expect(screen.queryByRole('button', { name: 'Compartidos' })).not.toBeInTheDocument()
  })

  it('filtra por rubro con el buscador', async () => {
    const { user } = renderVista()
    await user.click(screen.getByLabelText('Filtrar por rubro'))
    await user.click(screen.getByRole('option', { name: 'Librería' }))

    expect(screen.getByTestId('gasto-1')).toBeInTheDocument()
    expect(screen.queryByTestId('gasto-2')).not.toBeInTheDocument()
  })

  it('filtra por vehículo con el buscador', async () => {
    const { user } = renderVista()
    await user.click(screen.getByLabelText('Filtrar por vehículo'))
    await user.click(screen.getByRole('option', { name: /AC456EF/ }))

    expect(screen.getByTestId('gasto-2')).toBeInTheDocument()
    expect(screen.queryByTestId('gasto-1')).not.toBeInTheDocument()
  })

  it('las flechas llaman a onCambiarMes con el mes anterior y el siguiente', async () => {
    const { user, onCambiarMes } = renderVista()
    await user.click(screen.getByRole('button', { name: 'Mes anterior' }))
    await user.click(screen.getByRole('button', { name: 'Mes siguiente' }))

    expect(onCambiarMes).toHaveBeenNthCalledWith(1, '2026-09-01')
    expect(onCambiarMes).toHaveBeenNthCalledWith(2, '2026-11-01')
  })

  it('Nuevo gasto y Exportar llaman a sus handlers', async () => {
    const { user, onNuevoGasto, onExportar } = renderVista()
    await user.click(screen.getByRole('button', { name: /Nuevo gasto/ }))
    await user.click(screen.getByRole('button', { name: /Exportar/ }))

    expect(onNuevoGasto).toHaveBeenCalledTimes(1)
    expect(onExportar).toHaveBeenCalledTimes(1)
  })
})

describe('VistaGastos — mes siguiente de un gasto repartido', () => {
  it('en diciembre muestra la cuota 3 de 12 de un seguro de octubre', () => {
    renderVista({ mes: '2026-12-01', gastos: [SEGURO] })
    expect(screen.getByText('cuota 3 de 12')).toBeInTheDocument()
  })
})

describe('VistaGastos — con qué plata se pagó', () => {
  const DE_RENDICION = gasto({
    id: 20, rubro_id: 3, monto_total: 8000, origen_pago: 'rendicion',
    rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-28',
  })

  it('un gasto de rendición dice "Rendición de Tito Transportista del 28/10"', () => {
    renderVista({ gastos: [LIBRERIA, DE_RENDICION] })

    expect(within(screen.getByTestId('gasto-20')).getByText('Rendición de Tito Transportista del 28/10')).toBeInTheDocument()
    expect(within(screen.getByTestId('gasto-1')).queryByText(/Rendición de/)).not.toBeInTheDocument()
  })

  it('si el transportista no está en la lista, dice "otro usuario"', () => {
    renderVista({ gastos: [DE_RENDICION], transportistas: [] })

    expect(screen.getByText('Rendición de otro usuario del 28/10')).toBeInTheDocument()
  })

  it('el filtro Rendiciones deja sólo esos, y La oficina sólo los otros', async () => {
    const { user } = renderVista({ gastos: [LIBRERIA, DE_RENDICION] })
    const grupo = screen.getByRole('group', { name: 'Con qué plata' })

    await user.click(within(grupo).getByRole('button', { name: 'Rendiciones' }))
    expect(screen.queryByTestId('gasto-1')).not.toBeInTheDocument()
    expect(screen.getByTestId('gasto-20')).toBeInTheDocument()

    await user.click(within(grupo).getByRole('button', { name: 'La oficina' }))
    expect(screen.getByTestId('gasto-1')).toBeInTheDocument()
    expect(screen.queryByTestId('gasto-20')).not.toBeInTheDocument()

    await user.click(within(grupo).getByRole('button', { name: 'Todas' }))
    expect(screen.getByTestId('gasto-1')).toBeInTheDocument()
    expect(screen.getByTestId('gasto-20')).toBeInTheDocument()
  })

  it('una rendición cerrada: sin lápiz ni anular, con "Se cambia desde «Editar cierre»"', () => {
    renderVista({ gastos: [DE_RENDICION], rendicionesCerradas: new Set(['tr-1|2026-10-28']) })

    const fila = screen.getByTestId('gasto-20')
    expect(within(fila).queryByRole('button', { name: /Editar gasto/ })).not.toBeInTheDocument()
    expect(within(fila).queryByRole('button', { name: /Anular gasto/ })).not.toBeInTheDocument()
    expect(within(fila).getByText('Se cambia desde «Editar cierre»')).toBeInTheDocument()
  })

  it('con la clave fuera del Set (rendición abierta) el lápiz está', () => {
    renderVista({ gastos: [DE_RENDICION], rendicionesCerradas: new Set(['tr-1|2026-10-27']) })

    const fila = screen.getByTestId('gasto-20')
    expect(within(fila).getByRole('button', { name: /Editar gasto/ })).toBeInTheDocument()
    expect(within(fila).getByRole('button', { name: /Anular gasto/ })).toBeInTheDocument()
    expect(within(fila).queryByText(/Editar cierre/)).not.toBeInTheDocument()
  })
})

describe('VistaGastos — un empleado pagó con su plata', () => {
  const EMPLEADOS: EmpleadoParaElegir[] = [
    { id: 4, nombre: 'Martín Sosa', usuario_id: 'u-mar', vehiculo_id: null, activo: true },
    { id: 5, nombre: 'Laura Paz', usuario_id: 'u-lau', vehiculo_id: null, activo: true },
  ]
  const DE_MARTIN = gasto({ id: 30, rubro_id: 3, monto_total: 3000, origen_pago: 'empleado', empleado_id: 4 })
  const DE_LAURA = gasto({ id: 31, rubro_id: 3, monto_total: 4000, origen_pago: 'empleado', empleado_id: 5 })

  it('dice "Lo pagó Martín Sosa con su plata"', () => {
    renderVista({ gastos: [LIBRERIA, DE_MARTIN], empleados: EMPLEADOS })

    expect(within(screen.getByTestId('gasto-30')).getByText('Lo pagó Martín Sosa con su plata')).toBeInTheDocument()
    expect(within(screen.getByTestId('gasto-1')).queryByText(/Lo pagó/)).not.toBeInTheDocument()
  })

  it('si el empleado no está en la lista, dice "otro empleado"', () => {
    renderVista({ gastos: [DE_MARTIN], empleados: [] })
    expect(screen.getByText('Lo pagó otro empleado con su plata')).toBeInTheDocument()
  })

  it('el filtro Empleados deja sólo esos, y La oficina ya no los incluye', async () => {
    const { user } = renderVista({ gastos: [LIBRERIA, DE_MARTIN], empleados: EMPLEADOS })
    const grupo = screen.getByRole('group', { name: 'Con qué plata' })

    await user.click(within(grupo).getByRole('button', { name: 'Empleados' }))
    expect(screen.queryByTestId('gasto-1')).not.toBeInTheDocument()
    expect(screen.getByTestId('gasto-30')).toBeInTheDocument()

    await user.click(within(grupo).getByRole('button', { name: 'La oficina' }))
    expect(screen.getByTestId('gasto-1')).toBeInTheDocument()
    expect(screen.queryByTestId('gasto-30')).not.toBeInTheDocument()

    await user.click(within(grupo).getByRole('button', { name: 'Rendiciones' }))
    expect(screen.queryByTestId('gasto-30')).not.toBeInTheDocument()
  })

  it('el propio no tiene lápiz y sí anular, con la explicación', () => {
    renderVista({ gastos: [DE_MARTIN, DE_LAURA], empleados: EMPLEADOS, usuarioId: 'u-mar' })

    const propio = screen.getByTestId('gasto-30')
    expect(within(propio).queryByRole('button', { name: /Editar gasto/ })).not.toBeInTheDocument()
    expect(within(propio).getByRole('button', { name: /Anular gasto/ })).toBeInTheDocument()
    expect(within(propio).getByText('Lo pagaste vos: lo cambia otro admin o el encargado')).toBeInTheDocument()

    const ajeno = screen.getByTestId('gasto-31')
    expect(within(ajeno).getByRole('button', { name: /Editar gasto/ })).toBeInTheDocument()
    expect(within(ajeno).getByRole('button', { name: /Anular gasto/ })).toBeInTheDocument()
    expect(within(ajeno).queryByText(/Lo pagaste vos/)).not.toBeInTheDocument()
  })
})
