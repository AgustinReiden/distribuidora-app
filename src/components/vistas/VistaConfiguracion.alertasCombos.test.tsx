/**
 * Formulario de los topes de las alertas de combos (#1194): los dos topes
 * viajan juntos, el rango es 0 a 100 (como el CHECK y la RPC) y sólo el admin
 * los cambia.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaConfiguracion, { type VistaConfiguracionProps } from './VistaConfiguracion'

function props(over: Partial<VistaConfiguracionProps> = {}): VistaConfiguracionProps {
  return {
    montoMinimoActual: 0,
    cargando: false,
    guardando: false,
    impacto: undefined,
    impactoCargando: false,
    onMontoTipeado: vi.fn(),
    onGuardar: vi.fn(),
    nombreSucursal: 'Tucumán',
    comisionPctPreventista: 2,
    comisionPctOtros: 0,
    guardandoComisiones: false,
    onGuardarComisiones: vi.fn(),
    puedeEditarComisiones: true,
    diasAlertaVencimiento: 60,
    diasCriticoVencimiento: 15,
    guardandoAlertas: false,
    onGuardarAlertas: vi.fn(),
    mostrarSinStock: true,
    guardandoMostrarSinStock: false,
    onGuardarMostrarSinStock: vi.fn(),
    ventanaPrecioAnteriorHoras: 24,
    puedeEditarVentana: true,
    guardandoVentana: false,
    onGuardarVentana: vi.fn(),
    comboMargenMinimoPct: 10,
    comboDescuentoMaximoPct: 30,
    puedeEditarAlertasCombos: true,
    guardandoAlertasCombos: false,
    onGuardarAlertasCombos: vi.fn(),
    ...over,
  }
}

function formCombos() {
  const margen = screen.getByLabelText('Margen mínimo') as HTMLInputElement
  const descuento = screen.getByLabelText('Descuento máximo') as HTMLInputElement
  const form = margen.closest('form') as HTMLFormElement
  return { margen, descuento, boton: within(form).getByRole('button', { name: 'Guardar' }) }
}

describe('VistaConfiguracion — alertas de combos', () => {
  it('arranca con los topes vigentes y guarda los dos juntos', async () => {
    const p = props()
    render(<VistaConfiguracion {...p} />)
    const { margen, descuento, boton } = formCombos()
    expect(margen.value).toBe('10')
    expect(descuento.value).toBe('30')
    expect(boton).toBeDisabled()

    await userEvent.clear(margen)
    await userEvent.type(margen, '12,5')
    await userEvent.click(boton)
    expect(p.onGuardarAlertasCombos).toHaveBeenCalledWith(12.5, 30)
  })

  it('fuera de 0 a 100 avisa y no deja guardar', async () => {
    render(<VistaConfiguracion {...props()} />)
    const { descuento, boton } = formCombos()
    await userEvent.clear(descuento)
    await userEvent.type(descuento, '120')
    expect(screen.getByText('Los dos topes van de 0 a 100%.')).toBeInTheDocument()
    expect(boton).toBeDisabled()
  })

  it('quien no es admin los ve en sólo lectura', () => {
    render(<VistaConfiguracion {...props({ puedeEditarAlertasCombos: false })} />)
    expect(formCombos().margen).toBeDisabled()
    expect(screen.getByText('Solo un admin puede cambiarlas.')).toBeInTheDocument()
  })

  it('sin handler no se muestra', () => {
    render(<VistaConfiguracion {...props({ onGuardarAlertasCombos: undefined })} />)
    expect(screen.queryByText('Alertas de combos')).not.toBeInTheDocument()
  })
})
