/**
 * Las etiquetas del panel de combos (#1194): "hoy equivale a X% de descuento,
 * margen Y%" y las alertas de margen, descuento, sin costo y "no conviene". El
 * margen sólo con costos a la vista (admin, encargado).
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import VistaCombos from '../VistaCombos'
import type { ComboAdmin } from '../../../hooks/queries/useCombosQuery'
import type { ProductoParaAlertas } from '../../../utils/comboAlertas'

const productos = new Map<string, ProductoParaAlertas>([
  ['10', { id: 10, nombre: 'Fernet', precio: 10000, precio_sin_iva: 10000, costo_promedio: 8000 }],
  ['11', { id: 11, nombre: 'Coca', precio: 2500, precio_sin_iva: 2500, costo_promedio: 1500 }],
])

function combo(precio: number, extra: Partial<ComboAdmin> = {}): ComboAdmin {
  return {
    id: '500',
    nombre: 'Fernet + Coca',
    activo: true,
    fechaInicio: '2026-01-01',
    fechaFin: null,
    precio,
    combinaEscalas: false,
    prioridad: 0,
    topeCombos: null,
    productoAMoverId: null,
    componentes: [{ cantidad: 1, sueltos: ['10'], categorias: [] }, { cantidad: 1, sueltos: ['11'], categorias: [] }],
    ...extra,
  }
}

function renderVista(combos: ComboAdmin[], verCostos = true, prods = productos) {
  render(
    <VistaCombos
      combos={combos}
      loading={false}
      productoNombres={new Map([['10', 'Fernet'], ['11', 'Coca']])}
      onNuevoCombo={vi.fn()}
      onEditarCombo={vi.fn()}
      onToggleActivo={vi.fn()}
      productos={prods}
      umbrales={{ margenMinimoPct: 10, descuentoMaximoPct: 30 }}
      verCostos={verCostos}
    />,
  )
}

describe('VistaCombos — alertas', () => {
  it('un combo sano dice su descuento y su margen, sin alertas', () => {
    renderVista([combo(11000)])
    const ev = screen.getByTestId('combo-evaluacion-500')
    expect(ev).toHaveTextContent('Hoy equivale a 12% de descuento, margen 13,6%')
    expect(ev.querySelectorAll('p')).toHaveLength(1)
  })

  it('margen bajo el tope', () => {
    renderVista([combo(9800)])
    expect(screen.getByText('Margen bajo: 3,1%, el tope es 10%')).toBeInTheDocument()
  })

  it('margen negativo', () => {
    renderVista([combo(9000)])
    expect(screen.getByText(/Margen negativo/)).toBeInTheDocument()
  })

  it('"no conviene"', () => {
    renderVista([combo(13000)])
    expect(screen.getByText(/No conviene: comprar por separado sale más barato/)).toBeInTheDocument()
  })

  it('sin costo de un componente avisa en vez de calcular el margen', () => {
    const sinCosto = new Map(productos)
    sinCosto.set('11', { id: 11, nombre: 'Coca', precio: 2500, precio_sin_iva: 2500 })
    renderVista([combo(11000)], true, sinCosto)
    expect(screen.getByText(/Sin costo cargado \(Coca\)/)).toBeInTheDocument()
    expect(screen.getByTestId('combo-evaluacion-500')).not.toHaveTextContent(/, margen \d/)
  })

  it('sin permiso para ver costos: ni margen ni "sin costo"', () => {
    renderVista([combo(9000)], false)
    const ev = screen.getByTestId('combo-evaluacion-500')
    expect(ev).toHaveTextContent('Hoy equivale a 28% de descuento')
    expect(ev).not.toHaveTextContent(/margen/i)
  })
})
