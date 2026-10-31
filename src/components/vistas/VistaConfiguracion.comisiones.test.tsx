/**
 * Formulario de la comisión por defecto (#1320): el % lo cambia sólo el admin
 * —el encargado lo ve y no lo edita, tampoco el suyo— y el aviso de que rige
 * desde el mes en curso.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
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
    ...over,
  }
}

describe('VistaConfiguracion — comisión por defecto', () => {
  it('el admin la edita y guarda los dos porcentajes', async () => {
    const onGuardarComisiones = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarComisiones })} />)
    const prev = screen.getByLabelText('Preventistas')
    expect(prev).toBeEnabled()
    await userEvent.clear(prev)
    await userEvent.type(prev, '3')
    await userEvent.click(screen.getByRole('button', { name: 'Guardar comisiones' }))
    expect(onGuardarComisiones).toHaveBeenCalledWith(3, 0)
  })

  it('sin permiso (no admin) los inputs y el botón quedan deshabilitados y lo dice', () => {
    render(<VistaConfiguracion {...props({ puedeEditarComisiones: false })} />)
    expect(screen.getByLabelText('Preventistas')).toBeDisabled()
    expect(screen.getByLabelText('Resto (admin, encargado)')).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Guardar comisiones' })).toBeDisabled()
    expect(screen.getByText('Solo un admin puede cambiarlo.')).toBeInTheDocument()
  })

  it('avisa que un cambio rige desde el mes en curso y no toca los meses cerrados', () => {
    render(<VistaConfiguracion {...props()} />)
    expect(screen.getByText(/rige desde el 1° del mes en curso/)).toBeInTheDocument()
  })
})
