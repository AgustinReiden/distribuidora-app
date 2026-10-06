import { describe, it, expect } from 'vitest'
import {
  matchEscaneo, matchProveedor, normalizarDescripcion, normalizarCodigoProveedor, rasgosDescripcion,
  compararTamano, UMBRAL_SUGERIDO, equivalenciasParaRegistrar,
  CONFIANZA_MIN_DIFUSA, CONFIANZA_MAX_DIFUSA, MARGEN_SUGERIDO, confianzaDifusa, prepararCatalogo, buscarEnCatalogo,
} from './matchEscaneo'
import type { ProductoMatchable, LineaEscaneada, EntradaMatchEscaneo } from './matchEscaneo'

// Catálogo sintético con la forma de los nombres reales de la sucursal.
const CATALOGO: ProductoMatchable[] = [
  { id: '1', nombre: 'AGUA VILLAMANAOS SIN GAS 600 cc x 12', codigo: '200101' },
  { id: '2', nombre: 'AGUA VILLAMANAOS CON GAS 600 cc x 12', codigo: '200102' },
  { id: '3', nombre: 'AGUA VILLAMANAOS SIN GAS 2LT x 6', codigo: '200103' },
  { id: '4', nombre: 'MANAOS COLA 3 LT', codigo: '100101' },
  { id: '5', nombre: 'MANAOS COLA 2,25 LT', codigo: '100102' },
  { id: '6', nombre: 'MANAOS COLA 1,5 LT', codigo: '100103' },
  { id: '7', nombre: 'COCA COLA 1.5 LT X 6', codigo: null },
  { id: '8', nombre: 'COCA COLA ZERO 1.5LTS X 6', codigo: null },
  { id: '9', nombre: 'MANAOS NARANJA 3 LT', codigo: '100201' },
  { id: '10', nombre: 'MANAOS LIMA LIMON 3 LT', codigo: '100202' },
  { id: '11', nombre: 'POLENTA RAPIDA X 5 X 500 GRS', codigo: '100' },
  { id: '12', nombre: 'POLENTA X 5 X 500 GRS', codigo: '100' },
  { id: '13', nombre: 'CANELA MOLIDA x 25 g', codigo: '43538' },
  { id: '14', nombre: 'COMINO x 25 g', codigo: '43539' },
  { id: '15', nombre: 'YERBA VERDEF. HIERBAS x 500gr', codigo: 'Y03' },
  { id: '16', nombre: 'SAL FINA x 500 g x 10 u', codigo: null },
  { id: '17', nombre: 'MANAOS COLA 600 cc', codigo: '100104' },
  { id: '18', nombre: 'PRODUCTO DADO DE BAJA', codigo: 'BAJA1', activo: false },
]

const linea = (descripcion: string, extra: Partial<LineaEscaneada> = {}): LineaEscaneada =>
  ({ codigo: null, descripcion, cantidad: 1, precioUnitarioNeto: null, ...extra })

const correr = (lineas: LineaEscaneada[], extra: Partial<EntradaMatchEscaneo> = {}) =>
  matchEscaneo({ lineas, proveedorId: '20', catalogo: CATALOGO, ...extra })

describe('normalizarDescripcion (espejo de la mig 292)', () => {
  // La MISMA tabla que el DO $ensayo$ de la migración: si alguna se mueve, el
  // matcher busca una llave que la RPC no guardó.
  it.each([
    ['AGUA VILLAM. S/G 600X12', 'agua villam s g 600x12'],
    ['MANAOS COLA 2,25 LT', 'manaos cola 2.25 lt'],
    ['Coca-Cola  Zero 1.5Lts x 6', 'coca cola zero 1.5lts x 6'],
    ['AZÚCAR LEDESMA x 1 KG.', 'azucar ledesma x 1 kg'],
    ['  Ñoquis #3 (500grs) ', 'noquis 3 500grs'],
    ['1.2.3', '1.2 3'],
    ['PAÑAL. ', 'panal'],
  ])('%s → %s', (entrada, esperado) => {
    expect(normalizarDescripcion(entrada)).toBe(esperado)
  })

  it('sin letras ni números queda vacía (la SQL devuelve NULL)', () => {
    expect(normalizarDescripcion(' .,- ')).toBe('')
    expect(normalizarDescripcion(null)).toBe('')
  })

  it('el código del proveedor va sin espacios y en mayúsculas', () => {
    expect(normalizarCodigoProveedor(' ab 12 ')).toBe('AB12')
    expect(normalizarCodigoProveedor(4512)).toBe('4512')
  })
})

