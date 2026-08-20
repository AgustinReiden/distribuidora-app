import { describe, it, expect } from 'vitest'
import fixture from './prorrateoCompra.espejo.fixture.json'
import {
  CASOS_ESPEJO,
  CARGOS_TESTIGO,
  ITEMS_TESTIGO,
  cargoAWire,
  cargoDeWire,
  correrMotorTS,
  diferencias,
  esCasoDeContrato,
  lineaAWire,
  lineaDeWire,
  type CasoEspejo,
} from './prorrateoCompra.espejo'

/**
 * CAPA 1 DEL ESPEJO: el motor de TypeScript contra una FOTO del de SQL.
 *
 * LO QUE ESTE ARCHIVO NO PUEDE DETECTAR, y por eso lo dice el nombre del
 * describe y no sólo este comentario: que se haya movido el SQL. El fixture es
 * una foto congelada de la salida de `calcular_costos_compra` / `prorratear_cargo`
 * (mig 193); si alguien edita esas funciones en la base, la foto sigue diciendo
 * lo de antes y este test sigue verde mientras la producción calcula otra cosa.
 *
 * El que ve los dos lados es `scripts/espejo-motor-compras.mjs`, que corre las
 * DOS implementaciones sobre los mismos casos, deja que la comparación la haga
 * Postgres y vive en el gate de integridad —donde hay credenciales—. Ese es
 * también el único que puede regenerar este fixture, y sólo lo hace cuando la
 * comparación con la base salió en verde.
 *
 * Lo que SÍ detecta, al instante y sin red: que alguien tocó el motor de
 * TypeScript. Que es el caso frecuente, porque es el archivo que se edita
 * mientras se programa.
 */

interface CasoFixture {
  caso: string
  motor: string
  origen: string
  entrada: Record<string, unknown>
  celdas: number
  sql: Record<string, unknown> | null
  sql_error: string | null
}

const casosFixture = fixture.casos as unknown as CasoFixture[]
const decimales: number = fixture.decimales

/** El caso tal como lo va a correr el motor: la entrada sale DEL FIXTURE. */
const desdeFixture = (f: CasoFixture): CasoEspejo => ({
  caso: f.caso,
  motor: f.motor as CasoEspejo['motor'],
  entrada: f.entrada,
  origen: f.origen,
})

describe('Espejo TS ↔ SQL contra el fixture (no detecta que se haya movido el SQL)', () => {
  it('el fixture cubre exactamente los casos del espejo, con las mismas entradas', () => {
    // Si esto falla, alguien agregó o cambió un caso y no regeneró el fixture:
    // `node scripts/espejo-motor-compras.mjs --fijar`. Que el test siguiera
    // pasando con el fixture viejo sería peor que fallar — estaría verificando
    // un conjunto de casos que ya no es el que se declara.
    expect(casosFixture.map(c => c.caso)).toEqual(CASOS_ESPEJO.map(c => c.caso))
    for (const [i, caso] of CASOS_ESPEJO.entries()) {
      expect(casosFixture[i].motor).toBe(caso.motor)
      // Por el cable: es la forma en la que la entrada llegó a las dos
      // implementaciones, y la única que el fixture puede haber guardado.
      expect(casosFixture[i].entrada).toEqual(JSON.parse(JSON.stringify(caso.entrada)))
    }
  })

  it('el fixture se generó con los decimales que usa el espejo', () => {
    expect(decimales).toBe(6)
  })

  it('la traduccion a la forma de cable y de vuelta es la identidad', () => {
    // Sin esto, un error en el traductor haría que el espejo compare las dos
    // implementaciones sobre una entrada MUTILADA —las dos igual de mutilada—
    // y todo daría verde mientras nadie está mirando la factura que cree mirar.
    expect(ITEMS_TESTIGO.map(l => lineaDeWire(lineaAWire(l)))).toEqual(ITEMS_TESTIGO)
    expect(CARGOS_TESTIGO.map(c => cargoDeWire(cargoAWire(c)))).toEqual(CARGOS_TESTIGO)
  })

  const conValor = casosFixture.filter(f => !f.sql_error)
  const deContrato = casosFixture.filter(f => f.sql_error)

  describe('el motor de TS da lo que dio el de SQL', () => {
    it.each(conValor.map(f => [f.caso, f] as const))('%s', (_nombre, f) => {
      const { ts, ts_error } = correrMotorTS(desdeFixture(f))
      expect(ts_error).toBeNull()

      const { celdas, divergencias } = diferencias(ts, f.sql, decimales)
      // El mensaje de una divergencia trae el campo y los dos valores: sin eso
      // el fallo dice "objetos distintos" sobre 126 celdas y no sirve de nada.
      expect(
        divergencias.map(d => `${d.campo}: TS=${JSON.stringify(d.ts)} SQL=${JSON.stringify(d.sql)} (${d.motivo})`)
      ).toEqual([])
      // Y que además se hayan comparado TODAS: un motor que dejara de emitir un
      // campo bajaría este número, y el array vacío de arriba no lo diría.
      expect(celdas).toBe(f.celdas)
    })
  })

  describe('las dos rechazan la misma basura', () => {
    it.each(deContrato.map(f => [f.caso, f] as const))('%s', (_nombre, f) => {
      // El fixture guarda que el SQL rechazó esta entrada. Si el TS la acepta,
      // la vista previa le muestra al usuario un costo que la base no va a
      // guardar. El TEXTO no se compara: el de SQL nombra la funcion en
      // snake_case y el de TS en camelCase, y atarlos volveria fragil el gate
      // sin agregar nada. Lo que se compara es que los dos frenen.
      const { ts, ts_error } = correrMotorTS(desdeFixture(f))
      expect(ts).toBeNull()
      expect(ts_error).toBeTruthy()
      expect(f.sql_error).toBeTruthy()
    })

    it('todos los casos marcados de contrato son de contrato, y viceversa', () => {
      // Que el nombre y el comportamiento no se despeguen: un caso bautizado
      // "contrato ·" que en realidad devuelve un número dejaría de probar nada
      // y nadie lo notaría leyendo la lista.
      expect(deContrato.map(f => f.caso).sort())
        .toEqual(CASOS_ESPEJO.filter(esCasoDeContrato).map(c => c.caso).sort())
    })
  })

  it('la factura testigo compara las 156 celdas enteras, no una muestra', () => {
    // 21 lineas x 7 claves (el id y los seis unitarios) + 7 totales + los 2
    // factores de ajuste. El numero esta clavado para que un caso que se vacie
    // —una entrada que deje de tener lineas, un adaptador que devuelva {}— se
    // note: el resto de la suite pasaria igual comparando cero contra cero.
    const testigo = casosFixture.find(f => f.caso === 'testigo · factura A0005-00461415 completa')!
    expect(testigo.celdas).toBe(21 * 7 + 7 + 2)
  })
})
