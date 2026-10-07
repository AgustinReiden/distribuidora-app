/**
 * Qué ve cada rol en la lista de Productos (WP-52, #776).
 *
 * `/productos` no tiene gate de rol: los cinco roles entran a la misma lista.
 * Este test monta el `ProductosContainer` REAL con la identidad de fixture de
 * cada rol (`authDataDeRol`, la misma que usa la galería) y la `VistaProductos`
 * REAL que el container carga, así que lo que fija es la cadena entera
 * rol → permiso → prop → DOM, no una prop puesta a mano. Sólo se mockean las
 * queries y mutaciones (datos), nunca la vista ni los permisos.
 *
 * jsdom no evalúa media queries: la tabla de escritorio (`hidden md:block`) y
 * las tarjetas del celular (`md:hidden`) están las dos en el DOM, y se miran
 * por separado. La tabla por su rol ARIA; cada tarjeta, subiendo desde su
 * `<h3>` hasta el contenedor más alto que no tiene otra tarjeta adentro.
 * Nunca por clase.
 *
 * Se escribió primero como caracterización contra HEAD, antes de la columna:
 * todos ven el precio y nadie ve costo ni margen. Con la columna (decisión del
 * dueño: sólo admin, `puedeVerCostoProducto`) lo único que cambió es el bloque
 * del admin, que pasó de "no ve costo" a ver la columna "Costo / margen" y la
 * línea de la tarjeta. Con #974 el dueño la amplió al encargado, que pasó al
 * mismo lado (sin Acciones). Los otros tres roles conservan las mismas
 * aserciones.
 *
 * "No está en el DOM" se mira dos veces y a propósito: por `columnheader` y por
 * el `textContent` de todo el body. `*ByRole` saltea lo oculto con `display:
 * none` o `hidden`; el `textContent` no, así que una columna escondida por CSS
 * en vez de no dibujada también falla.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { render, screen, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

// La cadena de imports pide supabaseUrl al cargarse y jsdom no la tiene.
vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn() },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(),
}));

/**
 * Tres productos con TODAS las columnas de costo cargadas y distintas entre
 * sí, para que un costo tomado de la columna equivocada se note. Ningún costo
 * coincide con ningún precio, así que buscar un monto no confunde una cosa con
 * la otra. Los nombres no dicen "costo" ni "margen" a propósito: el test busca
 * esas palabras en todo el DOM.
 */
const PRODUCTOS = vi.hoisted(() => [
  {
    // Cascada: costo_promedio (1000) gana. costo_real (1200) es reposición.
    // El margen va contra precio_sin_iva (1500), no contra el final (1815).
    id: '1', codigo: 'CAS-15', nombre: 'Gaseosa Cascada 1,5 L', precio: 1815, precio_sin_iva: 1500,
    stock: 300, stock_minimo: 20, categoria: 'Gaseosas',
    costo_promedio: 1000, costo_real: 1200, costo_sin_iva: 900,
    impuestos_internos: 8.6956, costo_con_iva: 1300,
  },
  {
    // Sin ningún término de la cascada. `costo_con_iva` está cargado pero NO
    // participa (es el costo financiero, IVA adentro): no puede aparecer.
    id: '2', codigo: 'PLA-1', nombre: 'Jugo Placer 1 L', precio: 800,
    stock: 50, stock_minimo: 10, categoria: 'Jugos',
    costo_promedio: null, costo_real: null, costo_sin_iva: null,
    impuestos_internos: null, costo_con_iva: 700,
  },
  {
    // Sin promedio: la cascada cae a costo_real (600), que supera al precio.
    id: '3', codigo: 'VIL-2', nombre: 'Agua Villa 2 L', precio: 610, precio_sin_iva: 500,
    stock: 80, stock_minimo: 10, categoria: 'Aguas',
    costo_promedio: null, costo_real: 600, costo_sin_iva: 520,
    impuestos_internos: 0, costo_con_iva: 605,
  },
]);

const mutacion = vi.hoisted(() => () => ({ mutateAsync: vi.fn(), mutate: vi.fn(), isPending: false }));

