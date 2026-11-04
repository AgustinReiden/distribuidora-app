import { Buffer } from 'node:buffer'
import { createHmac } from 'node:crypto'
import { describe, expect, it } from 'vitest'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { SUB_SIN_USUARIO, fallaDelControl, tokenAuthenticated } from '../../scripts/lib/sesionAuthenticated.mjs'

/**
 * El token con el que scripts/check-embeds.mjs prueba los selects como la app
 * (#1417). PostgREST lo acepta sólo si la firma es la HS256 del JWT secret y el
 * claim `role` es el rol de Postgres con el que va a correr la consulta.
 */
describe('tokenAuthenticated', () => {
  const secreto = 'secreto-de-mentira-para-el-test'
  const token: string = tokenAuthenticated(secreto, { ahora: 1_800_000_000, segundos: 300 })
  const [cabecera, cuerpo, firma] = token.split('.')
  const leer = (parte: string) => JSON.parse(Buffer.from(parte, 'base64url').toString('utf8'))

  it('es un JWT HS256 firmado con el secret', () => {
    expect(leer(cabecera)).toEqual({ alg: 'HS256', typ: 'JWT' })
    expect(firma).toBe(createHmac('sha256', secreto).update(`${cabecera}.${cuerpo}`).digest('base64url'))
    expect(firma).not.toBe(createHmac('sha256', 'otro').update(`${cabecera}.${cuerpo}`).digest('base64url'))
  })

  it('corre como authenticated, no es de ningún usuario y dura lo pedido', () => {
    expect(leer(cuerpo)).toEqual({
      iss: 'supabase',
      aud: 'authenticated',
      role: 'authenticated',
      sub: SUB_SIN_USUARIO,
      iat: 1_800_000_000,
      exp: 1_800_000_300,
    })
  })

  it('sin secret no firma nada', () => {
    expect(() => tokenAuthenticated('')).toThrow(/JWT secret/)
  })
})

// El control negativo de check-embeds: el costo de pedido_items, como authenticated,
// tiene que dar 42501. Si pasa, o si el token no entra, la sesión no prueba nada.
describe('fallaDelControl', () => {
  it('el 42501 es el control que mordió', () => {
    expect(fallaDelControl(403, { code: '42501', message: 'permission denied for table pedido_items' })).toBeNull()
  })

  it('una lectura que pasa es rojo: el token no corre como authenticated', () => {
    expect(fallaDelControl(200, [])).toMatch(/authenticated leyó pedido_items\.costo_unitario_al_crear/)
  })

  it('un token rechazado o cualquier otro error también es rojo', () => {
    expect(fallaDelControl(401, { code: 'PGRST301', message: 'JWSError' })).toMatch(/se esperaba 42501 y dio HTTP 401 PGRST301/)
    expect(fallaDelControl(500, null)).toMatch(/HTTP 500/)
  })
})
