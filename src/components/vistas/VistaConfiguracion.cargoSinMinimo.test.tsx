/**
 * catalogo-B6 (tanda 6, #1603): el modo «cobrar envío» con la compra mínima en 0 se guardaba y
 * nunca cobraba (`cargo_envio_pedido_puro`: mínimo 0 = sin umbral). El formulario no avisaba.
 * Ahora muestra un aviso (no bloquea: guardar sigue siendo posible, es una política válida).
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
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
    puedeEditarMinimo: true,
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
    ...over,
  }
}

const AVISO = /nunca cobra el cargo de envío/

describe('VistaConfiguracion · cobrar envío con el mínimo en 0 (catalogo-B6)', () => {
  it('avisa que con mínimo 0 y un cargo mayor que 0 el envío nunca se cobra', async () => {
    const user = userEvent.setup()
    render(<VistaConfiguracion {...props()} />)
    await user.click(screen.getByRole('radio', { name: /Cobrar envío/ }))
    expect(screen.queryByText(AVISO)).not.toBeInTheDocument()

    fireEvent.change(screen.getByLabelText('Cargo de envío'), { target: { value: '500' } })

    expect(await screen.findByText(AVISO)).toBeInTheDocument()
  })

  it('con un mínimo mayor que 0 no avisa', async () => {
    const user = userEvent.setup()
    render(<VistaConfiguracion {...props({ montoMinimoActual: 10000, modoMinimoActual: 'cargo', cargoEnvioActual: 500 })} />)
    expect(screen.getByLabelText('Cargo de envío')).toBeInTheDocument()
    expect(screen.queryByText(AVISO)).not.toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Cargo de envío'), { target: { value: '700' } })
    expect(screen.queryByText(AVISO)).not.toBeInTheDocument()
    await user.click(screen.getByRole('radio', { name: /Por escalas/ }))
    expect(screen.queryByText(AVISO)).not.toBeInTheDocument()
  })

  it('sin cargo (0) no avisa: no hay nada que cobrar', () => {
    render(<VistaConfiguracion {...props({ modoMinimoActual: 'cargo', cargoEnvioActual: 0 })} />)
    expect(screen.queryByText(AVISO)).not.toBeInTheDocument()
  })
})
