import { describe, it, expect } from 'vitest'
import { armarFilasClientes, textoAsignacion } from './exportClientes'
import type { ClienteDB } from '../types'

const base = { id: '1', nombre_fantasia: 'Kiosco', direccion: 'Calle 1' } as ClienteDB
const perfiles = [{ id: 'u1', nombre: 'Ana' }, { id: 'u2', nombre: 'Beto' }]
const opts = { zonas: [{ id: 7, nombre: 'Centro' }], perfiles, sucursalNombre: 'Tucumán', incluirSaldo: true }

describe('textoAsignacion', () => {
  it('distingue los tres estados', () => {
    expect(textoAsignacion({ ...base, reservado_admin: true }, perfiles)).toBe('Reservado admin')
    expect(textoAsignacion({ ...base, preventista_ids: [] }, perfiles)).toBe('Sin asignar')
    expect(textoAsignacion(base, perfiles)).toBe('Sin asignar')
    expect(textoAsignacion({ ...base, preventista_ids: ['u1', 'u2'] }, perfiles)).toBe('Ana, Beto')
  })
  it('reservado gana aunque traiga ids', () => {
    expect(textoAsignacion({ ...base, reservado_admin: true, preventista_ids: ['u1'] }, perfiles)).toBe('Reservado admin')
  })
  it('id sin perfil conocido no rompe', () => {
    expect(textoAsignacion({ ...base, preventista_ids: ['zz'] }, perfiles)).toBe('Desconocido')
  })
})

describe('armarFilasClientes', () => {
  it('exporta una fila por cliente recibido, inactivos incluidos', () => {
    const filas = armarFilasClientes(
      [{ ...base, activo: true }, { ...base, id: '2', activo: false }], opts)
    expect(filas.map(f => f['Activo'])).toEqual(['Sí', 'No'])
  })
  it('resuelve zona por id, sucursal y saldo', () => {
    const [f] = armarFilasClientes([{ ...base, zona_id: '7', saldo_cuenta: 150 }], opts)
    expect(f['Zona']).toBe('Centro')
    expect(f['Sucursal']).toBe('Tucumán')
    expect(f['Saldo cuenta corriente']).toBe(150)
  })
  it('la zona sale sólo de zona_id, no del texto legado clientes.zona (#1314)', () => {
    const [desfasado, sinZona] = armarFilasClientes([
      { ...base, zona_id: '7', zona: 'Centro Viejo' },
      { ...base, id: '2', zona_id: null, zona: 'ZONA 1. JOAQUIN' },
    ], opts)
    expect(desfasado['Zona']).toBe('Centro')
    expect(sinZona['Zona']).toBe('')
  })
  it('sin permiso no hay columna de saldo', () => {
    const [f] = armarFilasClientes([{ ...base, saldo_cuenta: 150 }], { ...opts, incluirSaldo: false })
    expect('Saldo cuenta corriente' in f).toBe(false)
  })
  it('fecha de alta en día argentino', () => {
    const [f] = armarFilasClientes([{ ...base, created_at: '2026-03-10T01:30:00Z' }], opts)
    expect(f['Fecha de alta']).toBe('2026-03-09')
  })
  it('lista vacía → sin filas', () => {
    expect(armarFilasClientes([], opts)).toEqual([])
  })
})
