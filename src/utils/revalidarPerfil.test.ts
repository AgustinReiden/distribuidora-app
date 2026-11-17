import { describe, it, expect, vi } from 'vitest'
import { EVENTO_REVALIDAR_PERFIL, esMotivoDeUsuarioDesactivado, pedirRevalidacionDelPerfil } from './revalidarPerfil'

describe('esMotivoDeUsuarioDesactivado (S3)', () => {
  it('reconoce los textos que mandan las RPC de producción', () => {
    expect(esMotivoDeUsuarioDesactivado('Usuario desactivado')).toBe(true)
    // generar_codigo_vinculacion_bot
    expect(esMotivoDeUsuarioDesactivado('Tu usuario está desactivado.')).toBe(true)
    expect(esMotivoDeUsuarioDesactivado('{"code":"P0001","message":"Tu usuario esta desactivado."}')).toBe(true)
  })

  it('no confunde otros rechazos', () => {
    expect(esMotivoDeUsuarioDesactivado('Stock insuficiente')).toBe(false)
    expect(esMotivoDeUsuarioDesactivado('Cliente desactivado')).toBe(false)
    expect(esMotivoDeUsuarioDesactivado(undefined)).toBe(false)
    expect(esMotivoDeUsuarioDesactivado(null)).toBe(false)
  })
})

describe('pedirRevalidacionDelPerfil', () => {
  it('emite el evento que escucha useAuth', () => {
    const escucha = vi.fn()
    window.addEventListener(EVENTO_REVALIDAR_PERFIL, escucha)
    pedirRevalidacionDelPerfil()
    window.removeEventListener(EVENTO_REVALIDAR_PERFIL, escucha)
    expect(escucha).toHaveBeenCalledTimes(1)
  })
})