vi.mock('../../../hooks/queries', () => ({
  useProductosQuery: () => ({ data: PRODUCTOS, isLoading: false, isError: false, refetch: vi.fn() }),
  useCrearProductoMutation: mutacion,
  useActualizarProductoMutation: mutacion,
  useEliminarProductoMutation: mutacion,
  useRegistrarMermaMutation: mutacion,
  useProveedoresActivosQuery: () => ({ data: [] }),
  useClientesQuery: () => ({ data: [] }),
  useRegistrarCambioProductoMutation: mutacion,
  useCategoriasQuery: () => ({ data: [] }),
  useSubcategoriasQuery: () => ({ data: [] }),
  useAsegurarCatalogo: () => ({ asegurar: vi.fn(), creando: false }),
  useCrearGrupoPrecioMutation: mutacion,
  useGruposPrecioQuery: () => ({ data: [] }),
  usePromocionesListQuery: () => ({ data: [] }),
}));

vi.mock('../../../hooks/queries/useControlStockQuery', () => ({
  useAplicarControlStockMutation: mutacion,
}));

// Sólo cierra modales al cambiar de sucursal; necesita el SucursalProvider real.
vi.mock('../../../hooks/useResetOnSucursalChange', () => ({
  useResetOnSucursalChange: () => undefined,
}));

import ProductosContainer from '../../containers/ProductosContainer';
import VistaProductos from '../VistaProductos';
import { AuthDataProvider } from '../../../contexts/AuthDataContext';
import { NotificationProvider } from '../../../contexts/NotificationContext';
import { authDataDeRol, ROLES_GALERIA } from '../../../../dev/gallery/fixtures/auth';
import { formatPrecio } from '../../../utils/formatters';
import type { ProductoDB, RolUsuario } from '../../../types';

// Radix (menús del toolbar del admin) los pide al montar.
class ObservadorStub {
  observe(): void { /* no-op */ }
  unobserve(): void { /* no-op */ }
  disconnect(): void { /* no-op */ }
  takeRecords(): [] { return []; }
}
globalThis.ResizeObserver ??= ObservadorStub as unknown as typeof ResizeObserver;
globalThis.IntersectionObserver ??= ObservadorStub as unknown as typeof IntersectionObserver;

const [CASCADA, PLACER, VILLA] = PRODUCTOS;

/** Todo monto de costo de los fixtures, de cualquier columna. */
const MONTOS_DE_COSTO = [1000, 1200, 900, 1300, 700, 600, 520, 605];

/** `formatPrecio` separa el `$` con un espacio duro; el texto del DOM se compara normalizado. */
const plano = (s: string): string => s.replace(/\s+/g, ' ');
const precio = (n: number): string => plano(formatPrecio(n));

async function montar(rol: RolUsuario): Promise<HTMLElement> {
  render(
    <MemoryRouter>
      <NotificationProvider>
        <AuthDataProvider value={authDataDeRol(rol)}>
          <ProductosContainer />
        </AuthDataProvider>
      </NotificationProvider>
    </MemoryRouter>,
  );
  // La vista es lazy: la tabla aparece cuando el chunk resuelve.
  return screen.findByRole('table');
}

function encabezados(tabla: HTMLElement): string[] {
  return within(tabla).getAllByRole('columnheader').map(th => plano(th.textContent ?? '').trim());
}

function filaDe(tabla: HTMLElement, nombre: string): HTMLElement {
  const fila = within(tabla).getByText(nombre).closest('tr');
  expect(fila).not.toBeNull();
  return fila as HTMLElement;
}

/** La tarjeta del celular: sube desde su `<h3>` mientras no entre otra tarjeta. */
function tarjetaDe(nombre: string): HTMLElement {
  let el: HTMLElement = screen.getByRole('heading', { level: 3, name: nombre });
  while (el.parentElement && el.parentElement.querySelectorAll('h3').length === 1) {
    el = el.parentElement;
  }
  return el;
}

