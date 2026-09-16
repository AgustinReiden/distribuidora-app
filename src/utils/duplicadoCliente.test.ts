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
  compararNombres,
  normalizarNombre,
  tokensNombre,
  type CandidatoDuplicado,
} from './duplicadoCliente'

// Los dos clientes del incidente: misma puerta, dos altas, 17,5 m.
const CLIENTE_382: CandidatoDuplicado = {
  id: '382',
  razon_social: 'Lopez Ricardo',
  nombre_fantasia: 'PASAJE VERA Y ARAGON 2551',
  direccion: 'Pje. Vera y Aragon 2551, T4002AFE San Miguel de Tucumán, Tucumán, Argentina',
  latitud: -26.8375488,
  longitud: -65.2396541,
  activo: true,
}

const ALTA_938 = {
  razon_social: 'Ricardo',
  nombre_fantasia: 'López Ricardo ',
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

describe('normalizarNombre / tokensNombre', () => {
  it('saca acentos, mayúsculas y el espacio final que traía el 938', () => {
    expect(normalizarNombre('López Ricardo ')).toBe('lopez ricardo')
  })

  it('los tokens no se repiten', () => {
    expect(tokensNombre('Kiosco kiosco JUAN')).toEqual(['kiosco', 'juan'])
  })
})

describe('compararNombres', () => {
  it('"López Ricardo " y "Lopez Ricardo" son el mismo nombre', () => {
    expect(compararNombres('López Ricardo ', 'Lopez Ricardo')).toBe('igual')
  })

  it('"Ricardo" está contenido en "Lopez Ricardo": subconjunto, no igualdad', () => {
    expect(compararNombres('Ricardo', 'Lopez Ricardo')).toBe('subconjunto')
  })

  it('"Kiosco" dentro de "Kiosco Juan" es subconjunto — por eso nunca bloquea', () => {
    expect(compararNombres('Kiosco', 'Kiosco Juan')).toBe('subconjunto')
  })

  it('nombres sin relación son distintos', () => {
    expect(compararNombres('Panadería Nahuel', 'Pollería M&G')).toBe('distinto')
  })

  it('un nombre vacío no relaciona con nada', () => {
    expect(compararNombres('', 'Lopez Ricardo')).toBe('distinto')
    expect(compararNombres(null, null)).toBe('distinto')
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

  it('la dirección gana sobre el nombre: el motivo es el que ataja el caso', () => {
    // El nombre también daría bloqueo ("López Ricardo " = "Lopez Ricardo"),
    // pero el motivo que se le muestra al usuario es el accionable.
    const v = clasificarDuplicado(ALTA_938, [CLIENTE_382])
    expect(v.motivo).toBe('direccion')
  })
})

describe('clasificarDuplicado — dirección sin altura', () => {
  it('"B° Esperanza" contra otro "B° Esperanza" NO bloquea por dirección', () => {
    const vecino: CandidatoDuplicado = {
      id: '500',
      razon_social: 'Kiosco Marta',
      direccion: 'B° Esperanza',
      latitud: -26.9,
      longitud: -65.3,
      activo: true,
    }
    const v = clasificarDuplicado(
      {
        razon_social: 'Despensa Nélida',
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
      razon_social: 'Fiambrería del Centro',
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

describe('clasificarDuplicado — nombre', () => {
  // Lejos, para que la distancia no tape el motivo del nombre.
  const lejano = { latitud: -26.9, longitud: -65.4 }

  it('"López Ricardo " contra "Lopez Ricardo" BLOQUEA', () => {
    const v = clasificarDuplicado(
      { razon_social: 'López Ricardo ', direccion: 'Calle Nueva 45', ...lejano },
      [{ ...CLIENTE_382, latitud: -26.8, longitud: -65.2 }],
    )
    expect(v.bloquea).toBe(true)
    expect(v.motivo).toBe('nombre_igual')
  })

  it('"Ricardo" contra "Lopez Ricardo" AVISA, no bloquea', () => {
    const v = clasificarDuplicado(
      { razon_social: 'Ricardo', direccion: 'Calle Nueva 45', ...lejano },
      [{ ...CLIENTE_382, nombre_fantasia: null, latitud: -26.8, longitud: -65.2 }],
    )
    expect(v.bloquea).toBe(false)
    expect(v.avisa).toBe(true)
    expect(v.motivo).toBe('nombre_subconjunto')
  })

  it('"Kiosco" contra "Kiosco Juan" avisa: nunca bloqueo', () => {
    const v = clasificarDuplicado(
      { razon_social: 'Kiosco', direccion: 'Calle Nueva 45', ...lejano },
      [{ id: '77', razon_social: 'Kiosco Juan', direccion: 'Otra 1', latitud: -26.8, longitud: -65.2 }],
    )
    expect(v.bloquea).toBe(false)
    expect(v.avisa).toBe(true)
  })

  it('cruza razón social contra nombre de fantasía en los dos sentidos', () => {
    const v = clasificarDuplicado(
      { nombre_fantasia: 'Lopez Ricardo', direccion: 'Calle Nueva 45', ...lejano },
      [{ id: '382', razon_social: 'López Ricardo', direccion: 'Otra 1', latitud: -26.8, longitud: -65.2 }],
    )
    expect(v.motivo).toBe('nombre_igual')
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
      { razon_social: 'Otro', direccion: 'Pje. Vera y Aragon 2551, Tucumán' },
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
    razon_social: 'PUENTE CRISTIAN',
    nombre_fantasia: 'CHICLANA 1895',
    direccion: 'Chiclana 1895, T4000 San Miguel de Tucumán, Tucumán, Argentina',
    latitud: -26.8355312,
    longitud: -65.2223494,
  }

  it('reasignar el preventista no cambia nada de lo que el criterio mira', () => {
    expect(cambiaIdentidadDuplicado(PUENTE_CRISTIAN, { ...PUENTE_CRISTIAN })).toBe(false)
  })

  it('un cambio cosmético de nombre o dirección tampoco', () => {
    expect(cambiaIdentidadDuplicado(PUENTE_CRISTIAN, {
      ...PUENTE_CRISTIAN,
      razon_social: '  puente   cristián  ',
      direccion: 'CHICLANA 1895, Tucumán',
    })).toBe(false)
  })

  it('`undefined` y `null` son lo mismo: un cliente sin coordenadas no "cambia"', () => {
    expect(cambiaIdentidadDuplicado(
      { razon_social: 'Kiosco', direccion: 'B° Esperanza', latitud: null, longitud: null },
      { razon_social: 'Kiosco', direccion: 'B° Esperanza' },
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

  // El criterio cruza los cuatro pares razón/fantasía, así que el veredicto sólo
  // depende de QUÉ nombres hay. Un cliente con la razón social vacía la recibe
  // de la fantasía al guardar (`razonSocial || nombreFantasia`): sin esto,
  // parecería cambiar de nombre en cada edición.
  it('los nombres son un conjunto: llenar una razón social vacía con la fantasía no cuenta', () => {
    const sinRazonSocial = { razon_social: null, nombre_fantasia: 'CHICLANA 1895', direccion: 'Chiclana 1895' }
    expect(cambiaIdentidadDuplicado(sinRazonSocial, {
      ...sinRazonSocial,
      razon_social: 'CHICLANA 1895',
    })).toBe(false)
  })

  it('intercambiar razón social y fantasía tampoco: el criterio las cruza', () => {
    expect(cambiaIdentidadDuplicado(PUENTE_CRISTIAN, {
      ...PUENTE_CRISTIAN,
      razon_social: PUENTE_CRISTIAN.nombre_fantasia,
      nombre_fantasia: PUENTE_CRISTIAN.razon_social,
    })).toBe(false)
  })

  it('cambiarle el nombre sí, en cualquiera de los dos campos', () => {
    expect(cambiaIdentidadDuplicado(PUENTE_CRISTIAN, {
      ...PUENTE_CRISTIAN,
      razon_social: 'PUENTE CRISTIAN HIJO',
    })).toBe(true)
    expect(cambiaIdentidadDuplicado(PUENTE_CRISTIAN, {
      ...PUENTE_CRISTIAN,
      nombre_fantasia: 'Kiosco Chiclana',
    })).toBe(true)
  })

  // Sin altura la dirección no entra al criterio, pero el nombre sí: el guard
  // tiene que seguir corriendo cuando cambia lo único que puede ver.
  it('con dirección sin altura, el nombre sigue mandando', () => {
    const base = { razon_social: 'Kiosco', nombre_fantasia: 'Kiosco', direccion: 'B° Esperanza' }
    expect(cambiaIdentidadDuplicado(base, { ...base, direccion: 'B° Sagrado Corazón' })).toBe(false)
    expect(cambiaIdentidadDuplicado(base, { ...base, razon_social: 'Kiosco Juan' })).toBe(true)
  })
})
