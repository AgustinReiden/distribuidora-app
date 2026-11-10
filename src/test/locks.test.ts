import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { aplanar, consultaDelLock, hallazgosLocks, tomaVariasFilasSinOrden } from '../../scripts/lib/locks.mjs'

/**
 * El criterio del gate `scripts/check-locks.mjs` (#1520, gate 4). La base devuelve las sentencias con un lock de
 * fila (`auditoria_locks()`, ensayada en scripts/test-restos-nucleo-1520.sql); acá se fija cuál cuenta como
 * "varias filas sin ORDER BY", y la forma de la lista permitida. Las sentencias son como las devuelve el RPC: sin
 * comentarios, con los literales vacíos y el espacio colapsado.
 */

const marca = (s: string): boolean => tomaVariasFilasSinOrden(s)

describe('aplanar y consultaDelLock', () => {
  it('aplanar vacía los paréntesis de adentro hacia afuera', () => {
    expect(aplanar('f(a, (b)) AND g(c)')).toBe('f() AND g()')
  })

  it('el lock de una subconsulta se mira en su paréntesis', () => {
    const s = 'WITH l AS (SELECT id FROM t WHERE x = 1 FOR UPDATE) SELECT 1 FROM l ORDER BY id'
    expect(consultaDelLock(s, s.indexOf('FOR UPDATE'))).toBe('SELECT id FROM t WHERE x = 1 FOR UPDATE')
  })

  it('un FOR … IN … LOOP se corta en el LOOP', () => {
    const s = 'FOR r IN SELECT id FROM t WHERE x = 1 FOR UPDATE LOOP PERFORM 1 FROM u ORDER BY id'
    expect(consultaDelLock(s, s.indexOf('FOR UPDATE'))).toBe('FOR r IN SELECT id FROM t WHERE x = 1 FOR UPDATE ')
  })
})

describe('tomaVariasFilasSinOrden', () => {
  it('marca un lock de varias filas sin ORDER BY (el de sincronizar_lotes_compra)', () => {
    expect(marca('PERFORM 1 FROM public.producto_lotes WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal FOR UPDATE')).toBe(true)
  })

  it('no marca el mismo lock con ORDER BY', () => {
    expect(marca('PERFORM 1 FROM public.producto_lotes WHERE compra_id = p_compra_id ORDER BY id FOR UPDATE')).toBe(false)
  })

  it('marca id = ANY(…) sin orden, y no lo marca con orden', () => {
    expect(marca('PERFORM 1 FROM productos WHERE id = ANY (v_ids) AND sucursal_id = v_suc FOR UPDATE')).toBe(true)
    expect(marca('PERFORM 1 FROM productos WHERE id = ANY (v_ids) ORDER BY id FOR NO KEY UPDATE')).toBe(false)
  })

  it('no marca una fila por id, ni con alias', () => {
    expect(marca('PERFORM 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_suc FOR UPDATE')).toBe(false)
    expect(marca('PERFORM 1 FROM pedidos p WHERE p.id = p_pedido_id FOR UPDATE OF p')).toBe(false)
    expect(marca('PERFORM 1 FROM promociones WHERE id = (SELECT promocion_id FROM x WHERE y = 1) FOR UPDATE')).toBe(false)
  })

  it('un pedido_id = … no es un id', () => {
    expect(marca('PERFORM 1 FROM pedido_items WHERE pedido_id = p_pedido_id FOR UPDATE')).toBe(true)
  })

  it('el id del ON de un join no hace de una fila', () => {
    expect(marca('PERFORM 1 FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id WHERE pi.pedido_id = v FOR UPDATE OF pi')).toBe(true)
  })

  it('el id de una subconsulta del WHERE no hace de una fila (el de las salvedades de sincronizar_lotes_compra)', () => {
    expect(
      marca(
        "PERFORM 1 FROM public.salvedades_items s WHERE s.sucursal_id = v_sucursal AND s.estado_resolucion <> '' AND EXISTS ( SELECT 1 FROM jsonb_array_elements(s.lotes_devueltos) e JOIN public.producto_lotes l ON l.id = (e->>'')::bigint WHERE l.compra_id = p_compra_id) FOR UPDATE OF s",
      ),
    ).toBe(true)
  })

  it('el ORDER BY de una subconsulta no ordena el lock de afuera', () => {
    expect(marca('PERFORM 1 FROM t WHERE x IN (SELECT y FROM z ORDER BY y) FOR UPDATE')).toBe(true)
  })

  it('no marca un SELECT INTO: trae una fila', () => {
    expect(marca('SELECT id INTO v_id FROM ii_alicuotas WHERE encuadre_id = p AND vigente_desde = d FOR UPDATE')).toBe(false)
    expect(marca('IF v_cod IS NOT NULL THEN SELECT id INTO STRICT v_x FROM t WHERE codigo = v_cod FOR UPDATE')).toBe(false)
  })

  it('un INSERT INTO … SELECT … FOR UPDATE no es un SELECT INTO', () => {
    expect(marca('INSERT INTO log SELECT * FROM t WHERE x = p FOR UPDATE')).toBe(true)
  })

  it('no marca NOWAIT, SKIP LOCKED ni LIMIT 1', () => {
    expect(marca('PERFORM 1 FROM cola WHERE estado = p FOR UPDATE SKIP LOCKED')).toBe(false)
    expect(marca('PERFORM 1 FROM cola WHERE estado = p FOR UPDATE NOWAIT')).toBe(false)
    expect(marca('PERFORM 1 FROM cola WHERE estado = p LIMIT 1 FOR UPDATE')).toBe(false)
  })

  it('un FOR … IN sin orden se marca aunque el cuerpo tenga ORDER BY', () => {
    expect(marca('FOR r IN SELECT id FROM t WHERE x = 1 FOR UPDATE LOOP PERFORM 1 FROM u ORDER BY id')).toBe(true)
    expect(marca('FOR r IN SELECT id FROM t WHERE x = 1 ORDER BY id FOR UPDATE LOOP PERFORM 1')).toBe(false)
  })

  it('una CTE con lock sin orden se marca aunque la consulta de afuera ordene', () => {
    expect(marca('WITH l AS (SELECT id FROM t WHERE x = 1 FOR UPDATE) SELECT 1 FROM l ORDER BY id')).toBe(true)
  })

  it('mira las cuatro fuerzas de lock', () => {
    for (const fuerza of ['FOR UPDATE', 'FOR NO KEY UPDATE', 'FOR SHARE', 'FOR KEY SHARE']) {
      expect(marca(`PERFORM 1 FROM t WHERE x = 1 ${fuerza}`)).toBe(true)
    }
  })

  it('una sentencia sin lock no se marca', () => {
    expect(marca('UPDATE t SET x = 1 WHERE y = 2')).toBe(false)
  })
})