describe('rasgos: tamaños y packs', () => {
  it('600cc, 600 ml y 0,6 L son el mismo tamaño', () => {
    const a = rasgosDescripcion('AGUA 600cc')
    expect(compararTamano(a, rasgosDescripcion('AGUA 600 ml')).veredicto).toBe('igual')
    expect(compararTamano(a, rasgosDescripcion('AGUA 0,6L')).veredicto).toBe('igual')
    expect(compararTamano(a, rasgosDescripcion('AGUA 2,25 L')).veredicto).toBe('distinto')
  })

  it('separa el pack del tamaño: "600X12", "x 12", "X6"', () => {
    expect(rasgosDescripcion('AGUA VILLAM S/G 600X12')).toMatchObject({ sueltos: [600], packs: [12] })
    expect(rasgosDescripcion('AGUA VILLAMANAOS SIN GAS 600 cc x 12')).toMatchObject({
      medidas: [{ dim: 'vol', valor: 600 }], packs: [12],
    })
    expect(rasgosDescripcion('COCA COLA 1500 X6')).toMatchObject({ sueltos: [1500], packs: [6] })
    expect(rasgosDescripcion('POLENTA X 5 X 500 GRS')).toMatchObject({ medidas: [{ dim: 'peso', valor: 500 }], packs: [5] })
  })

  it('expande S/G y C/G antes de comparar', () => {
    expect(rasgosDescripcion('AGUA S/G').tokens).toEqual(['agua', 'sin', 'gas'])
    expect(rasgosDescripcion('AGUA C/G').tokens).toEqual(['agua', 'con', 'gas'])
  })

  it('un número suelto se compara contra la medida en ml o en litros', () => {
    expect(compararTamano(rasgosDescripcion('MANAOS COLA 2.25'), rasgosDescripcion('MANAOS COLA 2,25 LT')).veredicto).toBe('igual')
    expect(compararTamano(rasgosDescripcion('MANAOS COLA 2.25'), rasgosDescripcion('MANAOS COLA 3 LT')).veredicto).toBe('distinto')
    expect(compararTamano(rasgosDescripcion('COCA 1500'), rasgosDescripcion('COCA 1.5LTS')).veredicto).toBe('igual')
  })
})

