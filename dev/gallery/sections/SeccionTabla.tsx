/**
 * Table (WP-50, #774): el primitivo `src/components/ui/Table.tsx` con compras de
 * fixture, que es la tabla más repetida del back-office.
 *
 * Tres marcos:
 *  1. La tabla de todos los días: columnas de texto, un par de números, un badge
 *     de estado y un pie con el total en pesos.
 *  2. La tabla ancha: 11 columnas en un contenedor angosto. Scrollea ADENTRO de
 *     su región, y la región toma foco con Tab (anillo de foco global), así que
 *     se puede recorrer con el teclado. Para verlo hace falta que el contenedor
 *     sea más angosto que la tabla: acá lo fuerza `max-w-3xl`.
 *  3. Adentro de una `Card`, con `marco={false}`: la tabla no dibuja su propio
 *     borde porque ya vive en otra superficie.
 *
 * Nada de esto migra una tabla real: son los componentes de `src/` con datos de
 * fixture, igual que en el resto de la galería.
 */
import { Badge } from '../../../src/components/ui/Badge'
import Card from '../../../src/components/ui/Card'
import {
  Table,
  TableBody,
  TableCaption,
  TableCell,
  TableFooter,
  TableHead,
  TableHeader,
  TableRow,
} from '../../../src/components/ui/Table'
import { ETIQUETA_ESTADO_COMPRA, toneDeEstadoCompra } from '../../../src/lib/estadoTones'
import { formatPrecio } from '../../../src/utils/formatters'
import { COMPRAS_FIXTURE, sumarCompras, type CompraFixture } from '../fixtures/tabla'
import { Marco, Seccion } from '../ui/Marco'

const fecha = (d: Date): string => d.toLocaleDateString('es-AR')

/** Una compra cancelada no suma: su importe queda a la vista pero apagado y tachado. */
const IMPORTE_CANCELADO = 'text-gray-500 dark:text-gray-400 line-through'

function EstadoBadge({ compra }: { compra: CompraFixture }) {
  return (
    <Badge tone={toneDeEstadoCompra(compra.estado)}>{ETIQUETA_ESTADO_COMPRA[compra.estado]}</Badge>
  )
}

function Comprobante({ compra }: { compra: CompraFixture }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <Badge mono tone={compra.tipoFactura === 'FC' ? 'brand' : 'neutral'}>
        {compra.tipoFactura}
      </Badge>
      <span className="font-mono text-gray-600 dark:text-gray-400">{compra.numeroFactura}</span>
    </span>
  )
}

