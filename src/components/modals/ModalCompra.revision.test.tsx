/**
 * La revisión de la factura escaneada, con muchos renglones: lo que reportó el
 * dueño al cargar una factura de doce renglones desde el teléfono.
 *
 * 1. Un renglón sin sugerencia abría el buscador vacío («Sin resultados»): sin
 *    tipear no se veía el catálogo para elegir.
 * 2. Los renglones ya agregados a la compra seguían arriba, mezclados con los
 *    que faltaban.
 * 3. Después de la primera tanda, los que faltaban se tienen que poder seguir
 *    agregando de a uno: elegir el producto ya lo agrega (no hay otro botón),
 *    con la lista del catálogo sin tipear o buscándolo.
 *
 * Se arma con el reducer de verdad (las líneas resueltas entran a `items`) y la
 * tabla de verdad; sólo se mockea la consulta de candidatos.
 */
import { describe, it, expect, vi } from 'vitest'
import { useReducer } from 'react'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB } from '../../types'
import type { LineaRevision } from '../../utils/revisionEscaneo'

vi.mock('../../hooks/queries/useEscaneoQuery', () => {
  const CANDIDATOS_VACIOS = { equivalencias: [], comprados: [] }
  return {
    CANDIDATOS_VACIOS,
    useCandidatosEscaneoQuery: () => ({ data: CANDIDATOS_VACIOS, isLoading: false }),
  }
})

import RevisionEscaneoTabla from './ModalCompra.revision'
import { compraReducer, initialState } from './ModalCompra.reducer'
import { RegistroIlegiblesContext, useRegistroIlegibles } from '../../hooks/useRegistroIlegibles'

/** Un catálogo genérico: ninguna palabra se parece a la del renglón raro. */
const CATALOGO = Array.from({ length: 12 }, (_, i) => ({
  id: `p${i + 1}`,
  nombre: `Producto Generico ${String.fromCharCode(65 + i)} 1L`,
  codigo: `COD${i + 1}`,
  stock: 0,
  impuestos_internos: 0,
  porcentaje_iva: 21,
  condicion_iva: 'gravado',
})) as unknown as ProductoDB[]

function linea(descripcion: string, match: Partial<LineaRevision['match']>, costo = 100): LineaRevision {
  return {
    impresa: { codigo: null, descripcion, cantidad: 2, costoUnitario: costo, bonificacion: 0, iva: 21 },
    match: { estado: 'sin_match', confianza: 0, motivo: '', alternativas: [], ...match },
    resolucion: { tipo: 'pendiente' },
    advertencias: [],
  }
}

/** Diez renglones con sugerencia de 90% y dos que el matcher no encontró. */
function lineasFactura(): LineaRevision[] {
  const sugeridas = CATALOGO.slice(0, 10).map((p, i) =>
    linea(`RENGLON SUGERIDO ${i + 1}`, { estado: 'sugerido', productoId: String(p.id), confianza: 0.9, motivo: 'Parecido' }, 100 + i))
  return [
    ...sugeridas,
    linea('ZZQX BEBIDA RARA 750', { motivo: 'Sin coincidencia' }, 500),
    linea('WWKY OTRO RARO 1000', { motivo: 'Sin coincidencia' }, 600),
  ]
}

/** Como en ModalCompra: el reducer, el registro de campos en rojo alrededor y la tabla. */
function Harness() {
  const [state, dispatch] = useReducer(compraReducer, {
    ...initialState,
    revisionEscaneo: { lineas: lineasFactura(), rutaArchivo: null, advertenciasGenerales: [], bonificacionPie: null },
  })
  const ilegibles = useRegistroIlegibles()
  return (
    <RegistroIlegiblesContext.Provider value={ilegibles.registro}>
      {state.revisionEscaneo && (
        <RevisionEscaneoTabla revision={state.revisionEscaneo} productos={CATALOGO} proveedorId={null}
                              dispatch={dispatch} renderCrear={null} obtenerUrlFactura={null} />
      )}
      <ul aria-label="Líneas de la compra">
        {state.items.map((it, i) => <li key={i}>{it.productoNombre}</li>)}
      </ul>
    </RegistroIlegiblesContext.Provider>
  )
}