describe('matchEscaneo · ranking difuso', () => {
  it('"AGUA VILLAM S/G 600X12" sugiere la Villamanaos sin gas de 600 x 12, sin vincularla sola', () => {
    const [r] = correr([linea('AGUA VILLAM S/G 600X12')])
    expect(r.estado).toBe('sugerido')
    expect(r.productoId).toBe('1')
    expect(r.confianza).toBeGreaterThanOrEqual(CONFIANZA_MIN_DIFUSA)
    expect(r.confianza).toBeLessThan(0.9)
  })

  it('"MANAOS COLA 3LT" y "MANAOS COLA 2.25" no se mezclan', () => {
    const [tres, dos] = correr([linea('MANAOS COLA 3LT'), linea('MANAOS COLA 2.25')])
    expect(tres).toMatchObject({ estado: 'sugerido', productoId: '4' })
    expect(dos).toMatchObject({ estado: 'sugerido', productoId: '5' })
    expect(tres.alternativas.map(a => a.productoId)).not.toContain('4')
  })

  it('"COCA COLA 1500 X6" es la común, nunca la Zero', () => {
    const [comun, zero] = correr([linea('COCA COLA 1500 X6'), linea('COCA COLA ZERO 1.5 X 6')])
    expect(comun).toMatchObject({ estado: 'sugerido', productoId: '7' })
    expect(zero).toMatchObject({ estado: 'sugerido', productoId: '8' })
  })

  it('una Zero de otro tamaño no cae en la común', () => {
    const [r] = correr([linea('COCA COLA ZERO 2.25 X 6')])
    expect(r.productoId).not.toBe('7')
    expect(r.estado).toBe('sin_match')
  })

  it('el precio cerca del último costo empuja; uno disparatado baja a sin_match', () => {
    const comprados = [{ productoId: '4', ultimoCosto: 5000 }]
    const [cerca] = correr([linea('MANAOS COLA 3LT', { precioUnitarioNeto: 5200 })], { comprados })
    const [lejos] = correr([linea('MANAOS COLA 3LT', { precioUnitarioNeto: 26000 })], { comprados })
    expect(cerca).toMatchObject({ estado: 'sugerido', productoId: '4' })
    expect(lejos.estado).toBe('sin_match')
    expect(lejos.alternativas[0].productoId).toBe('4')
  })

  it('lo que ya se le compró al proveedor desempata a favor', () => {
    const catalogo: ProductoMatchable[] = [
      { id: 'a', nombre: 'GALLETITAS DULCES SURTIDAS 400 GRS' },
      { id: 'b', nombre: 'GALLETITAS DULCES SURTIDAS 400 GRS' },
    ]
    const [sin] = matchEscaneo({ lineas: [linea('GALLETITAS DULCES SURTIDAS 400G')], proveedorId: '20', catalogo })
    const [con] = matchEscaneo({
      lineas: [linea('GALLETITAS DULCES SURTIDAS 400G')], proveedorId: '20', catalogo,
      comprados: [{ productoId: 'b', ultimoCosto: null }],
    })
    // Dos idénticos sin historial: no hay margen, nadie se sugiere solo.
    expect(sin.estado).toBe('sin_match')
    expect(sin.alternativas.map(a => a.productoId).sort()).toEqual(['a', 'b'])
    expect(con.alternativas[0]?.productoId ?? con.productoId).toBe('b')
  })

  it('una línea que no se parece a nada queda sin_match sin alternativas', () => {
    const [r] = correr([linea('TORNILLO AUTOPERFORANTE 8X1')])
    expect(r).toMatchObject({ estado: 'sin_match', alternativas: [] })
    expect(r.productoId).toBeUndefined()
  })

  it('con gas y sin gas no se cruzan', () => {
    const [r] = correr([linea('AGUA VILLAMANAOS C/G 600 X 12')])
    expect(r).toMatchObject({ estado: 'sugerido', productoId: '2' })
  })
})

describe('matchEscaneo · equivalencias y código', () => {
  const equivalencias = [
    { productoId: '4', codigoProveedor: 'mc-3', descripcionNormalizada: 'cola 3000 manaos', unidadesPorBulto: null },
    { productoId: '1', codigoProveedor: null, descripcionNormalizada: 'agua villam s g 600x12', unidadesPorBulto: 12 },
    { productoId: '18', codigoProveedor: 'XX', descripcionNormalizada: 'algo de baja', unidadesPorBulto: null },
  ]

  it('la equivalencia por código vincula con confianza 1', () => {
    const [r] = correr([linea('lo que sea', { codigo: ' MC-3 ' })], { equivalencias })
    expect(r).toMatchObject({ estado: 'vinculado', productoId: '4', confianza: 1 })
  })

  it('la equivalencia por descripción vincula con 0.98 y trae la conversión', () => {
    const [r] = correr([linea('Agua Villam. S/G 600x12')], { equivalencias })
    expect(r).toMatchObject({ estado: 'vinculado', productoId: '1', confianza: 0.98, unidadesPorBulto: 12 })
  })

  it('una equivalencia a un producto dado de baja no se usa', () => {
    const [r] = correr([linea('ALGO DE BAJA', { codigo: 'XX' })], { equivalencias })
    expect(r.productoId).not.toBe('18')
    expect(r.estado).not.toBe('vinculado')
  })

  it('sin proveedor no se usan equivalencias ni historial', () => {
    const [r] = correr([linea('lo que sea', { codigo: 'MC-3' })], { equivalencias, proveedorId: null })
    expect(r.estado).toBe('sin_match')
  })

  it('nuestro código único vincula con 0.9', () => {
    const [r] = correr([linea('MANAOS COLA 3 LITROS', { codigo: '100101' })])
    expect(r).toMatchObject({ estado: 'vinculado', productoId: '4', confianza: 0.9 })
  })

  it('nuestro código único con una descripción que no tiene nada que ver: sugerido', () => {
    const [r] = correr([linea('TORNILLO AUTOPERFORANTE', { codigo: '43538' })])
    expect(r).toMatchObject({ estado: 'sugerido', productoId: '13', confianza: 0.6 })
  })

  it('un código repetido en la sucursal nunca vincula solo: sugiere el más parecido', () => {
    const [r] = correr([linea('POLENTA RAPIDA 5X500', { codigo: '100' })])
    expect(r).toMatchObject({ estado: 'sugerido', productoId: '11', confianza: 0.6 })
    expect(r.alternativas.map(a => a.productoId)).toEqual(['12'])
  })
})