function TablaCompras() {
  return (
    <Table>
      <TableCaption srOnly>Compras de los últimos 15 días</TableCaption>
      <TableHeader>
        <TableRow>
          <TableHead>Fecha</TableHead>
          <TableHead>Proveedor</TableHead>
          <TableHead>Comprobante</TableHead>
          <TableHead numerico>Ítems</TableHead>
          <TableHead className="text-center">Estado</TableHead>
          <TableHead numerico>Total</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {COMPRAS_FIXTURE.map((c) => (
          <TableRow key={c.id}>
            <TableCell className="whitespace-nowrap">{fecha(c.fecha)}</TableCell>
            <TableCell className="font-medium">{c.proveedor}</TableCell>
            <TableCell>
              <Comprobante compra={c} />
            </TableCell>
            <TableCell numerico>{c.items}</TableCell>
            <TableCell className="text-center">
              <EstadoBadge compra={c} />
            </TableCell>
            <TableCell numerico className={c.estado === 'cancelada' ? IMPORTE_CANCELADO : undefined}>
              {formatPrecio(c.total)}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
      <TableFooter>
        <TableRow>
          <TableCell colSpan={5}>Total del período (sin canceladas)</TableCell>
          <TableCell numerico>{formatPrecio(sumarCompras(COMPRAS_FIXTURE, 'total'))}</TableCell>
        </TableRow>
      </TableFooter>
    </Table>
  )
}

function TablaAncha() {
  return (
    <Table
      etiqueta="Detalle de compras con impuestos, desplazable horizontalmente"
      contenedorClassName="max-w-3xl"
      className="min-w-[72rem]"
    >
      <TableCaption srOnly>Detalle de compras con impuestos</TableCaption>
      <TableHeader>
        <TableRow>
          <TableHead>Fecha</TableHead>
          <TableHead>Proveedor</TableHead>
          <TableHead>Comprobante</TableHead>
          <TableHead numerico>Ítems</TableHead>
          <TableHead numerico>Unidades</TableHead>
          <TableHead numerico>Subtotal</TableHead>
          <TableHead numerico>IVA 21 %</TableHead>
          <TableHead numerico>Imp. internos</TableHead>
          <TableHead numerico>Percepciones</TableHead>
          <TableHead numerico>Total</TableHead>
          <TableHead className="text-center">Estado</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {COMPRAS_FIXTURE.map((c) => (
          <TableRow key={c.id}>
            <TableCell className="whitespace-nowrap">{fecha(c.fecha)}</TableCell>
            <TableCell className="font-medium whitespace-nowrap">{c.proveedor}</TableCell>
            <TableCell className="whitespace-nowrap">
              <Comprobante compra={c} />
            </TableCell>
            <TableCell numerico>{c.items}</TableCell>
            <TableCell numerico>{c.unidades}</TableCell>
            <TableCell numerico>{formatPrecio(c.subtotal)}</TableCell>
            <TableCell numerico>{c.iva > 0 ? formatPrecio(c.iva) : '—'}</TableCell>
            <TableCell numerico>
              {c.impuestosInternos > 0 ? formatPrecio(c.impuestosInternos) : '—'}
            </TableCell>
            <TableCell numerico>
              {c.percepciones > 0 ? formatPrecio(c.percepciones) : '—'}
            </TableCell>
            <TableCell numerico className={c.estado === 'cancelada' ? IMPORTE_CANCELADO : undefined}>
              {formatPrecio(c.total)}
            </TableCell>
            <TableCell className="text-center">
              <EstadoBadge compra={c} />
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
      <TableFooter>
        <TableRow>
          <TableCell colSpan={3}>Total del período (sin canceladas)</TableCell>
          <TableCell numerico>{sumarCompras(COMPRAS_FIXTURE, 'items')}</TableCell>
          <TableCell numerico>{sumarCompras(COMPRAS_FIXTURE, 'unidades')}</TableCell>
          <TableCell numerico>{formatPrecio(sumarCompras(COMPRAS_FIXTURE, 'subtotal'))}</TableCell>
          <TableCell numerico>{formatPrecio(sumarCompras(COMPRAS_FIXTURE, 'iva'))}</TableCell>
          <TableCell numerico>
            {formatPrecio(sumarCompras(COMPRAS_FIXTURE, 'impuestosInternos'))}
          </TableCell>
          <TableCell numerico>{formatPrecio(sumarCompras(COMPRAS_FIXTURE, 'percepciones'))}</TableCell>
          <TableCell numerico>{formatPrecio(sumarCompras(COMPRAS_FIXTURE, 'total'))}</TableCell>
          <TableCell />
        </TableRow>
      </TableFooter>
    </Table>
  )
}

function TablaEnCard() {
  return (
    <Card padding="none" className="overflow-hidden">
      <h4 className="px-4 pt-4 pb-3 text-base font-semibold text-gray-900 dark:text-white">
        Últimas compras
      </h4>
      <Table marco={false} className="border-t border-gray-200 dark:border-gray-700">
        <TableCaption srOnly>Últimas tres compras</TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead>Fecha</TableHead>
            <TableHead>Proveedor</TableHead>
            <TableHead numerico>Total</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {COMPRAS_FIXTURE.slice(0, 3).map((c) => (
            <TableRow key={c.id}>
              <TableCell className="whitespace-nowrap">{fecha(c.fecha)}</TableCell>
              <TableCell className="font-medium">{c.proveedor}</TableCell>
              <TableCell numerico>{formatPrecio(c.total)}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </Card>
  )
}

export default function SeccionTabla() {
  return (
    <Seccion
      id="tabla"
      titulo="Tabla"
      descripcion={
        <>
          <code>Table</code> y sus piezas (<code>TableHeader</code>, <code>TableBody</code>,{' '}
          <code>TableFooter</code>, <code>TableRow</code>, <code>TableHead</code>,{' '}
          <code>TableCell</code>, <code>TableCaption</code>) con compras de fixture. Renderizan los
          elementos HTML reales —<code>table</code>, <code>tr</code>, <code>th</code>,{' '}
          <code>td</code>—, así que <code>.closest('tr')</code> y <code>getAllByRole('row')</code>{' '}
          siguen andando. <code>numerico</code> alinea los montos a la derecha con cifras de ancho
          fijo. En alto contraste los <code>th</code> y <code>td</code> toman el borde de{' '}
          <code>high-contrast.css</code>.
        </>
      }
    >
      <Marco etiqueta="Table · caption sr-only · numerico · estado en Badge · pie con total" compacto>
        <TablaCompras />
      </Marco>

      <Marco
        etiqueta="Table etiqueta=… · 11 columnas en un contenedor angosto: scrollea adentro de su región (Tab la enfoca)"
        compacto
      >
        <TablaAncha />
      </Marco>

      <Marco etiqueta="Table marco={false} · adentro de una Card, que ya trae la superficie" compacto>
        <TablaEnCard />
      </Marco>
    </Seccion>
  )
}
