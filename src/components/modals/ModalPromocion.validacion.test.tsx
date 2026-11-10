/**
 * Una promo "unidad entera" sin producto de regalo guardaba igual:
 * `guardar()` manda `productoRegaloId || null` y la columna cae en su default
 * de "primer producto del pedido" (baseline:4044), o sea que el regalo
 * termina siendo cualquier cosa. La rama 'fraccion' ya exigía sus campos
 * (ajusteProductoId, descripcionRegalo, unidadesPorBloque) antes de guardar;
 * a 'unidad_entera' le faltaba el equivalente para productoRegaloId.
 */
import { describe, it, expect, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalPromocion from './ModalPromocion'
import type { ProductoDB } from '../../types'

vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoPedidosAbiertosQuery: () => ({ data: 0 }),
  usePreviewCambioFactorQuery: () => ({ data: [], isLoading: false }),
}))

const PRODUCTOS = [
  { id: '1', nombre: 'PRODUCTO A', precio: 100, stock: 10 },
  { id: '2', nombre: 'PRODUCTO REGALO', precio: 50, stock: 10 },
] as unknown as ProductoDB[]

function renderModal(onSave = vi.fn().mockResolvedValue({ success: true })) {
  render(<ModalPromocion promocion={null} productos={PRODUCTOS} onSave={onSave} onClose={vi.fn()} />)
  return { onSave }
}

async function completarCamposBasicos() {
  await userEvent.type(screen.getByPlaceholderText('Ej: Promo Manaos 12+2'), 'Promo test')
  await userEvent.click(screen.getByText('PRODUCTO A'))
  await userEvent.type(screen.getByPlaceholderText('Ej: 12'), '10')
  await userEvent.type(screen.getByPlaceholderText('Ej: 2'), '2')
}

const crear = () => screen.getByRole('button', { name: 'Crear Promocion' })

describe('ModalPromocion · unidad entera exige producto de regalo', () => {
  it('no guarda sin producto de regalo', async () => {
    const { onSave } = renderModal()
    await completarCamposBasicos()
    await userEvent.click(crear())
    expect(await screen.findByText('Seleccioná el producto de regalo')).toBeInTheDocument()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('guarda cuando se elige el producto de regalo', async () => {
    const { onSave } = renderModal()
    await completarCamposBasicos()
    await userEvent.type(screen.getByPlaceholderText('Buscar producto de regalo...'), 'REGALO')
    await userEvent.click(await screen.findByRole('button', { name: /PRODUCTO REGALO/ }))
    await userEvent.click(crear())
    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0]).toMatchObject({ productoRegaloId: '2' })
  })
})

/**
 * #1515 (PRM-4): el server rechaza una promo con el fin antes del inicio y una regla que no es un
 * entero positivo (los CHECK promociones_fechas_en_orden y promocion_reglas_valor_entero). El modal lo
 * dice antes, con palabras, en vez de mostrar el mensaje crudo del CHECK. Antes, parseInt('2.5') daba 2
 * sin avisar.
 */
describe('ModalPromocion · las fechas en orden y las reglas enteras', () => {
  const fechas = () => document.querySelectorAll<HTMLInputElement>('input[type="date"]')

  it('no guarda con la fecha de fin antes de la de inicio', async () => {
    const { onSave } = renderModal()
    await completarCamposBasicos()
    fireEvent.change(fechas()[0], { target: { value: '2026-11-10' } })
    fireEvent.change(fechas()[1], { target: { value: '2026-11-09' } })
    await userEvent.click(crear())
    expect(await screen.findByText('La fecha de fin no puede ser anterior a la de inicio')).toBeInTheDocument()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('la fecha de fin igual a la de inicio vale', async () => {
    const { onSave } = renderModal()
    await completarCamposBasicos()
    fireEvent.change(fechas()[0], { target: { value: '2026-11-10' } })
    fireEvent.change(fechas()[1], { target: { value: '2026-11-10' } })
    await userEvent.type(screen.getByPlaceholderText('Buscar producto de regalo...'), 'REGALO')
    await userEvent.click(await screen.findByRole('button', { name: /PRODUCTO REGALO/ }))
    await userEvent.click(crear())
    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0]).toMatchObject({ fechaInicio: '2026-11-10', fechaFin: '2026-11-10' })
  })

  it('no guarda una cantidad de bonificación con decimales', async () => {
    const { onSave } = renderModal()
    await userEvent.type(screen.getByPlaceholderText('Ej: Promo Manaos 12+2'), 'Promo test')
    await userEvent.click(screen.getByText('PRODUCTO A'))
    await userEvent.type(screen.getByPlaceholderText('Ej: 12'), '10')
    await userEvent.type(screen.getByPlaceholderText('Ej: 2'), '2.5')
    await userEvent.click(crear())
    expect(
      await screen.findByText('Ingresa la cantidad de bonificacion (un número entero mayor a 0)'),
    ).toBeInTheDocument()
    expect(onSave).not.toHaveBeenCalled()
  })
})