describe('matchEscaneo · invariantes', () => {
  it('dos líneas al mismo producto quedan marcadas', () => {
    const r = correr([
      linea('x', { codigo: '100101' }),
      linea('CANELA MOLIDA 25G'),
      linea('MANAOS COLA 3 LT', { codigo: '100101' }),
    ])
    expect(r[0].duplicadoCon).toEqual([2])
    expect(r[2].duplicadoCon).toEqual([0])
    expect(r[1].duplicadoCon).toBeUndefined()
  })

  it('nunca inventa: todo id devuelto está en el catálogo activo', () => {
    const lineas = [
      'AGUA VILLAM S/G 600X12', 'MANAOS COLA 3LT', 'COCA COLA 1500 X6', 'PRODUCTO DADO DE BAJA',
      'YERBA VERDEFLOR HIERBAS 500', 'SAL FINA 500G X10', 'ZZZ', '',
    ].map(d => linea(d))
    const activos = new Set(CATALOGO.filter(p => p.activo !== false).map(p => String(p.id)))
    for (const r of correr(lineas)) {
      if (r.productoId) expect(activos.has(r.productoId)).toBe(true)
      for (const a of r.alternativas) expect(activos.has(a.productoId)).toBe(true)
      expect(r.alternativas.length).toBeLessThanOrEqual(3)
      expect(r.confianza).toBeGreaterThanOrEqual(0)
      expect(r.confianza).toBeLessThanOrEqual(1)
      // Lo difuso nunca vincula: sin código ni equivalencia, como mucho sugerido.
      expect(r.estado).not.toBe('vinculado')
    }
  })
})

describe('equivalenciasParaRegistrar', () => {
  it('una por llave, con el producto con el que quedó cada línea', () => {
    expect(equivalenciasParaRegistrar([
      { productoId: 4, origenesEscaneo: [{ codigo: ' mc 3 ', descripcion: 'COLA 3L' }, { codigo: null, descripcion: 'Cola 3L.' }] },
      { productoId: '9', origenesEscaneo: [{ codigo: 'MC3', descripcion: 'cola 3l' }] },
      { productoId: '1' },
      { productoId: '2', origenesEscaneo: [{ codigo: null, descripcion: ' - ' }] },
    ])).toEqual([
      { producto_id: '4', codigo_proveedor: 'MC3', descripcion: 'COLA 3L' },
      { producto_id: '4', codigo_proveedor: null, descripcion: 'Cola 3L.' },
    ])
  })
})

describe('matchProveedor', () => {
  const proveedores = [
    { id: '20', nombre: 'Distribuidora Manaos S.A.', cuit: '30-71234567-8' },
    { id: '21', nombre: 'Cotella SRL', cuit: '30-70000000-1' },
    { id: '22', nombre: 'Viejo', cuit: '20-11111111-1', activo: false },
  ]

  it('el CUIT manda, con o sin guiones', () => {
    expect(matchProveedor({ nombre: 'cualquiera', cuit: '30712345678' }, proveedores))
      .toMatchObject({ estado: 'vinculado', proveedorId: '20', confianza: 1 })
  })

  it('sin CUIT conocido, un nombre parecido queda sugerido', () => {
    expect(matchProveedor({ nombre: 'DISTRIBUIDORA MANAOS SA', cuit: '30-99999999-9' }, proveedores))
      .toMatchObject({ estado: 'sugerido', proveedorId: '20' })
  })

  it('un proveedor inactivo no se vincula por CUIT', () => {
    expect(matchProveedor({ nombre: null, cuit: '20111111111' }, proveedores).estado).toBe('sin_match')
  })

  it('nada parecido: sin_match', () => {
    expect(matchProveedor({ nombre: 'Ferretería El Tornillo', cuit: null }, proveedores))
      .toMatchObject({ estado: 'sin_match', alternativas: [] })
  })
})

