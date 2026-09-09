/**
 * Cambiar el factor de fracción de una promo con barras abiertas cierra bloques
 * y descuenta stock en la misma transacción del guardado (trigger de
 * renormalización, issue #535). Lo que se cubre acá es que el modal NO deja
 * guardar eso sin mostrarlo antes: el guardado silencioso era justamente el bug.
 *
 * La aritmética no se testea acá a propósito — vive en SQL (`bloques_a_cerrar`),
 * compartida entre el trigger que escribe y el preview que muestra. Una copia en
 * TS sería una tercera fuente, que es lo que esta issue vino a eliminar.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalPromocion from './ModalPromocion'
import type { ProductoDB } from '../../types'
import type { PromocionConDetalles } from '../../hooks/queries/usePromocionesQuery'

const preview = vi.hoisted(() => vi.fn())

vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePreviewCambioFactorQuery: (...args: unknown[]) => preview(...args),
}))

const PRODUCTOS = [
  { id: '81', nombre: 'MANAOS NARANJA 3L', precio: 100, stock: 40 },
  { id: '83', nombre: 'MANAOS GRANADINA 3L', precio: 100, stock: 40 },
] as unknown as ProductoDB[]

/** Promo 13 de prod: fracción, factor 6, contenedor 81. */
const PROMO = {
  id: '13',
  nombre: 'Promo Manaos 6 + 2 3L',
  tipo: 'bonificacion',
  activo: true,
  fecha_inicio: '2026-01-01',
  fecha_fin: null,
  producto_regalo_id: '81',
  ajuste_producto_id: '81',
  ajuste_automatico: true,
  regalo_mueve_stock: false,
  unidades_por_bloque: 6,
  stock_por_bloque: 1,
  descripcion_regalo: '1 botella Manaos 3L',
  usos_pendientes: 4,
  productos: [{ producto_id: '81' }],
  reglas: [
    { clave: 'cantidad_compra', valor: 6 },
    { clave: 'cantidad_bonificacion', valor: 2 },
  ],
} as unknown as PromocionConDetalles

function sinCambios() {
  return { data: [], isLoading: false }
}

function conCierre() {
  return {
    data: [
      {
        barra: 'sustituto',
        producto_regalo_id: '83',
        producto_regalo: 'MANAOS GRANADINA 3L',
        contenedor_id: '83',
        contenedor: 'MANAOS GRANADINA 3L',
        resto_actual: 4,
        bloques_a_cerrar: 2,
        unidades_de_stock: 2,
        resto_final: 0,
      },
    ],
    isLoading: false,
  }
}

function renderModal(onSave = vi.fn().mockResolvedValue({ success: true })) {
  render(
    <ModalPromocion promocion={PROMO} productos={PRODUCTOS} onSave={onSave} onClose={vi.fn()} />,
  )
  return { onSave }
}

const factorInput = () => screen.getByPlaceholderText('Ej: 6')
const actualizar = () => screen.getByRole('button', { name: 'Actualizar' })

async function cambiarFactorA(valor: string) {
  await userEvent.clear(factorInput())
  await userEvent.type(factorInput(), valor)
  await userEvent.click(actualizar())
}

describe('ModalPromocion · cambio del factor de fracción', () => {
  beforeEach(() => {
    preview.mockReset()
    preview.mockReturnValue(sinCambios())
  })

  it('guarda derecho cuando el factor no cambió', async () => {
    const { onSave } = renderModal()
    await userEvent.click(actualizar())
    expect(onSave).toHaveBeenCalledTimes(1)
    expect(screen.queryByText(/Cambiás el factor/)).not.toBeInTheDocument()
  })

  it('no guarda sin confirmar cuando el factor cambió', async () => {
    const { onSave } = renderModal()
    preview.mockReturnValue(conCierre())
    await cambiarFactorA('2')
    expect(await screen.findByText(/Cambiás el factor de 6 a 2/)).toBeInTheDocument()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('dice cuántas unidades de stock se van y de qué contenedor', async () => {
    renderModal()
    preview.mockReturnValue(conCierre())
    await cambiarFactorA('2')
    expect(await screen.findByText(/Se descuentan 2 unidades de stock/)).toBeInTheDocument()
    expect(screen.getByText(/MANAOS GRANADINA 3L: 4 pendientes/)).toBeInTheDocument()
  })

  it('avisa explícitamente cuando no se mueve stock', async () => {
    renderModal()
    preview.mockReturnValue({ data: [{ bloques_a_cerrar: 0 }], isLoading: false })
    await cambiarFactorA('12')
    expect(await screen.findByText(/No se mueve stock/)).toBeInTheDocument()
  })

  it('guarda recién al confirmar', async () => {
    const { onSave } = renderModal()
    preview.mockReturnValue(conCierre())
    await cambiarFactorA('2')
    await userEvent.click(await screen.findByRole('button', { name: 'Guardar igual' }))
    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0]).toMatchObject({ unidadesPorBloque: 2, stockPorBloque: 1 })
  })

  it('volver cancela el guardado y deja el modal editable', async () => {
    const { onSave } = renderModal()
    preview.mockReturnValue(conCierre())
    await cambiarFactorA('2')
    await userEvent.click(await screen.findByRole('button', { name: 'Volver' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(screen.queryByText(/Cambiás el factor/)).not.toBeInTheDocument()
    expect(factorInput()).toHaveValue(2)
  })

  it('no confirma nada mientras el preview está cargando', async () => {
    renderModal()
    preview.mockReturnValue({ data: undefined, isLoading: true })
    await cambiarFactorA('2')
    expect(await screen.findByText(/Calculando/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Guardar igual' })).toBeDisabled()
  })
})
