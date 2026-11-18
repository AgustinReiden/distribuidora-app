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

  // B20 (D17): un porcentaje no lleva miles; la tecla del punto es la coma decimal.
  it('el porcentaje tipeado «2.5» se ve «2,5» y se guarda 2,5; uno que no se entiende no se guarda', async () => {
    const onGuardarComisiones = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarComisiones })} />)
    const prev = screen.getByLabelText('Preventistas') as HTMLInputElement
    await userEvent.clear(prev)
    await userEvent.type(prev, '2.5')
    expect(prev.value).toBe('2,5')
    await userEvent.click(screen.getByRole('button', { name: 'Guardar comisiones' }))
    expect(onGuardarComisiones).toHaveBeenCalledWith(2.5, 0)

    // H7 de la segunda lente: tipeado, el segundo separador no entra (el campo sin miles filtra
    // como el de plata); pegado, queda en rojo y no se guarda.
    onGuardarComisiones.mockClear()
    await userEvent.clear(prev)
    await userEvent.type(prev, '2,5,')
    expect(prev.value).toBe('2,5')
    await userEvent.clear(prev)
    await userEvent.click(prev)
    await userEvent.paste('2,5,')
    expect(prev).toHaveAttribute('aria-invalid', 'true')
    await userEvent.click(screen.getByRole('button', { name: 'Guardar comisiones' }))
    expect(onGuardarComisiones).not.toHaveBeenCalled()
  })

  // B20 (D17): lo precargado se ve con coma decimal, como se tipea: con `String`, 2,5 se veía «2.5».
  it('el porcentaje guardado 2,5 se precarga «2,5»', () => {
    render(<VistaConfiguracion {...props({ comisionPctPreventista: 2.5 })} />)
    expect(screen.getByLabelText('Preventistas')).toHaveValue('2,5')
  })

  // B20 (D17): los días del aviso de vencimiento son enteros; los miles los pone el campo.
  it('los días del aviso: «1500» se ve «1.500», y «1.5» (una coma) no es un día', async () => {
    const onGuardarAlertas = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarAlertas })} />)
    const amarillo = screen.getByLabelText('Amarillo') as HTMLInputElement
    await userEvent.clear(amarillo)
    await userEvent.type(amarillo, '1500')
    expect(amarillo.value).toBe('1.500')
    expect(amarillo).not.toHaveAttribute('aria-invalid', 'true')
    await userEvent.clear(amarillo)
    await userEvent.type(amarillo, '1.5')
    expect(amarillo.value).toBe('1,5')
    expect(amarillo).toHaveAttribute('aria-invalid', 'true')
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
