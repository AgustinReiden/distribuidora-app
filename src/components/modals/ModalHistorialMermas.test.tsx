/**
 * El modal se importa DIRECTO, no por ProductosContainer: allá se carga con
 * `lazyWithReload` y la primera prueba del archivo pagaría el `import()` del
 * chunk, que es el flake que se cazó en el PR #514.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mockCrearExcel = vi.fn()
const mockUseMermas = vi.fn()

vi.mock('../../utils/excel', () => ({
  createMultiSheetExcel: (hojas: unknown[], filename: string) => mockCrearExcel(hojas, filename),
}))

vi.mock('../../hooks/queries/useMermasQuery', () => ({
  useMermasQuery: (filtros: unknown) => mockUseMermas(filtros),
  LIMITE_MERMAS: 1000,
}))

// Período fijo: si no, el nombre del archivo depende del día en que corran los
// tests y la aserción exacta sería imposible.
vi.mock('../../utils/periodosReporte', () => ({
  presetsVentas: () => [
    { id: 'anio-2026', label: 'Año 2026', desde: '2026-01-01', hasta: '2026-09-07' },
    { id: 'mes-2026-09', label: 'Septiembre 2026 (en curso)', desde: '2026-09-01', hasta: '2026-09-07' },
  ],
}))

import ModalHistorialMermas from './ModalHistorialMermas'

const productos = [
  { id: 'p1', nombre: 'Coca 2L', codigo: 'C2L', precio: 3000, costo_promedio: 1000, costo_real: 1200 },
  { id: 'p2', nombre: 'Agua 500', codigo: 'A500', precio: 800, costo_promedio: 300 },
  { id: 'p3', nombre: 'Sin costo', codigo: 'SC', precio: 100 },
]

const usuarios = [{ id: 'u1', nombre: 'Jony' }]

const mermas = [
  // Pérdida real con costo congelado.
  {
    id: 'm1', producto_id: 'p1', cantidad: 2, motivo: 'rotura', costo_unitario: 900,
    usuario_id: 'u1', stock_anterior: 10, stock_nuevo: 8,
    created_at: '2026-08-15T14:00:00Z', observaciones: 'Se cayó el pallet',
  },
  // Vieja: sin snapshot, se valúa al costo de hoy.
  {
    id: 'm2', producto_id: 'p2', cantidad: 5, motivo: 'vencimiento', costo_unitario: null,
    usuario_id: null, stock_anterior: 50, stock_nuevo: 45, created_at: '2026-05-10T14:00:00Z',
  },
  // Producto sin ningún costo cargado.
  {
    id: 'm3', producto_id: 'p3', cantidad: 1, motivo: 'otro', costo_unitario: null,
    usuario_id: 'u1', stock_anterior: 5, stock_nuevo: 4, created_at: '2026-08-20T14:00:00Z',
  },
  // Ajuste de promoción: NO es pérdida.
  {
    id: 'm4', producto_id: 'p1', cantidad: 10, motivo: 'promociones', costo_unitario: 900,
    usuario_id: 'u1', stock_anterior: 100, stock_nuevo: 90, created_at: '2026-08-21T14:00:00Z',
  },
  // Reversión: cantidad NEGATIVA.
  {
    id: 'm5', producto_id: 'p1', cantidad: -3, motivo: 'promociones_reversion', costo_unitario: 900,
    usuario_id: 'u1', stock_anterior: 90, stock_nuevo: 93, created_at: '2026-08-22T14:00:00Z',
  },
]

function renderModal(data = mermas) {
  mockUseMermas.mockReturnValue({ data, isLoading: false })
  return render(
    <ModalHistorialMermas
      productos={productos as never}
      usuarios={usuarios as never}
      onClose={vi.fn()}
    />,
  )
}

describe('ModalHistorialMermas', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe('el filtro de fecha va al servidor', () => {
    it('le pasa el rango del preset al hook, no filtra en el cliente', () => {
      renderModal()
      expect(mockUseMermas).toHaveBeenCalledWith({ desde: '2026-01-01', hasta: '2026-09-07' })
    })

    it('cambiar de período vuelve a consultar con el rango nuevo', async () => {
      const user = userEvent.setup()
      renderModal()

      await user.selectOptions(screen.getByLabelText(/Período/), 'mes-2026-09')

      expect(mockUseMermas).toHaveBeenLastCalledWith({ desde: '2026-09-01', hasta: '2026-09-07' })
    })
  })

  describe('los ajustes de promoción quedan fuera del total', () => {
    it('la pérdida a costo no los suma', () => {
      // 2*900 (rotura) + 5*300 (vencimiento, al costo de hoy) + 1*0 = 3.300.
      // Si sumara promociones (10*900) y la reversión (-3*900) daría 9.600.
      renderModal()
      expect(screen.getByText('$3.300,00')).toBeInTheDocument()
    })

    it('lo explica en pantalla en vez de esconderlos', () => {
      renderModal()
      expect(screen.getByText(/ajustes de promoción/i)).toBeInTheDocument()
      expect(screen.getByText(/contrapartida de un regalo/i)).toBeInTheDocument()
    })

    it('las unidades perdidas tampoco los cuentan', () => {
      // 2 + 5 + 1 = 8, no 15.
      renderModal()
      const resumen = screen.getByText('Unidades perdidas').closest('div') as HTMLElement
      expect(within(resumen).getByText('8')).toBeInTheDocument()
    })
  })

  describe('las tres marcas de calidad del dato', () => {
    it('marca la fila valuada al costo de hoy por no tener snapshot', () => {
      renderModal()
      expect(screen.getByText('Costo estimado al valor actual')).toBeInTheDocument()
      expect(screen.getByText(/anteriores a que se guardara el costo del momento/i)).toBeInTheDocument()
    })

    it('marca el producto sin costo cargado: $0 no es "no vale nada"', () => {
      renderModal()
      expect(screen.getByText('Sin costo cargado')).toBeInTheDocument()
      expect(screen.getByText(/no es que valgan \$0, es que no se sabe/i)).toBeInTheDocument()
    })

    it('aclara que el precio de venta es el de hoy', () => {
      renderModal()
      expect(screen.getByText(/la base no guarda a cuánto se vendía el día de la merma/i)).toBeInTheDocument()
    })
  })

  describe('los tres defectos de render', () => {
    it('una cantidad negativa no imprime el doble signo', () => {
      // Antes salía "--3": el signo ya venía en el número.
      renderModal()
      expect(screen.getByText('+3')).toBeInTheDocument()
      expect(screen.queryByText('--3')).not.toBeInTheDocument()
    })

    it('promociones_reversion tiene etiqueta, no sale el string crudo', () => {
      renderModal()
      expect(screen.getAllByText('Reversión de promoción').length).toBeGreaterThan(0)
      expect(screen.queryByText('promociones_reversion')).not.toBeInTheDocument()
    })

    it('muestra quién registró la merma', () => {
      // El prop `usuarios` nunca se pasaba: todas las filas decían
      // "Usuario desconocido".
      renderModal()
      expect(screen.getAllByText('Jony').length).toBeGreaterThan(0)
      expect(screen.queryByText('Usuario desconocido')).not.toBeInTheDocument()
    })

    it('una merma sin usuario dice que no está registrado, no que es desconocido', () => {
      renderModal()
      expect(screen.getByText('Sin registrar')).toBeInTheDocument()
    })
  })

  describe('export a Excel', () => {
    it('exporta dos hojas: el detalle y el resumen por motivo', async () => {
      const user = userEvent.setup()
      renderModal()

      await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }))

      expect(mockCrearExcel).toHaveBeenCalledTimes(1)
      const [hojas, nombreArchivo] = mockCrearExcel.mock.calls[0]

      expect(hojas.map((h: { name: string }) => h.name)).toEqual(['Detalle', 'Resumen por motivo'])
      expect(nombreArchivo).toBe('mermas-2026-01-01_a_2026-09-07')
    })

    it('el detalle lleva el costo, el precio y de dónde salió cada costo', async () => {
      const user = userEvent.setup()
      renderModal()

      await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }))
      const [hojas] = mockCrearExcel.mock.calls[0]

      expect(hojas[0].data[0]).toMatchObject({
        Producto: 'Coca 2L',
        Motivo: 'Rotura',
        Tipo: 'Pérdida',
        Cantidad: 2,
        'Costo unitario': 900,
        'Costo total': 1800,
        'Precio total (hoy)': 6000,
        'Origen del costo': 'Congelado al momento',
        Usuario: 'Jony',
      })
    })

    it('cada fila dice si su costo es estimado o si no hay costo', async () => {
      const user = userEvent.setup()
      renderModal()

      await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }))
      const [hojas] = mockCrearExcel.mock.calls[0]
      const porId = Object.fromEntries(
        hojas[0].data.map((f: Record<string, unknown>) => [f.Producto, f]),
      )

      expect(porId['Agua 500']['Origen del costo']).toBe('Estimado al valor actual')
      expect(porId['Sin costo']['Origen del costo']).toBe('Sin costo cargado')
    })

    it('marca los ajustes de promoción como tales en el detalle', async () => {
      const user = userEvent.setup()
      renderModal()

      await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }))
      const [hojas] = mockCrearExcel.mock.calls[0]
      const ajustes = hojas[0].data.filter((f: Record<string, unknown>) => f.Tipo === 'Ajuste de promoción')

      expect(ajustes).toHaveLength(2)
    })

    it('el resumen cierra con el total de pérdida y los ajustes aparte', async () => {
      const user = userEvent.setup()
      renderModal()

      await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }))
      const [hojas] = mockCrearExcel.mock.calls[0]
      const filas = hojas[1].data as Record<string, unknown>[]

      // Sin esto, el archivo sale del sistema y nadie puede saber por qué el
      // total no es la suma de la columna Costo.
      expect(filas.find(f => String(f.Motivo).startsWith('TOTAL PÉRDIDA'))).toMatchObject({
        Unidades: 8,
        Costo: 3300,
      })
      expect(filas.find(f => String(f.Motivo).startsWith('Ajustes de promoción'))).toMatchObject({
        Registros: 2,
        Costo: 6300, // 10*900 + (-3)*900
      })
    })

    it('no exporta si no hay filas', async () => {
      const user = userEvent.setup()
      renderModal([])

      const boton = screen.getByRole('button', { name: /Exportar a Excel/i })
      expect(boton).toBeDisabled()
      await user.click(boton)
      expect(mockCrearExcel).not.toHaveBeenCalled()
    })
  })

  describe('truncamiento', () => {
    it('avisa cuando el período llega al tope de filas', () => {
      const muchas = Array.from({ length: 1000 }, (_, i) => ({
        ...mermas[0], id: `x${i}`,
      }))
      renderModal(muchas)

      expect(screen.getByText(/se muestran los 1000 más recientes/i)).toBeInTheDocument()
    })

    it('no avisa cuando entran todas', () => {
      renderModal()
      expect(screen.queryByText(/más recientes/i)).not.toBeInTheDocument()
    })
  })
})
