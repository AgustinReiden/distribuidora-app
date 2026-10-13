import { describe, it, expect } from 'vitest'
import {
  armarListaPrecios,
  condicionMayorista,
  TITULO_SIN_CATEGORIA,
  type ProductoListaPrecios,
} from './listaPrecios'
import { describirReglaEscala } from './describirReglaEscala'
import { resolverPreciosMayorista, type PricingMap } from './precioMayorista'
import { orquestarPrecios } from './orquestacionPrecios'
import type { PromoMap } from './promociones'
import type { GrupoPrecioConDetalles } from '../types'

// =============================================================================
// Fixtures: armadas con los datos reales de Tucumán del 2026-10-13.
// =============================================================================

let siguienteId = 1
const nuevoId = () => String(siguienteId++)

interface EscalaFixture {
  cantidad: number
  precio: number
  activo?: boolean
  minProductosDistintos?: number
  minimos?: Array<{ productoId: string; cantidad: number; precioOverride?: number | null }>
}

function grupo(
  nombre: string,
  productoIds: string[],
  escalas: EscalaFixture[],
  opts: { activo?: boolean } = {},
): GrupoPrecioConDetalles {
  const id = nuevoId()
  const escalasDb = escalas.map(e => ({
    id: nuevoId(),
    grupo_precio_id: id,
    cantidad_minima: e.cantidad,
    precio_unitario: e.precio,
    etiqueta: null,
    activo: e.activo ?? true,
    min_productos_distintos: e.minProductosDistintos ?? 1,
  }))
  const escalaMinimos: GrupoPrecioConDetalles['escalaMinimos'] = {}
  escalas.forEach((e, i) => {
    if (!e.minimos) return
    escalaMinimos[escalasDb[i].id] = e.minimos.map(m => ({
      escala_id: escalasDb[i].id,
      producto_id: m.productoId,
      cantidad_minima_por_item: m.cantidad,
      precio_unitario_override: m.precioOverride ?? null,
      sucursal_id: '1',
    }))
  })
  return {
    id,
    nombre,
    activo: opts.activo ?? true,
    productos: productoIds.map(pid => ({ id: nuevoId(), grupo_precio_id: id, producto_id: pid })),
    escalas: escalasDb,
    escalaMinimos,
  }
}

function producto(
  id: string,
  nombre: string,
  precio: number | string | null,
  extra: Partial<ProductoListaPrecios> = {},
): ProductoListaPrecios {
  return { id, nombre, precio, activo: true, categoria: null, subcategoria_id: null, ...extra }
}

/** El formateo de moneda usa un espacio duro entre "$" y el número. */
const sinEspacioDuro = (lineas: string[]) => lineas.map(l => l.replace(/\u00a0/g, ' '))

const condicion = (
  p: ProductoListaPrecios,
  grupos: GrupoPrecioConDetalles[],
  productos: ProductoListaPrecios[] = [p],
) => sinEspacioDuro(condicionMayorista(p, grupos, productos))

// Productos reales
const codito = producto('140', 'CODITO COTELLA 500GRS ', 1030, { categoria: 'FIDEOS', subcategoria_id: 'sub-500' })
const papasCebolla = producto('103', 'PAPAS FRITAS CEBOLLA', 2860, { categoria: 'SNACKS' })
const papasJamon = producto('104', 'PAPAS FRITAS JAMON', 2860, { categoria: 'SNACKS' })
const papasTomChe = producto('102', 'PAPAS FRITAS TOM & CHE', 2860, { categoria: 'SNACKS' })
const alfatucBlanco = producto('156', 'ALFATUC BLANCO x 18 u', 5800, { categoria: 'ALFAJORES' })
const alfatucNegro = producto('157', 'ALFATUC NEGRO x 18 u', 5800, { categoria: 'ALFAJORES' })
const pamperito = producto('169', 'PAMPERITO COTELLA 500 GRS', 950, { categoria: 'FIDEOS', subcategoria_id: 'sub-500' })

