import { describe, it, expect } from 'vitest'
import { claveNombreZona, esZonaRepetidaDelServer, mensajeZonaRepetida, zonaConMismoNombre } from './nombreZona'

const zonas = [
  { id: '1', nombre: 'Centro ', activo: true },
  { id: '2', nombre: 'Norte', activo: false },
]

describe('nombre de zona único sin mirar mayúsculas ni espacios (D13)', () => {
  it('la clave saca los espacios de los bordes y pasa a mayúsculas, como upper(btrim())', () => {
    expect(claveNombreZona('  Centro ')).toBe('CENTRO')
    expect(claveNombreZona('centro sur')).toBe('CENTRO SUR')
    expect(claveNombreZona('\tCentro')).toBe('\tCENTRO')
    expect(claveNombreZona(null)).toBe('')
  })

  it('encuentra la zona que ya existe aunque esté guardada con un espacio de más', () => {
    expect(zonaConMismoNombre(zonas, 'CENTRO')?.id).toBe('1')
    expect(zonaConMismoNombre(zonas, ' centro')?.id).toBe('1')
    expect(zonaConMismoNombre(zonas, 'norte')?.id).toBe('2')
    expect(zonaConMismoNombre(zonas, 'Centro Sur')).toBeUndefined()
    expect(zonaConMismoNombre(zonas, '   ')).toBeUndefined()
  })

  it('al renombrar no choca consigo misma', () => {
    expect(zonaConMismoNombre(zonas, 'CENTRO', '1')).toBeUndefined()
    expect(zonaConMismoNombre(zonas, 'NORTE', '1')?.id).toBe('2')
  })

  it('el aviso nombra la zona que ya está, y si está desactivada', () => {
    expect(mensajeZonaRepetida({ nombre: 'Centro ' })).toContain('«Centro »')
    expect(mensajeZonaRepetida({ nombre: 'Norte', activo: false })).toContain('(desactivada)')
  })

  it('reconoce el rechazo del trigger del server y no un 23505 cualquiera', () => {
    expect(esZonaRepetidaDelServer({ code: '23505', message: 'Ya existe la zona «Centro» en esta sucursal: …' })).toBe(true)
    expect(esZonaRepetidaDelServer({ code: '23505', message: 'duplicate key value violates unique constraint "zonas_nombre_unico_por_sucursal"' })).toBe(false)
    expect(esZonaRepetidaDelServer({ code: '42501', message: 'Ya existe la zona «Centro»' })).toBe(false)
    expect(esZonaRepetidaDelServer(null)).toBe(false)
  })
})
