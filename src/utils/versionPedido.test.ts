import { describe, it, expect } from 'vitest'
import { versionTrasCambioPropio } from './versionPedido'

const V1 = '2026-11-03T12:00:00.123456+00:00'
const V2 = '2026-11-03T12:05:00.654321+00:00'

describe('versionTrasCambioPropio (#1376)', () => {
  it('adopta la nueva si la edición estaba en la de antes', () => {
    expect(versionTrasCambioPropio(V1, { anterior: V1, nueva: V2 })).toBe(V2)
  })

  it('compara el instante, no el texto', () => {
    expect(versionTrasCambioPropio('2026-11-03T12:00:00.123Z', {
      anterior: '2026-11-03T12:00:00.123+00:00', nueva: V2,
    })).toBe(V2)
  })

  it('no la adopta si otro guardó en el medio: el rechazo tiene que llegar', () => {
    const otro = '2026-11-03T12:02:00+00:00'
    expect(versionTrasCambioPropio(V1, { anterior: otro, nueva: V2 })).toBe(V1)
  })

  it('sin versión la edición no compara, y sigue sin comparar', () => {
    expect(versionTrasCambioPropio(null, { anterior: V1, nueva: V2 })).toBeNull()
  })

  it('un replay idempotente no trae versiones: no cambia nada', () => {
    expect(versionTrasCambioPropio(V1, undefined)).toBe(V1)
  })
})
