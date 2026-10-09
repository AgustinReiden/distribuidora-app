/* eslint-disable no-undef */
/**
 * PWA Assets Generator
 *
 * Genera los íconos de la PWA, el favicon y los logos que usa la app a partir
 * del logo de Crecer Distribuciones (`scripts/marca/crecer-original.webp`).
 * Ejecutar con: node scripts/generate-pwa-assets.js
 *
 * El original viene sobre fondo blanco y en un solo bloque: flecha arriba,
 * «CRECER» al medio y «DISTRIBUCIONES» abajo. De ahí salen tres recortes:
 *  - completo (las tres franjas): el login;
 *  - compacto (flecha + CRECER): la barra de arriba y los íconos de la app.
 *    «DISTRIBUCIONES» en un ícono de 48 px es una raya: se lee en el login, no
 *    en la pantalla de inicio del celular;
 *  - isotipo (sólo la flecha): el favicon y la barra de arriba en el celular.
 *    A 16 px no entra ninguna letra.
 *
 * Los logos de la app van a `src/assets/marca/` (se importan y Vite les pone
 * hash, así un cambio de logo nunca queda pegado en la caché). Los íconos van a
 * `public/` con nombre fijo, porque los nombran el manifest e index.html.
 */

import sharp from 'sharp';
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const publicDir = join(__dirname, '..', 'public');
const marcaDir = join(__dirname, '..', 'src', 'assets', 'marca');
const ORIGINAL = join(__dirname, 'marca', 'crecer-original.webp');

// Los cuatro colores lisos del logo, medidos sobre el original (mediana de los
// píxeles que no tocan el blanco). Sirven para sacar el fondo: un píxel de
// borde es una mezcla de uno de estos con blanco.
const PALETA = [
  [254, 108, 6], // naranja (C, R)
  [254, 198, 2], // amarillo (CER, cola de la flecha)
  [51, 147, 35], // verde (flecha, E)
  [26, 127, 52], // verde oscuro (DISTRIBUCIONES)
];

// «DISTRIBUCIONES» en verde oscuro sobre la tarjeta oscura del login
// (stone-800, #292524) da 2,7:1. En la variante oscura va en este verde, el
// mismo tono más claro: 5,9:1. El resto del logo se lee bien sobre oscuro tal
// cual (naranja 5,0, amarillo 9,4, verde 3,7 en letras de 60 px).
const VERDE_OSCURO_SOBRE_NEGRO = [61, 184, 92]; // #3DB85C

const BLANCO_TILE = '#ffffff';

/**
 * Saca el fondo blanco sin comerse los colores.
 *
 * No es un "color a alfa" genérico: ése vuelve semitransparente todo color que
 * no tenga un canal en 0, y la flecha verde quedaría al 83 % (más oscura sobre
 * un fondo oscuro). Acá cada píxel se proyecta sobre la recta blanco -> color
 * liso más cercano. Si cae sobre la recta (residuo chico) es borde
 * antialiaseado: queda el color liso con ese alfa. Si no cae (residuo grande)
 * es la juntura entre dos colores, como el amarillo y el verde de la flecha:
 * queda opaco, tal cual.
 */
function sacarFondo(data) {
  for (let i = 0; i < data.length; i += 4) {
    const q = [255 - data[i], 255 - data[i + 1], 255 - data[i + 2]];
    if (q[0] + q[1] + q[2] <= 12) {
      // El blanco del original es 253-254 (compresión), no 255.
      data[i + 3] = 0;
      continue;
    }
    let mejor = null;
    for (const color of PALETA) {
      const v = [255 - color[0], 255 - color[1], 255 - color[2]];
      const vv = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
      const alfa = Math.min(1, Math.max(0, (q[0] * v[0] + q[1] * v[1] + q[2] * v[2]) / vv));
      const residuo = Math.hypot(q[0] - alfa * v[0], q[1] - alfa * v[1], q[2] - alfa * v[2]);
      if (!mejor || residuo < mejor.residuo) mejor = { color, alfa, residuo };
    }
    if (mejor.residuo > 40 || mejor.alfa >= 0.97) {
      data[i + 3] = 255;
    } else {
      data[i] = mejor.color[0];
      data[i + 1] = mejor.color[1];
      data[i + 2] = mejor.color[2];
      data[i + 3] = Math.round(mejor.alfa * 255);
    }
  }
}

