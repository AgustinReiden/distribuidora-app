/**
 * Tests del criterio de cliente duplicado.
 *
 * Los casos con datos reales salen de prod (proyecto ManaosApp, sucursal 1) y
 * están duplicados en el bloque DO de la migración: si alguien cambia una de
 * las dos mitades y no la otra, uno de los dos lados se pone rojo.
 */

import { describe, it, expect } from 'vitest'
import { haversineMeters } from './geo'
import {
  DUPLICADO_AVISO_METROS,
  DUPLICADO_BLOQUEO_METROS,
  boxParaRadio,
  cambiaIdentidadDuplicado,
  clasificarDuplicado,
  claveDireccionConAltura,
  mensajeDuplicado,
  type CandidatoDuplicado,
} from './duplicadoCliente'

// Los dos clientes del incidente: misma puerta, dos altas, 17,5 m.
const CLIENTE_382: CandidatoDuplicado = {
  id: '382',
  direccion: 'Pje. Vera y Aragon 2551, T4002AFE San Miguel de Tucumán, Tucumán, Argentina',
  latitud: -26.8375488,
  longitud: -65.2396541,
  activo: true,
}

const ALTA_938 = {
  direccion: 'Pje. Vera y Aragon 2551, T4002AFE San Miguel de Tucumán, Tucumán, Argentina',
  latitud: -26.8375164,
  longitud: -65.2398268,
}

describe('claveDireccionConAltura', () => {
  it('normaliza el primer segmento de la dirección formateada de Google', () => {
    expect(claveDireccionConAltura(CLIENTE_382.direccion)).toBe('pje vera y aragon 2551')
  })

  it('da la misma clave para las dos altas del par 382/938', () => {
    expect(claveDireccionConAltura(ALTA_938.direccion)).toBe(
      claveDireccionConAltura(CLIENTE_382.direccion),
    )
  })

  it('devuelve null sin altura: un barrio no es una puerta', () => {
    // 170 clientes de la sucursal 2 comparten estas direcciones sin numeración.
    expect(claveDireccionConAltura('B° Esperanza')).toBeNull()
    expect(claveDireccionConAltura('B° Sagrado Corazón, Tucumán, Argentina')).toBeNull()
    expect(claveDireccionConAltura('')).toBeNull()
    expect(claveDireccionConAltura(null)).toBeNull()
  })

  it('ignora acentos, puntuación y espacios de más', () => {
    expect(claveDireccionConAltura('  Av.   Benjamín   Aráoz  800 , Tucumán')).toBe(
      'av benjamin araoz 800',
    )
  })
})

describe('boxParaRadio', () => {
  it('el semieje de longitud es más ancho que el de latitud fuera del ecuador', () => {
    const { dlat, dlng } = boxParaRadio(-26.8375, 30)
    expect(dlng).toBeGreaterThan(dlat)
  })

  it('el box cubre de verdad el radio pedido en los dos ejes', () => {
    const lat = -26.8375
    const lng = -65.2396
    const { dlat, dlng } = boxParaRadio(lat, 30)
    expect(haversineMeters({ lat, lng }, { lat: lat + dlat, lng })).toBeGreaterThanOrEqual(29.9)
    expect(haversineMeters({ lat, lng }, { lat, lng: lng + dlng })).toBeGreaterThanOrEqual(29.9)
  })
})

describe('clasificarDuplicado — el par 382/938', () => {
  it('están a ~17,5 m, que el detector viejo (0,2 m) no veía', () => {
    const d = haversineMeters(
      { lat: CLIENTE_382.latitud!, lng: CLIENTE_382.longitud! },
      { lat: ALTA_938.latitud, lng: ALTA_938.longitud },
    )
    expect(d).toBeGreaterThan(17)
    expect(d).toBeLessThan(18)
  })

  it('BLOQUEA por dirección con altura', () => {
    const v = clasificarDuplicado(ALTA_938, [CLIENTE_382])
    expect(v.bloquea).toBe(true)
    expect(v.avisa).toBe(false)
    expect(v.motivo).toBe('direccion')
    expect(v.distancia_m).toBeGreaterThan(17)
    expect(v.distancia_m).toBeLessThan(18)
    expect(v.candidato?.id).toBe('382')
  })

  // Los dos se llamaban casi igual ("Ricardo" / "Lopez Ricardo") y eso ya no
  // interviene: lo que los une es la puerta.
  it('el motivo es la dirección, que es lo accionable', () => {
    expect(clasificarDuplicado(ALTA_938, [CLIENTE_382]).motivo).toBe('direccion')
  })
})

