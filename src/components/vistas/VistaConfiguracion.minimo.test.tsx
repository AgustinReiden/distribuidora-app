/**
 * Formulario de la compra mínima con cargo de envío (mig 389, #1220): los tres
 * modos, qué campos muestra cada uno, y qué manda al guardar. Lo que no usa el
 * modo se guarda en 0 para que no reaparezca al cambiar de modo.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaConfiguracion, { type VistaConfiguracionProps } from './VistaConfiguracion'

function props(over: Partial<VistaConfiguracionProps> = {}): VistaConfiguracionProps {
  return {
    montoMinimoActual: 10000,
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
    ...over,
  }
}

function botonGuardarMinimo() {
  const form = (screen.getByLabelText('Compra mínima por pedido') as HTMLInputElement).closest('form') as HTMLFormElement
  return form.querySelector('button[type="submit"]') as HTMLButtonElement
}

describe('VistaConfiguracion — compra mínima y cargo de envío', () => {
  it('en bloquear no muestra los campos del envío', () => {
    render(<VistaConfiguracion {...props()} />)
    expect(screen.getByRole('radio', { name: /Bloquear/ })).toBeChecked()
    expect(screen.queryByLabelText('Cargo de envío')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Envío gratis desde')).not.toBeInTheDocument()
  })

  it('en cobrar envío muestra el cargo pero no el envío gratis', async () => {
    const user = userEvent.setup()
    render(<VistaConfiguracion {...props()} />)
    await user.click(screen.getByRole('radio', { name: /Cobrar envío/ }))
    expect(screen.getByLabelText('Cargo de envío')).toBeInTheDocument()
    expect(screen.queryByLabelText('Envío gratis desde')).not.toBeInTheDocument()
  })

  it('guarda el modo, el mínimo y el cargo; lo que el modo no usa va en 0', async () => {
    const user = userEvent.setup()
    const onGuardar = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardar, montoEnvioGratisActual: 99999 })} />)
    await user.click(screen.getByRole('radio', { name: /Cobrar envío/ }))
    fireEvent.change(screen.getByLabelText('Cargo de envío'), { target: { value: '1500' } })
    await user.click(botonGuardarMinimo())
    expect(onGuardar).toHaveBeenCalledWith({
      modo: 'cargo',
      montoMinimo: 10000,
      montoEnvioGratis: 0,
      cargoEnvio: 1500,
    })
  })

  it('en escalas pide el envío gratis y exige que supere al mínimo', async () => {
    const user = userEvent.setup()
    const onGuardar = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardar })} />)
    await user.click(screen.getByRole('radio', { name: /Por escalas/ }))
    fireEvent.change(screen.getByLabelText('Cargo de envío'), { target: { value: '1500' } })
    fireEvent.change(screen.getByLabelText('Envío gratis desde'), { target: { value: '10000' } })
    // No supera al mínimo: no se puede guardar.
    expect(botonGuardarMinimo()).toBeDisabled()

    fireEvent.change(screen.getByLabelText('Envío gratis desde'), { target: { value: '20000' } })
    await user.click(botonGuardarMinimo())
    expect(onGuardar).toHaveBeenCalledWith({
      modo: 'escalas',
      montoMinimo: 10000,
      montoEnvioGratis: 20000,
      cargoEnvio: 1500,
    })
  })

  it('refleja la política vigente que llega del servidor', () => {
    render(<VistaConfiguracion {...props({ modoMinimoActual: 'escalas', montoEnvioGratisActual: 30000, cargoEnvioActual: 2000 })} />)
    expect(screen.getByRole('radio', { name: /Por escalas/ })).toBeChecked()
    expect((screen.getByLabelText('Cargo de envío') as HTMLInputElement).value).toBe('2000')
    expect((screen.getByLabelText('Envío gratis desde') as HTMLInputElement).value).toBe('30000')
  })

  it('con la política sin cambios, Guardar queda deshabilitado', () => {
    render(<VistaConfiguracion {...props({ modoMinimoActual: 'cargo', cargoEnvioActual: 1500 })} />)
    expect(botonGuardarMinimo()).toBeDisabled()
  })
})
