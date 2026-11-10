import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { hallazgosClientesActivo } from '../../scripts/lib/clientesActivo.mjs'

/**
 * Lo que decide el gate de clientes dados de baja (scripts/check-clientes-activo.mjs, gate 3 de
 * #1520): toda función que inserta en pedidos mira clientes.activo, salvo las permitidas.
 */
describe('hallazgosClientesActivo', () => {
  const nueva = 'crear_pedido_mostrador(bigint,jsonb)'

  it('sin funciones que no miran, no hay nada', () => {
    expect(hallazgosClientesActivo({ funciones: 3, sin_activo: [] })).toEqual({ faltan: [], sobrantes: [] })
  })

  it('una función que crea pedidos sin mirar activo es rojo', () => {
    expect(hallazgosClientesActivo({ funciones: 4, sin_activo: [nueva] })).toEqual({
      faltan: [nueva],
      sobrantes: [],
    })
  })

  it('la permitida no es rojo', () => {
    expect(hallazgosClientesActivo({ sin_activo: [nueva] }, { [nueva]: 'x' }).faltan).toEqual([])
  })

  it('la permitida que ya mira activo sobra, y no es rojo', () => {
    expect(hallazgosClientesActivo({ sin_activo: [] }, { [nueva]: 'x' })).toEqual({
      faltan: [],
      sobrantes: [nueva],
    })
  })

  it('va por firma: una sobrecarga nueva no hereda la excepción', () => {
    const sobrecarga = 'crear_pedido_mostrador(bigint,jsonb,text)'
    expect(hallazgosClientesActivo({ sin_activo: [sobrecarga] }, { [nueva]: 'x' }).faltan).toEqual([sobrecarga])
  })
})

describe('scripts/clientes-activo-permitidas.json', () => {
  const ruta = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../scripts/clientes-activo-permitidas.json')
  const lista = JSON.parse(fs.readFileSync(ruta, 'utf8')) as { funciones: Record<string, string> }

  // Al nacer el gate (mig 480) las tres funciones que insertan en pedidos ya miraban activo. La
  // lista sólo se achica: una función nueva mira activo o crea por crear_pedido_completo.
  const alNacer: string[] = []

  it('sólo se achica: ninguna permitida es nueva', () => {
    for (const firma of Object.keys(lista.funciones)) expect(alNacer).toContain(firma)
  })
})