describe('clasificarDuplicado — dirección sin altura', () => {
  it('"B° Esperanza" contra otro "B° Esperanza" NO bloquea por dirección', () => {
    const vecino: CandidatoDuplicado = {
      id: '500',
      direccion: 'B° Esperanza',
      latitud: -26.9,
      longitud: -65.3,
      activo: true,
    }
    const v = clasificarDuplicado(
      {
        direccion: 'B° Esperanza',
        // A 200 m: fuera de la banda de aviso, así que el veredicto es limpio.
        latitud: -26.9018,
        longitud: -65.3,
      },
      [vecino],
    )
    expect(v.bloquea).toBe(false)
    expect(v.avisa).toBe(false)
    expect(v.motivo).toBeNull()
  })
})

describe('clasificarDuplicado — distancia', () => {
  const base = { lat: -26.8375, lng: -65.2396 }

  function aMetros(metros: number): CandidatoDuplicado {
    const { dlat } = boxParaRadio(base.lat, metros)
    return {
      id: '900',
      direccion: 'Otra Calle 123',
      latitud: base.lat + dlat,
      longitud: base.lng,
      activo: true,
    }
  }

  const alta = {
    razon_social: 'Kiosco La Esquina',
    direccion: 'Alguna Calle 999',
    latitud: base.lat,
    longitud: base.lng,
  }

  it('a 5 m AVISA y no bloquea — ahí viven comercios vecinos legítimos', () => {
    const v = clasificarDuplicado(alta, [aMetros(5)])
    expect(v.bloquea).toBe(false)
    expect(v.avisa).toBe(true)
    expect(v.motivo).toBe('distancia')
    expect(v.distancia_m).toBeGreaterThan(4.5)
    expect(v.distancia_m).toBeLessThan(5.5)
  })

  it('a 1,4 m (el kiosco y la fiambrería reales) todavía avisa, no bloquea', () => {
    const v = clasificarDuplicado(alta, [aMetros(1.4)])
    expect(v.bloquea).toBe(false)
    expect(v.avisa).toBe(true)
  })

  it('a 0,5 m BLOQUEA: es el mismo punto', () => {
    const v = clasificarDuplicado(alta, [aMetros(0.5)])
    expect(v.bloquea).toBe(true)
    expect(v.motivo).toBe('punto')
    expect(v.distancia_m).toBeLessThan(DUPLICADO_BLOQUEO_METROS)
  })

  it('a 60 m no dice nada', () => {
    const v = clasificarDuplicado(alta, [aMetros(60)])
    expect(v.bloquea).toBe(false)
    expect(v.avisa).toBe(false)
    expect(v.motivo).toBeNull()
  })

  it('justo afuera de la banda de aviso no dice nada', () => {
    const v = clasificarDuplicado(alta, [aMetros(DUPLICADO_AVISO_METROS + 5)])
    expect(v.avisa).toBe(false)
  })

  it('elige al más cercano cuando hay varios', () => {
    const lejos = { ...aMetros(25), id: '901' }
    const cerca = { ...aMetros(4), id: '902' }
    const v = clasificarDuplicado(alta, [lejos, cerca])
    expect(v.candidato?.id).toBe('902')
  })
})