describe('hallazgosLocks', () => {
  const lotes = { firma: 'sincronizar_lotes_compra(bigint,jsonb)', sentencia: 'PERFORM 1 FROM producto_lotes WHERE compra_id = p FOR UPDATE' }
  const ordenada = { firma: 'aplicar_control_stock(bigint)', sentencia: 'PERFORM 1 FROM productos WHERE id = ANY (v) ORDER BY id FOR UPDATE' }
  const otra = { firma: 'x(bigint)', sentencia: 'PERFORM 1 FROM pedido_items WHERE pedido_id = p FOR SHARE' }

  it('una función con un lock de varias filas sin orden que no está permitida es rojo, con sus sentencias', () => {
    expect(hallazgosLocks({ sentencias: [lotes, ordenada, otra] }, { [lotes.firma]: 'm' })).toEqual({
      marcadas: [{ firma: otra.firma, sentencias: [otra.sentencia] }],
      sobrantes: [],
    })
  })

  it('agrupa las sentencias de la misma función', () => {
    const segunda = { ...lotes, sentencia: 'PERFORM 1 FROM salvedades_items WHERE x = 1 FOR UPDATE' }
    expect(hallazgosLocks({ sentencias: [lotes, segunda] }).marcadas).toEqual([
      { firma: lotes.firma, sentencias: [lotes.sentencia, segunda.sentencia] },
    ])
  })

  it('la permitida que ya ordena sobra, y no es rojo', () => {
    expect(hallazgosLocks({ sentencias: [ordenada] }, { [lotes.firma]: 'm' })).toEqual({
      marcadas: [],
      sobrantes: [lotes.firma],
    })
  })

  it('va por firma: una sobrecarga nueva no hereda la excepción', () => {
    const sobrecarga = { ...lotes, firma: 'sincronizar_lotes_compra(bigint,jsonb,boolean)' }
    expect(hallazgosLocks({ sentencias: [sobrecarga] }, { [lotes.firma]: 'm' }).marcadas).toHaveLength(1)
  })
})

describe('scripts/locks-permitidas.json', () => {
  const ruta = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../scripts/locks-permitidas.json')
  const lista = JSON.parse(fs.readFileSync(ruta, 'utf8')) as { funciones: Record<string, string> }

  // Las que marcaba el gate al nacer (#1520, 10/11). La lista sólo se achica: una función nueva ordena sus locks.
  const alNacer = ['_combo_rehacer(bigint,bigint,bigint,bigint)', 'sincronizar_lotes_compra(bigint,jsonb)']

  it('sólo se achica: ninguna permitida es nueva', () => {
    for (const firma of Object.keys(lista.funciones)) expect(alNacer).toContain(firma)
  })

  it('cada permitida dice por qué', () => {
    for (const motivo of Object.values(lista.funciones)) expect(motivo.trim().length).toBeGreaterThan(10)
  })
})