/**
 * Entrega C: la confianza de lo difuso dejó de ser un 0.89 plano. Se reparte
 * por puntaje y por la ventaja sobre el segundo, y nunca llega al 0.9 del
 * vínculo por código.
 */
describe('confianzaDifusa: se reparte y no alcanza al vínculo', () => {
  it('el mínimo es el que apenas pasa umbral y margen; el máximo, 0.89', () => {
    expect(confianzaDifusa(UMBRAL_SUGERIDO, UMBRAL_SUGERIDO - MARGEN_SUGERIDO)).toBe(CONFIANZA_MIN_DIFUSA)
    expect(confianzaDifusa(1.3, 0)).toBe(CONFIANZA_MAX_DIFUSA)
    expect(confianzaDifusa(50, -50)).toBeLessThan(0.9)
  })

  it('sube con el puntaje y con la ventaja sobre el segundo', () => {
    expect(confianzaDifusa(0.95, 0.5)).toBeGreaterThan(confianzaDifusa(0.8, 0.35))
    expect(confianzaDifusa(1.0, 0.3)).toBeGreaterThan(confianzaDifusa(1.0, 0.85))
  })

  it('dos líneas difusas distintas ya no muestran el mismo número', () => {
    const rs = correr([linea('AGUA VILLAM S/G 600X12'), linea('MANAOS NARANJA 3LT'), linea('CANELA MOLIDA 25G')])
    const difusas = rs.filter(r => r.estado === 'sugerido').map(r => r.confianza)
    expect(difusas.length).toBeGreaterThanOrEqual(2)
    expect(new Set(difusas).size).toBeGreaterThan(1)
    for (const c of difusas) expect(c).toBeLessThan(0.9)
  })

  it('lo difuso nunca vincula solo, por alto que sea el parecido', () => {
    const rs = correr([linea('MANAOS COLA 3 LT'), linea('AGUA VILLAMANAOS SIN GAS 600 cc x 12')],
      { comprados: [{ productoId: '4', ultimoCosto: 1000 }, { productoId: '1', ultimoCosto: 500 }] })
    for (const r of rs) {
      expect(r.estado).toBe('sugerido')
      expect(r.confianza).toBeLessThan(0.9)
    }
  })
})

describe('buscarEnCatalogo: el buscador de la revisión usa el motor del matcher', () => {
  const prep = prepararCatalogo(CATALOGO, { proveedorId: '20', comprados: [{ productoId: '3', ultimoCosto: 100 }] })
  const ids = (q: string) => buscarEnCatalogo(prep, q).map(r => r.productoId)

  it('entiende abreviaturas y tamaños: "villam s/g 600" trae la sin gas de 600 primero', () => {
    expect(ids('villam s/g 600')[0]).toBe('1')
  })

  it('lo tipeado es parcial: "coca" no castiga a la Zero por tener una palabra de más', () => {
    expect(ids('coca').slice(0, 2).sort()).toEqual(['7', '8'])
  })

  it('un código tipeado que coincide va primero', () => {
    expect(ids('43539')[0]).toBe('14')
  })

  it('premia lo que ya se le compró al proveedor', () => {
    expect(ids('agua villamanaos sin gas')[0]).toBe('3')
  })

  it('no ofrece los dados de baja, y sin consulta no devuelve nada', () => {
    expect(ids('dado de baja')).not.toContain('18')
    expect(buscarEnCatalogo(prep, '  ')).toEqual([])
  })
})

describe('equivalenciasParaRegistrar: la conversión confirmada en la revisión', () => {
  it('viaja sólo si la clave está (confirmada); null = 1:1', () => {
    const r = equivalenciasParaRegistrar([
      { productoId: '1', origenesEscaneo: [{ codigo: 'A1', descripcion: 'CAJA AGUA', unidadesPorBulto: 12 }] },
      { productoId: '2', origenesEscaneo: [{ codigo: 'B1', descripcion: 'AGUA SUELTA', unidadesPorBulto: null }] },
      { productoId: '3', origenesEscaneo: [{ codigo: 'C1', descripcion: 'SIN TOCAR' }] },
    ])
    expect(r[0]).toMatchObject({ producto_id: '1', unidades_por_bulto: 12 })
    expect(r[1]).toMatchObject({ producto_id: '2', unidades_por_bulto: null })
    expect('unidades_por_bulto' in r[2]).toBe(false)
  })
})