describe('clasificarDuplicado — el nombre no es parte del criterio (mig 260)', () => {
  // Existió de la mig 250 a la 260 y se sacó porque marcaba homónimos: en prod
  // había 375 clientes con un vecino de nombre solapado y 116 con uno idéntico
  // —cuatro comercios distintos se llaman "Cristian"—. Un nombre repetido no es
  // un duplicado. Estos tests fijan que no vuelva por la ventana.
  const lejano = { latitud: -26.9, longitud: -65.4 }

  it('dos clientes con el MISMO nombre en direcciones distintas no son duplicado', () => {
    const v = clasificarDuplicado(
      { direccion: 'Calle Nueva 45', ...lejano },
      [{ id: '18', direccion: 'Otra Calle 1', latitud: -26.8, longitud: -65.2 }],
    )
    expect(v.bloquea).toBe(false)
    expect(v.avisa).toBe(false)
    expect(v.motivo).toBeNull()
  })

  it('tampoco un nombre contenido en el otro', () => {
    const v = clasificarDuplicado(
      { direccion: 'Calle Nueva 45', ...lejano },
      [{ id: '77', direccion: 'Otra 1', latitud: -26.8, longitud: -65.2 }],
    )
    expect(v.motivo).toBeNull()
  })

  // La red de seguridad: si alguien vuelve a meter un campo de nombre en la
  // entrada, el criterio lo ignora en vez de empezar a opinar de nuevo.
  it('un nombre en la entrada no cambia el veredicto', () => {
    const conNombre = { direccion: 'Calle Nueva 45', ...lejano, razon_social: 'Cristian' }
    const sinNombre = { direccion: 'Calle Nueva 45', ...lejano }
    const candidatos = [{ id: '18', direccion: 'Otra 1', latitud: -26.8, longitud: -65.2, razon_social: 'Cristian' }]
    expect(clasificarDuplicado(conNombre, candidatos)).toEqual(clasificarDuplicado(sinNombre, candidatos))
  })

  it('ve a los inactivos: se reactiva, no se clona', () => {
    const v = clasificarDuplicado(ALTA_938, [{ ...CLIENTE_382, activo: false }])
    expect(v.bloquea).toBe(true)
    expect(v.candidato?.activo).toBe(false)
  })
})

describe('clasificarDuplicado — sin hallazgo', () => {
  it('sin candidatos no dice nada', () => {
    expect(clasificarDuplicado(ALTA_938, []).motivo).toBeNull()
  })

  it('un alta sin coordenadas sigue bloqueando por dirección', () => {
    const v = clasificarDuplicado(
      { direccion: 'Pje. Vera y Aragon 2551, Tucumán' },
      [CLIENTE_382],
    )
    expect(v.bloquea).toBe(true)
    expect(v.motivo).toBe('direccion')
    expect(v.distancia_m).toBeNull()
  })
})


describe('cambiaIdentidadDuplicado — el guard rige el alta y la mudanza', () => {
  // El caso real: cliente #316, reasignado de un preventista a otro. El vecino
  // "Cristian" (#18) tiene un nombre que se solapa con "PUENTE CRISTIAN" y el
  // aviso saltaba en cada edición, aunque el cliente lleve años conviviendo
  // con él.
  const PUENTE_CRISTIAN = {
    direccion: 'Chiclana 1895, T4000 San Miguel de Tucumán, Tucumán, Argentina',
    latitud: -26.8355312,
    longitud: -65.2223494,
  }

  it('reasignar el preventista no cambia nada de lo que el criterio mira', () => {
    expect(cambiaIdentidadDuplicado(PUENTE_CRISTIAN, { ...PUENTE_CRISTIAN })).toBe(false)
  })

  it('un cambio cosmético de la dirección tampoco', () => {
    expect(cambiaIdentidadDuplicado(PUENTE_CRISTIAN, {
      ...PUENTE_CRISTIAN,
      direccion: 'CHICLANA 1895, Tucumán',
    })).toBe(false)
  })

  it('`undefined` y `null` son lo mismo: un cliente sin coordenadas no "cambia"', () => {
    expect(cambiaIdentidadDuplicado(
      { direccion: 'B° Esperanza', latitud: null, longitud: null },
      { direccion: 'B° Esperanza' },
    )).toBe(false)
  })

  it('mudarlo a otra puerta sí', () => {
    expect(cambiaIdentidadDuplicado(PUENTE_CRISTIAN, {
      ...PUENTE_CRISTIAN,
      direccion: 'Chiclana 1897, T4000 San Miguel de Tucumán, Tucumán, Argentina',
    })).toBe(true)
  })

  it('moverle las coordenadas sí, aunque la dirección quede igual', () => {
    expect(cambiaIdentidadDuplicado(PUENTE_CRISTIAN, {
      ...PUENTE_CRISTIAN,
      latitud: -26.8375488,
    })).toBe(true)
  })

  // Desde la mig 260 el nombre no entra al criterio, así que renombrar a un
  // cliente no puede cambiar ningún veredicto y no tiene por qué consultar.
  it('renombrar al cliente no es un cambio de identidad', () => {
    const renombrado = { ...PUENTE_CRISTIAN } as Record<string, unknown>
    renombrado.razon_social = 'OTRO NOMBRE COMPLETAMENTE DISTINTO'
    renombrado.nombre_fantasia = 'Y OTRA FANTASÍA'
    expect(cambiaIdentidadDuplicado(PUENTE_CRISTIAN, renombrado)).toBe(false)
  })

  // Sin altura la dirección no entra al criterio: cambiarla por otra sin altura
  // no mueve nada, y ya no queda ninguna otra regla que pueda mirar.
  it('con dirección sin altura, cambiarla por otra sin altura no cuenta', () => {
    const base = { direccion: 'B° Esperanza' }
    expect(cambiaIdentidadDuplicado(base, { direccion: 'B° Sagrado Corazón' })).toBe(false)
    expect(cambiaIdentidadDuplicado(base, { direccion: 'B° Esperanza 250' })).toBe(true)
  })
})