const textoDe = (el: HTMLElement): string => plano(el.textContent ?? '');

const ENCABEZADOS_BASE = ['Código', 'Producto', 'Categoría', 'Proveedor', 'Precio', 'Stock'];

/** Nada de costo ni de margen, por texto y por encabezado, en todo el DOM. */
function sinCostoNiMargen(tabla: HTMLElement): void {
  expect(within(tabla).queryByRole('columnheader', { name: /costo|margen/i })).not.toBeInTheDocument();
  const todo = textoDe(document.body);
  expect(todo).not.toMatch(/costo|margen/i);
  for (const monto of MONTOS_DE_COSTO) {
    expect(todo).not.toContain(precio(monto));
  }
  expect(todo).not.toMatch(/\d+\.\d%/);
}

/** El precio de cada producto, en su fila de la tabla y en su tarjeta. */
function veElPrecioEnLosDosLayouts(tabla: HTMLElement): void {
  for (const p of PRODUCTOS) {
    expect(textoDe(filaDe(tabla, p.nombre))).toContain(precio(p.precio));
    const tarjeta = textoDe(tarjetaDe(p.nombre));
    expect(tarjeta).toContain('Precio:');
    expect(tarjeta).toContain(precio(p.precio));
  }
}

describe('VistaProductos por rol', () => {
  // Admin y encargado ven el costo (puedeVerCostoProducto, #974): van aparte.
  describe.each(ROLES_GALERIA.filter(r => r !== 'admin' && r !== 'encargado'))('%s', (rol) => {
    it('ve las columnas de siempre, sin Acciones', async () => {
      const tabla = await montar(rol);
      expect(encabezados(tabla)).toEqual(ENCABEZADOS_BASE);
    });

    it('ve el precio de cada producto en la tabla y en la tarjeta', async () => {
      const tabla = await montar(rol);
      veElPrecioEnLosDosLayouts(tabla);
    });

    it('no tiene costo ni margen en el DOM, en ningún layout', async () => {
      const tabla = await montar(rol);
      sinCostoNiMargen(tabla);
    });
  });

  describe('admin', () => {
    it('ve las columnas de siempre, "Costo / margen" al lado del precio, y Acciones', async () => {
      const tabla = await montar('admin');
      expect(encabezados(tabla)).toEqual([
        'Código', 'Producto', 'Categoría', 'Proveedor', 'Precio', 'Costo / margen', 'Stock', 'Acciones',
      ]);
    });

    it('ve el precio de cada producto en la tabla y en la tarjeta', async () => {
      const tabla = await montar('admin');
      veElPrecioEnLosDosLayouts(tabla);
    });

    it('ve el costo de la cascada canónica (costo_promedio), no costo_real, y su margen', async () => {
      const tabla = await montar('admin');
      // costo_promedio 1000 gana a costo_real 1200, contra el precio sin IVA:
      // (1500 − 1000) / 1000 = 50,0 %. Con costo_real suelto serían $1.200 y
      // 25,0 %; contra el precio final (1815), 81,5 %.
      const fila = textoDe(filaDe(tabla, CASCADA.nombre));
      expect(fila).toContain(precio(1000));
      expect(fila).toContain('50.0%');
      expect(textoDe(tarjetaDe(CASCADA.nombre))).toContain(`Costo: ${precio(1000)} · Margen: 50.0%`);

      // Ningún otro término de costo del producto aparece en ningún layout.
      const todo = textoDe(document.body);
      for (const otro of [1200, 900, 1300]) expect(todo).not.toContain(precio(otro));
      expect(todo).not.toContain('25.0%');
      expect(todo).not.toContain('81.5%');

      // Un margen positivo no se marca como alerta.
      expect(within(filaDe(tabla, CASCADA.nombre)).queryByTitle('Precio por debajo del costo')).not.toBeInTheDocument();
    });

    it('un producto sin costo dice "sin costo": ni $0, ni costo_con_iva, ni margen', async () => {
      const tabla = await montar('admin');
      const fila = filaDe(tabla, PLACER.nombre);
      expect(textoDe(fila)).toContain('sin costo');
      expect(textoDe(fila)).not.toContain(precio(0));
      // costo_con_iva (700) no participa de la cascada.
      expect(textoDe(fila)).not.toContain(precio(700));
      expect(textoDe(fila)).not.toMatch(/%/);

      const tarjeta = textoDe(tarjetaDe(PLACER.nombre));
      expect(tarjeta).toContain('Costo: sin costo');
      expect(tarjeta).not.toContain(precio(0));
      expect(tarjeta).not.toContain(precio(700));
      expect(tarjeta).not.toMatch(/Margen|%/);
    });

    it('un precio por debajo del costo muestra el margen negativo, marcado como alerta', async () => {
      const tabla = await montar('admin');
      // Sin promedio la cascada cae a costo_real, contra el precio sin IVA:
      // (500 − 600) / 600 = −16,7 %.
      const fila = filaDe(tabla, VILLA.nombre);
      expect(textoDe(fila)).toContain(precio(600));
      expect(within(fila).getByTitle('Precio por debajo del costo')).toHaveTextContent('-16.7%');

      const tarjeta = tarjetaDe(VILLA.nombre);
      expect(textoDe(tarjeta)).toContain(`Costo: ${precio(600)} · Margen: -16.7%`);
      expect(within(tarjeta).getByTitle('Precio por debajo del costo')).toHaveTextContent('-16.7%');
    });
  });

  // #974: el dueño amplió el costo al encargado. Ve la columna y la línea de la
  // tarjeta igual que el admin, pero no Acciones (editar sigue siendo de admin).
  describe('encargado', () => {
    it('ve las columnas de siempre y "Costo / margen" al lado del precio, sin Acciones', async () => {
      const tabla = await montar('encargado');
      expect(encabezados(tabla)).toEqual([
        'Código', 'Producto', 'Categoría', 'Proveedor', 'Precio', 'Costo / margen', 'Stock',
      ]);
    });

    it('ve el precio de cada producto en la tabla y en la tarjeta', async () => {
      const tabla = await montar('encargado');
      veElPrecioEnLosDosLayouts(tabla);
    });

    it('ve el costo de la cascada canónica y su margen, en la tabla y en la tarjeta', async () => {
      const tabla = await montar('encargado');
      const fila = textoDe(filaDe(tabla, CASCADA.nombre));
      expect(fila).toContain(precio(1000));
      expect(fila).toContain('50.0%');
      expect(textoDe(tarjetaDe(CASCADA.nombre))).toContain(`Costo: ${precio(1000)} · Margen: 50.0%`);
    });
  });

  // La vista no decide por su cuenta quién ve el costo: sólo obedece la prop que
  // le pasa el container. Un `isAdmin` adentro de la vista rompe esto.
  it('la vista sin `puedeVerCosto` no dibuja costo ni margen aunque sea admin', () => {
    render(
      <MemoryRouter>
        <VistaProductos
          productos={PRODUCTOS as ProductoDB[]}
          productosStockBajo={[]}
          loading={false}
          isAdmin
          puedeControlarStock
          onNuevoProducto={vi.fn()}
          onEditarProducto={vi.fn()}
          onEliminarProducto={vi.fn()}
        />
      </MemoryRouter>,
    );
    const tabla = screen.getByRole('table');
    expect(encabezados(tabla)).toEqual([...ENCABEZADOS_BASE, 'Acciones']);
    sinCostoNiMargen(tabla);
  });

  it('las tres tarjetas y las tres filas son de los fixtures (control del recorte)', async () => {
    const tabla = await montar('preventista');
    expect(within(tabla).getAllByRole('row')).toHaveLength(1 + PRODUCTOS.length);
    for (const p of [CASCADA, PLACER, VILLA]) {
      const tarjeta = tarjetaDe(p.nombre);
      expect(within(tarjeta).getAllByRole('heading', { level: 3 })).toHaveLength(1);
      expect(textoDe(tarjeta)).toContain(`#${p.codigo}`);
    }
  });
});
