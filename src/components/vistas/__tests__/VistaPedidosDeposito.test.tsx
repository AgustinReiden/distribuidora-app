/**
 * Vista de depósito (#782): hojas de ruta armadas con lo que hay que cargar,
 * paradas en orden y, aparte, los pedidos sin ruta. Sólo lectura y sin plata.
 */
import type { ComponentProps } from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaPedidosDeposito from '../VistaPedidosDeposito'
import { normalizarHojasDeRuta } from '../../../utils/hojasDeRutaDeposito'

const item = (id: number, nombre: string, cantidad: number, extra: Record<string, unknown> = {}) => ({
  id, producto_id: id, cantidad, es_bonificacion: false, descripcion_regalo: null, unidades_por_bloque_al_crear: null,
  producto: { id, nombre, codigo: String(id), categoria: 'GASEOSAS', subcategoria_id: null, unidades_de_venta_por_fardo: null, etiqueta_bulto: null },
  promocion: null,
  ...extra,
})

const pedido = (id: number, cliente: string, items: unknown[], extra: Record<string, unknown> = {}) => ({
  id, estado: 'asignado', canal: 'app', fecha: '2026-10-07', fecha_entrega_programada: null,
  created_at: '2026-10-07T12:00:00Z', notas: null,
  cliente: { id: id * 10, nombre_fantasia: cliente, razon_social: null, direccion: `Calle ${id}`, aclaracion_direccion: null, telefono: null, zona: null, horarios_atencion: null },
  items, cambio: null,
  ...extra,
})

const datos = normalizarHojasDeRuta({
  fecha: '2026-10-08',
  rutas: [{
    recorrido_id: 77, estado: 'en_curso', transportista: { id: 'u-1', nombre: 'Rober' },
    paradas: [
      { ...pedido(1, 'Kiosco Lola', [item(10, 'Manaos Cola 3L', 6), item(11, 'Placer Anana', 2)], { notas: 'Separar en dos bultos' }), orden_entrega: 1 },
      { ...pedido(2, 'Almacén Pepe', [item(10, 'Manaos Cola 3L', 4)]), orden_entrega: 2 },
      // Cancelado en la ruta: se ve como parada, pero no se carga.
      { ...pedido(3, 'Despensa Cancelada', [item(10, 'Manaos Cola 3L', 100)], { estado: 'cancelado' }), orden_entrega: 3 },
    ],
  }],
  sin_ruta: [pedido(9, 'Super Nuevo', [item(12, 'Agua 2L', 3)], { estado: 'pendiente' })],
  subrubros: {},
})

function renderVista(props: Partial<ComponentProps<typeof VistaPedidosDeposito>> = {}) {
  const onCambiarFecha = vi.fn()
  const onDescargarManifiesto = vi.fn()
  render(
    <VistaPedidosDeposito
      datos={datos}
      cargando={false}
      error={null}
      onCambiarFecha={onCambiarFecha}
      onDescargarManifiesto={onDescargarManifiesto}
      onReintentar={vi.fn()}
      {...props}
    />,
  )
  return { onCambiarFecha, onDescargarManifiesto }
}

