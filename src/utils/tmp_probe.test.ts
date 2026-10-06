import { it } from 'vitest'
import { matchEscaneo } from './matchEscaneo'
const CATALOGO = [
  { id: 'p1', nombre: 'Manaos Cola 3L', codigo: 'MC3000' },
  { id: 'p2', nombre: 'Agua Villamanaos Sin Gas 600 cc x 12', codigo: 'AV600' },
  { id: 'p3', nombre: 'Manaos Naranja 3L', codigo: 'MN3000' },
  { id: 'p4', nombre: 'Yerba Verdeflor Hierbas 500 g', codigo: 'Y500' },
]
it('probe', () => {
  const rs = matchEscaneo({
    lineas: ['Manaos Cola 3L', 'AGUA VILLAMANAOS SIN GAS 600CC X12', 'PRODUCTO DESCONOCIDO', 'NARANJA MANAOS 3 LITROS', 'YERBA VERDEF. HIERBAS'].map((d, i) => ({ codigo: i === 0 ? 'MC3000' : null, descripcion: d })),
    proveedorId: null, catalogo: CATALOGO,
  })
  for (const r of rs) console.log('PROBE', r.estado, r.productoId, r.confianza, r.alternativas)
})