const fila = (n: number) => screen.getByRole('row', { name: new RegExp(`^Línea ${n}:`) })
const itemsCompra = () => within(screen.getByRole('list', { name: 'Líneas de la compra' })).queryAllByRole('listitem')
/** Las filas de renglones, en el orden en que se ven (sin encabezados ni separadores). */
const filasEnOrden = () => screen.getAllByRole('row').filter(r => /^Línea \d+:/.test(r.getAttribute('aria-label') ?? ''))

async function aceptarTanda(user: ReturnType<typeof userEvent.setup>, n: number) {
  await user.click(screen.getByRole('button', { name: `Aceptar todas las sugeridas ≥ 85% (${n})` }))
  await user.click(within(screen.getByRole('alertdialog', { name: 'Aceptar sugeridas' })).getByRole('button', { name: `Sí, aceptar ${n}` }))
}

describe('revisión de una factura con muchos renglones', () => {
  it('1 · un renglón sin sugerencia muestra el catálogo al abrir el buscador, y filtra al escribir', async () => {
    const user = userEvent.setup()
    render(<Harness />)
    await user.click(within(fila(11)).getByRole('combobox', { name: 'Producto de la línea 11' }))
    const lista = screen.getByRole('listbox', { name: 'Producto de la línea 11' })
    expect(within(lista).queryByText('Sin resultados')).toBeNull()
    const opciones = within(lista).getAllByRole('option')
    expect(opciones.length).toBeGreaterThan(5)
    expect(opciones[0]).toHaveTextContent('Producto Generico A 1L')

    await user.keyboard('generico k')
    expect(within(lista).getAllByRole('option')[0]).toHaveTextContent('Producto Generico K 1L')
  })

  it('2 · los renglones ya agregados salen del camino: los que faltan quedan arriba', async () => {
    const user = userEvent.setup()
    render(<Harness />)
    await aceptarTanda(user, 10)
    expect(itemsCompra()).toHaveLength(10)

    const orden = filasEnOrden().map(r => r.getAttribute('aria-label'))
    expect(orden[0]).toMatch(/^Línea 11:/)
    expect(orden[1]).toMatch(/^Línea 12:/)
    // Las agregadas siguen a la vista (para cambiarlas), debajo y rotuladas.
    expect(screen.getByRole('rowheader', { name: /Ya agregadas a la compra \(10\)/ })).toBeInTheDocument()
    expect(within(fila(1)).getByText('✓ vinculado')).toBeInTheDocument()
  })

  it('3 · después de la primera tanda se siguen agregando los que faltan, de a uno', async () => {
    const user = userEvent.setup()
    render(<Harness />)
    await aceptarTanda(user, 10)

    // Sin tipear: se elige del catálogo y entra a la compra.
    await user.click(within(fila(11)).getByRole('combobox', { name: 'Producto de la línea 11' }))
    await user.click(within(screen.getByRole('listbox', { name: 'Producto de la línea 11' })).getByRole('option', { name: /Producto Generico K 1L/ }))
    expect(within(fila(11)).getByText('✓ vinculado')).toBeInTheDocument()
    expect(itemsCompra()).toHaveLength(11)

    // El último, tipeando.
    await user.click(within(fila(12)).getByRole('combobox', { name: 'Producto de la línea 12' }))
    await user.keyboard('generico l')
    await user.keyboard('{Enter}')
    expect(within(fila(12)).getByText('✓ vinculado')).toBeInTheDocument()
    expect(itemsCompra().map(li => li.textContent)).toContain('Producto Generico L 1L')
    expect(itemsCompra()).toHaveLength(12)
    expect(screen.getByRole('button', { name: /Terminar revisión/ })).toBeEnabled()
  })
})