describe('VistaPedidosDeposito', () => {
  it('muestra cada hoja de ruta con su chofer y el total a cargar, sin contar lo cancelado', () => {
    renderVista()
    const ruta = screen.getByRole('region', { name: /Rober/ })
    const carga = within(ruta).getByRole('list', { name: /para cargar/i })
    // 6 + 4 de la misma Cola; los 100 del pedido cancelado no suben al camión.
    expect(within(carga).getByText('10x')).toBeInTheDocument()
    expect(within(carga).getByText('Manaos Cola 3L')).toBeInTheDocument()
    expect(within(carga).getByText('2x')).toBeInTheDocument()
  })

  it('lista las paradas en orden con cliente, dirección, notas y productos', () => {
    renderVista()
    const paradas = screen.getByRole('list', { name: /paradas de Rober/i })
    const items = within(paradas).getAllByRole('listitem').filter(li => li.parentElement === paradas)
    expect(items.map(li => within(li).getByRole('heading').textContent)).toEqual([
      expect.stringContaining('Kiosco Lola'),
      expect.stringContaining('Almacén Pepe'),
      expect.stringContaining('Despensa Cancelada'),
    ])
    expect(within(items[0]).getByText('Calle 1')).toBeInTheDocument()
    expect(within(items[0]).getByText('Separar en dos bultos')).toBeInTheDocument()
    expect(within(items[0]).getByText('6x Manaos Cola 3L')).toBeInTheDocument()
    expect(within(items[2]).getByText('Cancelado')).toBeInTheDocument()
  })

  it('muestra aparte los pedidos que todavía no están en ninguna ruta', () => {
    renderVista()
    const sinRuta = screen.getByRole('region', { name: /todavía sin ruta/i })
    expect(within(sinRuta).getByText(/Super Nuevo/)).toBeInTheDocument()
    expect(within(sinRuta).getByText('3x Agua 2L')).toBeInTheDocument()
  })

  it('no muestra ningún monto', () => {
    const { container } = render(
      <VistaPedidosDeposito datos={datos} cargando={false} error={null}
        onCambiarFecha={vi.fn()} onDescargarManifiesto={vi.fn()} onReintentar={vi.fn()} />,
    )
    expect(container.textContent).not.toMatch(/\$/)
    expect(container.textContent).not.toMatch(/total|pagad|saldo|precio|deuda|cobrar/i)
  })

  it('no ofrece ninguna acción sobre el pedido: sólo moverse de fecha y bajar el manifiesto', () => {
    renderVista()
    const nombres = screen.getAllByRole('button').map(b => b.getAttribute('aria-label') || b.textContent || '')
    for (const n of nombres) {
      expect(n).toMatch(/día anterior|día siguiente|próxima ruta|manifiesto/i)
    }
  })

  it('cambia de fecha con las flechas y con el selector', async () => {
    const { onCambiarFecha } = renderVista()
    await userEvent.click(screen.getByRole('button', { name: /día siguiente/i }))
    expect(onCambiarFecha).toHaveBeenLastCalledWith('2026-10-09')
    await userEvent.click(screen.getByRole('button', { name: /día anterior/i }))
    expect(onCambiarFecha).toHaveBeenLastCalledWith('2026-10-07')
    await userEvent.click(screen.getByRole('button', { name: /próxima ruta/i }))
    expect(onCambiarFecha).toHaveBeenLastCalledWith(null)
  })

  it('baja el manifiesto de la ruta que se pide, sin los pedidos cancelados', async () => {
    const { onDescargarManifiesto } = renderVista()
    await userEvent.click(screen.getByRole('button', { name: /manifiesto/i }))
    const [ruta, pedidos] = onDescargarManifiesto.mock.calls[0]
    expect(ruta.recorridoId).toBe('77')
    expect(pedidos.map((p: { id: string }) => p.id)).toEqual(['1', '2'])
  })

  it('sin rutas armadas para la fecha lo dice, y sigue mostrando lo pendiente', () => {
    renderVista({ datos: { ...datos, rutas: [] } })
    expect(screen.getByText(/no hay hojas de ruta armadas/i)).toBeInTheDocument()
    expect(screen.getByRole('region', { name: /todavía sin ruta/i })).toBeInTheDocument()
  })

  it('marca la parada no entregada', () => {
    const conNoEntregado = normalizarHojasDeRuta({
      fecha: '2026-10-07',
      rutas: [{ recorrido_id: 1, estado: 'en_curso', transportista: { id: 'u', nombre: 'Rober' },
        paradas: [{ ...pedido(5, 'Kiosco Cerrado', [item(10, 'Manaos Cola 3L', 1)], { estado: 'pendiente' }), orden_entrega: 1, estado_entrega: 'no_entregado' }] }],
      sin_ruta: [], subrubros: {},
    })
    renderVista({ datos: conNoEntregado })
    const paradas = screen.getByRole('list', { name: /paradas de Rober/i })
    expect(within(paradas).getByText('No entregado')).toBeInTheDocument()
  })

  it('el producto que se entrega en un cambio va en su rubro, no en "Sin rubro"', () => {
    const conCambio = normalizarHojasDeRuta({
      fecha: '2026-10-08',
      rutas: [{ recorrido_id: 1, estado: 'en_curso', transportista: { id: 'u', nombre: 'Rober' },
        paradas: [{ ...pedido(6, 'Kiosco Cambio', [], { canal: 'cambio', cambio: {
          producto_devuelto_nombre: 'Cola vencida', cantidad_devuelta: 2,
          producto_entregado_id: 55, producto_entregado_nombre: 'Cola Nueva 3L', cantidad_entregada: 2,
          producto_entregado_categoria: 'GASEOSAS', producto_entregado_subcategoria_id: null,
          observaciones: null, motivo: null,
        } }), orden_entrega: 1 }] }],
      sin_ruta: [], subrubros: {},
    })
    renderVista({ datos: conCambio })
    const carga = screen.getByRole('list', { name: /para cargar/i })
    expect(within(carga).getByText('GASEOSAS')).toBeInTheDocument()
    expect(within(carga).queryByText('Sin rubro')).not.toBeInTheDocument()
    expect(within(carga).getByText('Cola Nueva 3L')).toBeInTheDocument()
  })

  it('mientras carga otra fecha, las flechas siguen en pantalla con la fecha pedida', () => {
    renderVista({ datos: undefined, cargando: true, fecha: '2026-10-09' })
    expect(screen.getByLabelText(/fecha de la hoja de ruta/i)).toHaveValue('2026-10-09')
    expect(screen.getByRole('button', { name: /día siguiente/i })).toBeInTheDocument()
  })

  it('un error se muestra con reintentar', async () => {
    const onReintentar = vi.fn()
    renderVista({ datos: undefined, error: new Error('Sin conexión: no se pudieron cargar las hojas de ruta.'), onReintentar })
    expect(screen.getByRole('heading', { name: /no se pudieron cargar las hojas de ruta/i })).toBeInTheDocument()
    expect(screen.getByText(/^Sin conexión/)).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(onReintentar).toHaveBeenCalledTimes(1)
  })
})