/**
 * Las franjas horizontales del logo (filas con algo opaco). Las de menos de
 * 6 px son motas de la compresión y se descartan. El logo tiene tres; si el
 * original cambia de forma, mejor cortar acá que generar íconos mal recortados.
 */
function franjas(data, ancho, alto) {
  const resultado = [];
  let desde = null;
  for (let y = 0; y <= alto; y++) {
    let ocupada = false;
    if (y < alto) {
      for (let x = 0; x < ancho; x++) {
        if (data[(y * ancho + x) * 4 + 3] > 64) { ocupada = true; break; }
      }
    }
    if (ocupada && desde === null) desde = y;
    if (!ocupada && desde !== null) {
      if (y - desde >= 6) resultado.push({ top: desde, bottom: y - 1 });
      desde = null;
    }
  }
  if (resultado.length !== 3) {
    throw new Error(`Esperaba 3 franjas en el logo (flecha, CRECER, DISTRIBUCIONES) y hay ${resultado.length}`);
  }
  return resultado;
}

/** Caja que encierra lo opaco entre dos filas, lista para `extract`. */
function caja(data, ancho, top, bottom) {
  let left = ancho;
  let right = -1;
  for (let y = top; y <= bottom; y++) {
    for (let x = 0; x < ancho; x++) {
      if (data[(y * ancho + x) * 4 + 3] > 64) {
        if (x < left) left = x;
        if (x > right) right = x;
      }
    }
  }
  return { left, top, width: right - left + 1, height: bottom - top + 1 };
}

/** Borra todo lo que quede fuera de las franjas: motas sueltas de la compresión. */
function limpiarFueraDeFranjas(data, ancho, alto, bandas) {
  for (let y = 0; y < alto; y++) {
    if (bandas.some(b => y >= b.top && y <= b.bottom)) continue;
    for (let x = 0; x < ancho; x++) data[(y * ancho + x) * 4 + 3] = 0;
  }
}

function recolorear(data, ancho, { top, bottom }, rgb) {
  for (let y = top; y <= bottom; y++) {
    for (let x = 0; x < ancho; x++) {
      const i = (y * ancho + x) * 4;
      if (data[i + 3] === 0) continue;
      data[i] = rgb[0];
      data[i + 1] = rgb[1];
      data[i + 2] = rgb[2];
    }
  }
}

function recorte(data, ancho, alto, area) {
  return sharp(data, { raw: { width: ancho, height: alto, channels: 4 } }).extract(area);
}

const PNG_LOGO = { palette: true, quality: 95, effort: 10, compressionLevel: 9 };

async function guardar(imagen, ruta, opcionesPng = PNG_LOGO) {
  await imagen.png(opcionesPng).toFile(ruta);
  console.log(`Generated: ${ruta}`);
}

/**
 * Ícono de la app: el logo compacto centrado sobre un cuadrado blanco, opaco y
 * sin esquinas redondeadas. Cada sistema le pone su forma (iOS, Android, macOS),
 * y lo transparente iOS lo pinta de negro: el iOS reciente arma el ícono de inicio
 * también con los del manifest, no sólo con el apple-touch-icon.
 * `escala` es qué fracción del ancho ocupa el logo. Los maskable y los atajos van
 * más chicos porque el lanzador los recorta en círculo: el logo tiene que entrar
 * en la zona segura (el 80 % central).
 */
async function icono(compacto, tamano, { escala }) {
  const anchoLogo = Math.round(tamano * escala);
  const logo = await compacto.clone().resize({ width: anchoLogo }).png().toBuffer();
  const { height: altoLogo } = await sharp(logo).metadata();
  const compuesto = await sharp({
    create: { width: tamano, height: tamano, channels: 3, background: BLANCO_TILE },
  }).composite([{
    input: logo,
    left: Math.round((tamano - anchoLogo) / 2),
    top: Math.round((tamano - altoLogo) / 2),
  }]).png().toBuffer();
  // Sin canal alfa en el archivo: si no, el PNG sale con transparencia declarada
  // aunque ningún píxel la use.
  return sharp(compuesto).removeAlpha();
}

/** Favicon: la flecha sola, centrada en un cuadrado transparente. */
function favicon(isotipo, tamano) {
  return isotipo.clone().resize(tamano, tamano, {
    fit: 'contain',
    background: { r: 0, g: 0, b: 0, alpha: 0 },
  });
}