describe('condicionMayorista \u2014 el texto aprobado por el dueño (2026-10-13)', () => {
  it('un producto en dos condiciones: una línea por escala, ordenadas por cantidad', () => {
    // FIDEO X FARDO (12 u. a $950) y CODITO 1/2 FARDO (6 u. a $990), cada uno solo.
    const grupos = [
      grupo('FIDEO X FARDO', ['140'], [{ cantidad: 12, precio: 950 }]),
      grupo('CODITO 1/2 FARDO', ['140'], [{ cantidad: 6, precio: 990 }]),
    ]
    expect(condicion(codito, grupos)).toEqual([
      'Desde 6 u. $ 990,00 c/u',
      'Desde 12 u. $ 950,00 c/u',
    ])
  })

  it('surtido: la última línea dice con cuántos sabores suma', () => {
    const papas = [papasCebolla, papasJamon, papasTomChe]
    const grupos = [grupo('PAPAS SABORIZADAS', ['103', '104', '102'], [{ cantidad: 18, precio: 2350 }])]
    expect(condicion(papasCebolla, grupos, papas)).toEqual([
      'Desde 18 u. $ 2.350,00 c/u',
      'surtido con 3 sabores',
    ])
  })

  it('varias escalas con el mismo surtido: el surtido va una sola vez, al final', () => {
    const alfatuc = [alfatucBlanco, alfatucNegro]
    const grupos = [
      grupo('Alfatuc Mayorista', ['156', '157'], [{ cantidad: 2, precio: 5600 }]),
      grupo('ALFATUC X 10 CAJAS', ['156', '157'], [{ cantidad: 10, precio: 5200 }]),
    ]
    expect(condicion(alfatucBlanco, grupos, alfatuc)).toEqual([
      'Desde 2 u. $ 5.600,00 c/u',
      'Desde 10 u. $ 5.200,00 c/u',
      'surtido con 2 sabores',
    ])
  })

  it('una escala de más cantidad que no baja el precio no se muestra (PAMPERITO)', () => {
    const grupos = [
      grupo('PAMPERITO 1/2 FARDO', ['169'], [{ cantidad: 6, precio: 890 }]),
      grupo('PAMPERITO FARDO', ['169'], [{ cantidad: 12, precio: 890 }]),
    ]
    expect(condicion(pamperito, grupos)).toEqual(['Desde 6 u. $ 890,00 c/u'])
  })

  it('al mismo precio pero sumando más sabores SÍ se muestra, con el surtido en su línea', () => {
    const otro1 = producto('201', 'OTRO 1', 950)
    const otro2 = producto('202', 'OTRO 2', 950)
    const grupos = [
      grupo('SOLO', ['169'], [{ cantidad: 6, precio: 890 }]),
      grupo('SURTIDO', ['169', '201', '202'], [{ cantidad: 12, precio: 890 }]),
    ]
    expect(condicion(pamperito, grupos, [pamperito, otro1, otro2])).toEqual([
      'Desde 6 u. $ 890,00 c/u',
      'Desde 12 u. $ 890,00 c/u, surtido con 3 sabores',
    ])
  })

  it('surtidos distintos por escala: cada línea dice el suyo', () => {
    const otro = producto('201', 'OTRO', 1030)
    const grupos = [
      grupo('1/2 FARDO', ['140'], [{ cantidad: 6, precio: 990 }]),
      grupo('FARDO SURTIDO', ['140', '201'], [{ cantidad: 12, precio: 950 }]),
    ]
    expect(condicion(codito, grupos, [codito, otro])).toEqual([
      'Desde 6 u. $ 990,00 c/u',
      'Desde 12 u. $ 950,00 c/u, surtido con 2 sabores',
    ])
  })

  it('un sabor desactivado no cuenta para el surtido', () => {
    const inactivo = producto('104', 'PAPAS FRITAS JAMON', 2860, { activo: false })
    const grupos = [grupo('PAPAS', ['103', '104'], [{ cantidad: 18, precio: 2350 }])]
    expect(condicion(papasCebolla, grupos, [papasCebolla, inactivo])).toEqual([
      'Desde 18 u. $ 2.350,00 c/u',
    ])
  })

  it('sin condiciones no hay texto', () => {
    expect(condicion(codito, [])).toEqual([])
  })

  it('ignora el grupo desactivado y la escala desactivada, como fetchPricingMap', () => {
    const grupos = [
      grupo('APAGADO', ['140'], [{ cantidad: 6, precio: 900 }], { activo: false }),
      grupo('ESCALA APAGADA', ['140'], [
        { cantidad: 12, precio: 800, activo: false },
        { cantidad: 24, precio: 850 },
      ]),
    ]
    expect(condicion(codito, grupos)).toEqual(['Desde 24 u. $ 850,00 c/u'])
  })

  it('una escala que no baja del precio de lista no es condición mayorista', () => {
    const grupos = [grupo('CARO', ['140'], [{ cantidad: 6, precio: 1030 }, { cantidad: 12, precio: 1100 }])]
    expect(condicion(codito, grupos)).toEqual([])
  })

  it('dice lo que cobra el pedido aunque la escala mayor del grupo sea más cara', () => {
    // Dentro de un grupo manda la escala de mayor cantidad que aplica, no la más
    // barata: con 12 u. el pedido cobra $950, no $900. La lista no puede
    // esconder esa línea como si fuera redundante.
    const grupos = [grupo('RARO', ['140'], [{ cantidad: 6, precio: 900 }, { cantidad: 12, precio: 950 }])]
    expect(condicion(codito, grupos)).toEqual([
      'Desde 6 u. $ 900,00 c/u',
      'Desde 12 u. $ 950,00 c/u',
    ])
  })

  it('una escala combinada (mínimos por producto o varios sabores distintos) se describe con describirReglaEscala', () => {
    const otro = producto('201', 'OTRO', 1030)
    const escala = { cantidad: 12, precio: 800, minProductosDistintos: 2 }
    const grupos = [grupo('COMBINADA', ['140', '201'], [escala])]
    const esperado = describirReglaEscala({
      cantidadMinima: 12,
      precioUnitario: 800,
      etiqueta: null,
      minProductosDistintos: 2,
      minimosPorProducto: new Map(),
    })
    expect(condicion(codito, grupos, [codito, otro])).toEqual(sinEspacioDuro([esperado]))
  })

  // --- Configuraciones que hoy no existen en prod pero se pueden cargar desde
  // --- el panel de condiciones (revisión adversarial del 2026-10-13).

  it('una escala mayor que vuelve al precio de lista corta el descuento, y la lista lo dice', () => {
    // Dentro del grupo manda la escala de mayor cantidad: con 12 u. el pedido
    // cobra $1.030, el precio de lista.
    const grupos = [grupo('RARO', ['140'], [{ cantidad: 6, precio: 800 }, { cantidad: 12, precio: 1100 }])]
    expect(condicion(codito, grupos)).toEqual([
      'Desde 6 u. $ 800,00 c/u',
      'Desde 12 u. $ 1.030,00 c/u',
    ])
  })

  it('una escala con mínimos por sabor que se alcanza con el producto solo tiene su línea "Desde"', () => {
    const otro = producto('201', 'OTRO', 1030)
    const grupos = [grupo('MIXTA', ['140', '201'], [
      { cantidad: 6, precio: 900 },
      // Sólo le pide un mínimo al OTRO sabor: 10 u. de CODITO solo la alcanzan.
      { cantidad: 10, precio: 800, minimos: [{ productoId: '201', cantidad: 5 }] },
    ])]
    expect(condicion(codito, grupos, [codito, otro])).toEqual([
      'Desde 6 u. $ 900,00 c/u',
      'Desde 10 u. $ 800,00 c/u',
      'surtido con 2 sabores',
    ])
  })

  it('una escala con mínimo que cambia el precio del pedido no queda escondida detrás de la otra', () => {
    const otro = producto('201', 'OTRO', 1030)
    const grupos = [grupo('MIXTA', ['140', '201'], [
      { cantidad: 6, precio: 800 },
      // Con 10 u. de CODITO (y su mínimo de 3 cumplido) manda ésta: $950.
      { cantidad: 10, precio: 950, minimos: [{ productoId: '140', cantidad: 3 }] },
    ])]
    expect(condicion(codito, grupos, [codito, otro])).toEqual([
      'Desde 6 u. $ 800,00 c/u',
      'Desde 10 u. $ 950,00 c/u',
      'surtido con 2 sabores',
    ])
  })

  it('si el mínimo propio supera la cantidad de la escala, la línea arranca en el mínimo', () => {
    const grupos = [grupo('MINIMO', ['140'], [
      { cantidad: 10, precio: 800, minimos: [{ productoId: '140', cantidad: 12 }] },
    ])]
    expect(condicion(codito, grupos)).toEqual(['Desde 12 u. $ 800,00 c/u'])
  })

  it('una escala que pide más sabores distintos de los que hay activos no se puede alcanzar: no se muestra', () => {
    const inactivo = producto('201', 'VIEJO', 1030, { activo: false })
    const grupos = [grupo('IMPOSIBLE', ['140', '201'], [{ cantidad: 12, precio: 800, minProductosDistintos: 2 }])]
    expect(condicion(codito, grupos, [codito, inactivo])).toEqual([])
  })

  it('la regla de una escala de varios sabores no nombra productos desactivados, y el surtido va en cada línea', () => {
    const otro = producto('201', 'OTRO', 1030)
    const inactivo = producto('202', 'VIEJO', 1030, { activo: false })
    const grupos = [grupo('COMBINADA', ['140', '201', '202'], [
      { cantidad: 6, precio: 900 },
      {
        cantidad: 12,
        precio: 800,
        minProductosDistintos: 2,
        minimos: [{ productoId: '201', cantidad: 5 }, { productoId: '202', cantidad: 5 }],
      },
    ])]
    const regla = describirReglaEscala({
      cantidadMinima: 12,
      precioUnitario: 800,
      etiqueta: null,
      minProductosDistintos: 2,
      minimosPorProducto: new Map([['201', { cantidad: 5, precioOverride: null }]]),
    }, { nombresProductos: new Map([['140', 'CODITO COTELLA 500GRS'], ['201', 'OTRO']]) })
    const lineas = condicion(codito, grupos, [codito, otro, inactivo])
    expect(lineas).toEqual(sinEspacioDuro([
      // Con una regla aparte, "surtido con N sabores" suelto al final se
      // leería como parte de esa regla.
      'Desde 6 u. $ 900,00 c/u, surtido con 2 sabores',
      regla,
    ]))
    expect(lineas.join(' ')).not.toMatch(/VIEJO|#202/)
  })

  it('un sabor sin precio no se lista, así que tampoco cuenta para el surtido', () => {
    const sinPrecio = producto('201', 'SIN PRECIO', 0)
    const grupos = [grupo('PAPAS', ['140', '201'], [{ cantidad: 6, precio: 990 }])]
    expect(condicion(codito, grupos, [codito, sinPrecio])).toEqual(['Desde 6 u. $ 990,00 c/u'])
  })

  // --- Decisiones del dueño del 2026-10-13 (#1120).

  it('con un mínimo de venta mayor que la primera escala, las escalas arrancan en el mínimo', () => {
    // El pedido no deja cargar menos de 12: "Desde 6 u." no se puede comprar.
    const conMinimo = { ...codito, cantidad_minima_venta: 12 }
    const grupos = [grupo('1/2 FARDO', ['140'], [{ cantidad: 6, precio: 990 }])]
    expect(condicion(conMinimo, grupos)).toEqual(['Desde 12 u. $ 990,00 c/u'])
  })

  it('las escalas que el mínimo deja atrás se pliegan en la primera línea, con el precio del mínimo', () => {
    const grupos = [
      grupo('1/2 FARDO', ['140'], [{ cantidad: 6, precio: 990 }]),
      grupo('FARDO', ['140'], [{ cantidad: 12, precio: 950 }]),
      grupo('2 FARDOS', ['140'], [{ cantidad: 24, precio: 900 }]),
    ]
    expect(condicion({ ...codito, cantidad_minima_venta: 8 }, grupos)).toEqual([
      'Desde 8 u. $ 990,00 c/u',
      'Desde 12 u. $ 950,00 c/u',
      'Desde 24 u. $ 900,00 c/u',
    ])
    expect(condicion({ ...codito, cantidad_minima_venta: '15' }, grupos)).toEqual([
      'Desde 15 u. $ 950,00 c/u',
      'Desde 24 u. $ 900,00 c/u',
    ])
  })

  it('un mínimo por debajo de la primera escala no cambia nada (hoy, los 34 productos con mínimo)', () => {
    const grupos = [
      grupo('1/2 FARDO', ['140'], [{ cantidad: 6, precio: 990 }]),
      grupo('FARDO', ['140'], [{ cantidad: 12, precio: 950 }]),
    ]
    expect(condicion({ ...codito, cantidad_minima_venta: 3 }, grupos)).toEqual([
      'Desde 6 u. $ 990,00 c/u',
      'Desde 12 u. $ 950,00 c/u',
    ])
  })

  it('la lista no mira promociones: el mayorista que muestra se cobra quitando la promo del pedido', () => {
    // Decisión del dueño: queda como está. Si el pedido dispara una promo sobre
    // el producto, cobra precio de lista + regalo; quien arma el pedido puede
    // quitar la promo, y entonces cobra lo que dice la lista.
    const grupos = [grupo('FARDO', ['140'], [{ cantidad: 12, precio: 950 }])]
    expect(condicion(codito, grupos)).toEqual(['Desde 12 u. $ 950,00 c/u'])

    const g = grupos[0]
    const pricingMap: PricingMap = new Map([['140', [{
      grupoId: g.id,
      grupoNombre: g.nombre,
      productoIds: ['140'],
      escalas: [{ cantidadMinima: 12, precioUnitario: 950, etiqueta: null, minProductosDistintos: 1, minimosPorProducto: new Map() }],
    }]]])
    const promoMap: PromoMap = new Map([['140', [{
      id: 'promo-12+1',
      nombre: '12+1',
      tipo: 'bonificacion',
      productoIds: ['140'],
      reglas: { cantidad_compra: 12, cantidad_bonificacion: 1 },
    }]]])
    const precioDelPedido = (promosEliminadas?: Set<string>) => orquestarPrecios({
      items: [{ productoId: '140', cantidad: 12, precioUnitario: 1030 }],
      pricingMap,
      promoMap,
      promosEliminadas,
    }).items.find(i => i.productoId === '140' && !i.esBonificacion)?.precioUnitario

    expect(precioDelPedido()).toBe(1030)
    expect(precioDelPedido(new Set(['promo-12+1']))).toBe(950)
  })

  it('cada línea es el precio que da el motor del pedido al cargar esa cantidad del producto', () => {
    const grupos = [
      grupo('A', ['140'], [{ cantidad: 6, precio: 990 }, { cantidad: 30, precio: 905 }]),
      grupo('B', ['140', '201'], [{ cantidad: 12, precio: 950 }]),
      grupo('C', ['140'], [{ cantidad: 24, precio: 960 }]),
    ]
    const pricingMap: PricingMap = new Map([[
      '140',
      grupos.map(g => ({
        grupoId: g.id,
        grupoNombre: g.nombre,
        productoIds: g.productos.map(p => p.producto_id),
        escalas: g.escalas.map(e => ({
          cantidadMinima: e.cantidad_minima,
          precioUnitario: e.precio_unitario,
          etiqueta: null,
          minProductosDistintos: 1,
          minimosPorProducto: new Map(),
        })),
      })),
    ]])
    const lineas = condicion(codito, grupos, [codito, producto('201', 'OTRO', 1030)])
    // El 24 a $960 no baja de $950 (que ya rige desde 12): no se muestra.
    expect(lineas).toEqual([
      'Desde 6 u. $ 990,00 c/u',
      'Desde 12 u. $ 950,00 c/u, surtido con 2 sabores',
      'Desde 30 u. $ 905,00 c/u',
    ])
    for (const [cantidad, precio] of [[6, 990], [12, 950], [24, 950], [30, 905]] as const) {
      const resuelto = resolverPreciosMayorista(
        [{ productoId: '140', cantidad, precioUnitario: 1030 }],
        pricingMap,
      ).get('140')
      expect(resuelto?.precioResuelto).toBe(precio)
    }
  })
})

describe('armarListaPrecios \u2014 secciones', () => {
  const nombresSubrubro = new Map([['sub-500', 'FIDEOS x 500 gr'], ['sub-5k', 'FIDEOS x 5 kg']])

  it('sólo productos activos (activo ausente cuenta como activo) y con precio cargado', () => {
    const secciones = armarListaPrecios({
      productos: [
        producto('1', 'ACTIVO', 100, { categoria: 'A' }),
        producto('2', 'SIN DATO DE ACTIVO', 100, { categoria: 'A', activo: undefined }),
        producto('3', 'DESACTIVADO', 100, { categoria: 'A', activo: false }),
        producto('4', 'SIN PRECIO', 0, { categoria: 'A' }),
        producto('5', 'PRECIO NULO', null, { categoria: 'A' }),
      ],
      grupos: [],
    })
    expect(secciones.flatMap(s => s.filas.map(f => f.nombre))).toEqual(['ACTIVO', 'SIN DATO DE ACTIVO'])
  })

  it('rubros alfabéticos; dentro del rubro, lo sin subrubro primero y después los subrubros', () => {
    const secciones = armarListaPrecios({
      productos: [
        producto('1', 'SPAGHETTI', 100, { categoria: 'FIDEOS', subcategoria_id: 'sub-500' }),
        producto('2', 'FIDEO SUELTO', 100, { categoria: 'FIDEOS' }),
        producto('3', 'CODITO 5KG', 100, { categoria: 'FIDEOS', subcategoria_id: 'sub-5k' }),
        producto('4', 'ALFAJOR', 100, { categoria: 'ALFAJORES' }),
        producto('5', 'MONO', 100, { categoria: 'FIDEOS', subcategoria_id: 'sub-500' }),
      ],
      grupos: [],
      nombresSubrubro,
    })
    expect(secciones.map(s => [s.rubro, s.subrubro, s.filas.map(f => f.nombre)])).toEqual([
      ['ALFAJORES', null, ['ALFAJOR']],
      ['FIDEOS', null, ['FIDEO SUELTO']],
      ['FIDEOS', 'FIDEOS x 5 kg', ['CODITO 5KG']],
      ['FIDEOS', 'FIDEOS x 500 gr', ['MONO', 'SPAGHETTI']],
    ])
  })

  it('los productos sin categoría van en "Otros", al final aunque el abecedario diga otra cosa', () => {
    const secciones = armarListaPrecios({
      productos: [
        producto('1', 'SIN RUBRO', 100),
        producto('2', 'EN BLANCO', 100, { categoria: '   ' }),
        producto('3', 'SOLO SUBRUBRO', 100, { subcategoria_id: 'sub-500' }),
        producto('4', 'ZAPALLO', 100, { categoria: 'ZAPALLOS' }),
        producto('5', 'PAPA', 100, { categoria: 'PAPAS' }),
      ],
      grupos: [],
      nombresSubrubro,
    })
    expect(secciones.map(s => s.rubro)).toEqual(['PAPAS', 'ZAPALLOS', TITULO_SIN_CATEGORIA])
    const otros = secciones[secciones.length - 1]
    expect(otros.sinCategoria).toBe(true)
    expect(otros.subrubro).toBeNull()
    expect(otros.filas.map(f => f.nombre)).toEqual(['EN BLANCO', 'SIN RUBRO', 'SOLO SUBRUBRO'])
  })

  it('un rubro que se llama "Otros" va junto con los sin categoría, en un solo "Otros" al final (#1120)', () => {
    // Decisión del dueño (2026-10-13): dos secciones "Otros" confunden al cliente.
    const secciones = armarListaPrecios({
      productos: [
        producto('1', 'SIN RUBRO', 100),
        producto('2', 'DE OTROS', 100, { categoria: 'Otros' }),
        producto('3', 'DE OTROS EN MAYUSCULAS', 100, { categoria: ' OTROS ' }),
        producto('4', 'ZAPALLO', 100, { categoria: 'ZAPALLOS' }),
      ],
      grupos: [],
    })
    expect(secciones.map(s => [s.rubro, s.sinCategoria, s.subrubro, s.filas.map(f => f.nombre)])).toEqual([
      ['ZAPALLOS', false, null, ['ZAPALLO']],
      [TITULO_SIN_CATEGORIA, true, null, ['DE OTROS', 'DE OTROS EN MAYUSCULAS', 'SIN RUBRO']],
    ])
  })

  it('los subrubros del rubro "Otros" quedan como subrubros dentro del "Otros" del final', () => {
    const secciones = armarListaPrecios({
      productos: [
        producto('1', 'SIN RUBRO', 100),
        producto('2', 'VELA', 100, { categoria: 'Otros', subcategoria_id: 'sub-velas' }),
        producto('3', 'AGUA', 100, { categoria: 'AGUAS' }),
      ],
      grupos: [],
      nombresSubrubro: new Map([['sub-velas', 'Velas']]),
    })
    expect(secciones.map(s => [s.rubro, s.sinCategoria, s.subrubro, s.filas.map(f => f.nombre)])).toEqual([
      ['AGUAS', false, null, ['AGUA']],
      [TITULO_SIN_CATEGORIA, true, null, ['SIN RUBRO']],
      [TITULO_SIN_CATEGORIA, true, 'Velas', ['VELA']],
    ])
  })

  it('un subrubro que no está en el mapa se trata como sin subrubro', () => {
    const secciones = armarListaPrecios({
      productos: [producto('1', 'X', 100, { categoria: 'A', subcategoria_id: 'no-existe' })],
      grupos: [],
      nombresSubrubro,
    })
    expect(secciones).toEqual([
      { rubro: 'A', subrubro: null, sinCategoria: false, filas: [{ nombre: 'X', precio: 100, condicion: [] }] },
    ])
  })

  it('las filas llevan el nombre sin espacios sobrantes, el precio como número y la condición', () => {
    const [seccion] = armarListaPrecios({
      productos: [codito],
      grupos: [grupo('CODITO 1/2 FARDO', ['140'], [{ cantidad: 6, precio: 990 }])],
    })
    expect(seccion.filas).toEqual([
      { nombre: 'CODITO COTELLA 500GRS', precio: 1030, condicion: [expect.stringMatching(/^Desde 6 u\. \$\s990,00 c\/u$/)] },
    ])
  })

  it('ningún campo prohibido llega a la salida, aunque venga en la entrada', () => {
    // Un ProductoDB entero, con todo lo que la lista NO puede mostrar.
    const productoCompleto = {
      ...producto('77', 'GASEOSA', 1500, { categoria: 'BEBIDAS' }),
      stock: 987654,
      stock_minimo: 13579,
      costo_real: 111.11,
      costo_promedio: 222.22,
      costo_sin_iva: 333.33,
      costo_con_iva: 444.44,
      codigo: 'COD-SECRETO',
      proveedor_id: 'prov-secreto',
      proveedor: { nombre: 'PROVEEDOR SECRETO' },
      promocion: 'PROMO SECRETA',
      // El mínimo de venta entra (#1120: las escalas arrancan en él) pero no se
      // muestra como dato. Va por debajo de la escala para que no la mueva.
      cantidad_minima_venta: 2,
      unidades_por_bulto: 97531,
      etiqueta_bulto: 'BULTO SECRETO',
    } as unknown as ProductoListaPrecios
    const secciones = armarListaPrecios({
      productos: [productoCompleto],
      grupos: [grupo('MAYORISTA', ['77'], [{ cantidad: 6, precio: 1400 }])],
    })

    for (const seccion of secciones) {
      expect(Object.keys(seccion).sort()).toEqual(['filas', 'rubro', 'sinCategoria', 'subrubro'])
      for (const fila of seccion.filas) {
        expect(Object.keys(fila).sort()).toEqual(['condicion', 'nombre', 'precio'])
      }
    }
    const salida = JSON.stringify(secciones)
    for (const prohibido of [
      'stock', 'costo', 'codigo', 'proveedor', 'promo', 'minima', 'bulto', 'id',
      '987654', '13579', '111.11', '222.22', '333.33', '444.44', 'COD-SECRETO', 'prov-secreto',
      'PROVEEDOR SECRETO', 'PROMO SECRETA', '97531', 'BULTO SECRETO', 'MAYORISTA',
    ]) {
      expect(salida).not.toContain(prohibido)
    }
    expect(salida).not.toMatch(/m[ií]nimo/i)
  })
})