describe('mensajeDuplicado — el número que se muestra es el CÓDIGO, no el id', () => {
  // El id de `clientes` no aparece en ninguna pantalla: la lista muestra
  // `#codigo` y el buscador filtra por código. Son dos secuencias distintas y
  // en los 730 clientes de prod no coinciden ni una vez, así que imprimir el id
  // mandaba al usuario a buscar un número que da con OTRO comercio. El caso
  // testigo: el aviso decía "(#18)" de un cliente que en la app es el #10.
  const veredicto = (over: Record<string, unknown> = {}) => ({
    bloquea: false,
    avisa: true,
    motivo: 'distancia' as const,
    distancia_m: null,
    cliente_visible: { id: 18, codigo: 10, nombre: 'Cristian', activo: true },
    ...over,
  })

  it('imprime el código del vecino', () => {
    expect(mensajeDuplicado(veredicto()).mensaje).toContain('"Cristian" (#10)')
  })

  it('no imprime el id por ningún lado', () => {
    expect(mensajeDuplicado(veredicto()).mensaje).not.toContain('#18')
  })

  it('lo mismo en los tres motivos', () => {
    for (const motivo of ['direccion', 'punto', 'distancia'] as const) {
      const m = mensajeDuplicado(veredicto({ motivo, distancia_m: 5.2 })).mensaje
      expect(m).toContain('(#10)')
      expect(m).not.toContain('#18')
    }
  })

  it('y en el mensaje del inactivo, que es el que manda a buscarlo a mano', () => {
    const m = mensajeDuplicado(veredicto({
      cliente_visible: { id: 18, codigo: 10, nombre: 'Cristian', activo: false },
    }))
    expect(m.titulo).toMatch(/inactivo/i)
    expect(m.mensaje).toContain('(#10)')
  })

  // Un bundle nuevo contra la RPC vieja, en la ventana entre los dos deploys.
  // Mejor sin número que con uno que lleva a otro cliente.
  it('sin código, nombra al vecino y no inventa un número', () => {
    const m = mensajeDuplicado(veredicto({
      cliente_visible: { id: 18, nombre: 'Cristian', activo: true },
    })).mensaje
    expect(m).toContain('"Cristian"')
    expect(m).not.toContain('#')
  })

  // La otra mitad de la regla, que ya fijaba el #543: si la RLS tapa al vecino,
  // no se lo nombra ni con código ni con id.
  it('si el vecino está tapado, no va ni el nombre ni ningún número', () => {
    const m = mensajeDuplicado(veredicto({ cliente_visible: null })).mensaje
    expect(m).not.toContain('Cristian')
    expect(m).not.toContain('#')
    expect(m).toMatch(/administración/)
  })
})