/**
 * Un .ico de verdad, con varios tamaños adentro (cada uno como PNG, que todo
 * navegador actual entiende). El de antes era un PNG renombrado.
 */
function ico(pngs) {
  const cabecera = Buffer.alloc(6);
  cabecera.writeUInt16LE(0, 0);
  cabecera.writeUInt16LE(1, 2);
  cabecera.writeUInt16LE(pngs.length, 4);
  let offset = 6 + 16 * pngs.length;
  const entradas = pngs.map(({ tamano, buffer }) => {
    const entrada = Buffer.alloc(16);
    entrada.writeUInt8(tamano, 0);
    entrada.writeUInt8(tamano, 1);
    entrada.writeUInt16LE(1, 4);
    entrada.writeUInt16LE(32, 6);
    entrada.writeUInt32LE(buffer.length, 8);
    entrada.writeUInt32LE(offset, 12);
    offset += buffer.length;
    return entrada;
  });
  return Buffer.concat([cabecera, ...entradas, ...pngs.map(p => p.buffer)]);
}

async function generateScreenshot(outputPath, width, height, isWide) {
  // Crear un screenshot placeholder con el tema de la app
  const svg = `
    <svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" style="stop-color:#f3f4f6"/>
          <stop offset="100%" style="stop-color:#e5e7eb"/>
        </linearGradient>
      </defs>
      <rect width="100%" height="100%" fill="url(#bg)"/>

      <!-- Header -->
      <rect x="0" y="0" width="${width}" height="${isWide ? 64 : 56}" fill="#2563eb"/>
      <text x="${isWide ? 24 : 16}" y="${isWide ? 40 : 36}"
            font-family="Arial, sans-serif"
            font-size="${isWide ? 24 : 20}"
            font-weight="bold"
            fill="white">
        Distribuidora App
      </text>

      <!-- Content cards -->
      ${isWide ? `
        <rect x="24" y="88" width="380" height="200" rx="8" fill="white" filter="url(#shadow)"/>
        <rect x="24" y="96" width="380" height="40" fill="#2563eb" opacity="0.1"/>
        <text x="40" y="124" font-family="Arial" font-size="16" fill="#1e40af">Dashboard</text>

        <rect x="428" y="88" width="380" height="200" rx="8" fill="white"/>
        <rect x="428" y="96" width="380" height="40" fill="#10b981" opacity="0.1"/>
        <text x="444" y="124" font-family="Arial" font-size="16" fill="#065f46">Pedidos Recientes</text>

        <rect x="832" y="88" width="380" height="200" rx="8" fill="white"/>
        <rect x="832" y="96" width="380" height="40" fill="#f59e0b" opacity="0.1"/>
        <text x="848" y="124" font-family="Arial" font-size="16" fill="#92400e">Stock</text>
      ` : `
        <rect x="16" y="72" width="${width - 32}" height="120" rx="8" fill="white"/>
        <text x="32" y="108" font-family="Arial" font-size="18" font-weight="bold" fill="#1f2937">Bienvenido</text>
        <text x="32" y="132" font-family="Arial" font-size="14" fill="#6b7280">3 pedidos pendientes</text>
        <text x="32" y="156" font-family="Arial" font-size="14" fill="#6b7280">$125,430 ventas del dia</text>

        <rect x="16" y="208" width="${width - 32}" height="80" rx="8" fill="white"/>
        <text x="32" y="244" font-family="Arial" font-size="16" font-weight="bold" fill="#1f2937">Acciones rapidas</text>

        <rect x="16" y="304" width="${width - 32}" height="200" rx="8" fill="white"/>
        <text x="32" y="340" font-family="Arial" font-size="16" font-weight="bold" fill="#1f2937">Pedidos recientes</text>
      `}

      <!-- Bottom nav (mobile only) -->
      ${!isWide ? `
        <rect x="0" y="${height - 64}" width="${width}" height="64" fill="white"/>
        <line x1="0" y1="${height - 64}" x2="${width}" y2="${height - 64}" stroke="#e5e7eb" stroke-width="1"/>
      ` : ''}
    </svg>
  `;

  await sharp(Buffer.from(svg))
    .png()
    .toFile(outputPath);

  console.log(`Generated: ${outputPath}`);
}

async function main() {
  if (!existsSync(ORIGINAL)) {
    console.error(`Error: no está el logo original en ${ORIGINAL}`);
    process.exit(1);
  }

  console.log('Generating PWA assets...\n');

  const { data, info } = await sharp(readFileSync(ORIGINAL))
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const { width: ancho, height: alto } = info;

  sacarFondo(data);
  const [flecha, crecer, distribuciones] = franjas(data, ancho, alto);
  limpiarFueraDeFranjas(data, ancho, alto, [flecha, crecer, distribuciones]);

  const areaCompleto = caja(data, ancho, flecha.top, distribuciones.bottom);
  const areaCompacto = caja(data, ancho, flecha.top, crecer.bottom);
  // La flecha entera es casi el doble de ancha que de alta: en un cuadrado de
  // 16 px queda una raya de 9 px de alto. Sin el primer 30 % de la cola (que ahí
  // es un hilo amarillo) entra mucho más grande y se sigue leyendo igual.
  const flechaEntera = caja(data, ancho, flecha.top, flecha.bottom);
  const sinCola = Math.round(flechaEntera.width * 0.3);
  const areaIsotipo = { ...flechaEntera, left: flechaEntera.left + sinCola, width: flechaEntera.width - sinCola };

  const completo = recorte(data, ancho, alto, areaCompleto);
  const compacto = recorte(data, ancho, alto, areaCompacto);
  const isotipo = recorte(data, ancho, alto, areaIsotipo);

  const dataOscuro = Buffer.from(data);
  recolorear(dataOscuro, ancho, distribuciones, VERDE_OSCURO_SOBRE_NEGRO);
  const completoOscuro = recorte(dataOscuro, ancho, alto, areaCompleto);

  // Logos de la app. El completo se muestra a ~256 px de ancho, el compacto a
  // 36-40 px de alto y el isotipo a 28: estos tamaños alcanzan para pantallas 3x.
  await guardar(completo.clone().resize({ width: 768 }), join(marcaDir, 'crecer-logo.png'));
  await guardar(completoOscuro.clone().resize({ width: 768 }), join(marcaDir, 'crecer-logo-oscuro.png'));
  await guardar(compacto.clone().resize({ height: 128 }), join(marcaDir, 'crecer-compacto.png'));
  await guardar(isotipo.clone().resize({ height: 96 }), join(marcaDir, 'crecer-isotipo.png'));

  // Íconos de la app (manifest + iOS).
  for (const tamano of [64, 192, 512]) {
    await guardar(await icono(compacto, tamano, { escala: 0.8 }), join(publicDir, `pwa-${tamano}x${tamano}.png`));
  }
  // El precomposed es el mismo archivo con el nombre que algunas versiones de iOS
  // piden por su cuenta. Sin él, el fallback de la SPA les contesta 200 con el
  // index.html, iOS no lo puede leer como imagen y pone la letra sobre gris.
  for (const nombre of ['apple-touch-icon.png', 'apple-touch-icon-precomposed.png']) {
    await guardar(await icono(compacto, 180, { escala: 0.8 }), join(publicDir, nombre));
  }
  await guardar(await icono(compacto, 512, { escala: 0.66 }), join(publicDir, 'maskable-icon-512x512.png'));
  for (const nombre of ['shortcut-pedido.png', 'shortcut-clientes.png']) {
    await guardar(await icono(compacto, 96, { escala: 0.66 }), join(publicDir, nombre));
  }

  // Favicon. Los chicos van sin paleta: son de pocos bytes igual y la
  // cuantización se nota en 16 px.
  const PNG_CHICO = { compressionLevel: 9 };
  await guardar(favicon(isotipo, 16), join(publicDir, 'favicon-16x16.png'), PNG_CHICO);
  await guardar(favicon(isotipo, 32), join(publicDir, 'favicon-32x32.png'), PNG_CHICO);
  const pngsIco = [];
  for (const tamano of [16, 32, 48]) {
    pngsIco.push({ tamano, buffer: await favicon(isotipo, tamano).png(PNG_CHICO).toBuffer() });
  }
  writeFileSync(join(publicDir, 'favicon.ico'), ico(pngsIco));
  console.log(`Generated: ${join(publicDir, 'favicon.ico')}`);

  // Generar screenshots
  await generateScreenshot(join(publicDir, 'screenshot-wide.png'), 1280, 720, true);
  await generateScreenshot(join(publicDir, 'screenshot-narrow.png'), 640, 1136, false);

  console.log('\nAll PWA assets generated successfully!');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
