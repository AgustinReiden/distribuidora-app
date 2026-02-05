/* eslint-disable no-undef */
/**
 * PWA Assets Generator
 *
 * Genera todos los iconos necesarios para la PWA a partir del SVG base.
 * Ejecutar con: node scripts/generate-pwa-assets.js
 */

import sharp from 'sharp';
import { readFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const publicDir = join(__dirname, '..', 'public');

// Configuración de iconos a generar
const icons = [
  { name: 'favicon-16x16.png', size: 16 },
  { name: 'favicon-32x32.png', size: 32 },
  { name: 'pwa-64x64.png', size: 64 },
  { name: 'pwa-192x192.png', size: 192 },
  { name: 'pwa-512x512.png', size: 512 },
  { name: 'apple-touch-icon.png', size: 180 },
  { name: 'shortcut-pedido.png', size: 96 },
  { name: 'shortcut-clientes.png', size: 96 },
];

// Icono maskable necesita padding extra para el safe zone
const maskableIcons = [
  { name: 'maskable-icon-512x512.png', size: 512, padding: 80 },
];

async function generateIcon(svgPath, outputPath, size, padding = 0) {
  const svg = readFileSync(svgPath);

  if (padding > 0) {
    // Para maskable icons, crear con padding
    const innerSize = size - (padding * 2);
    const resized = await sharp(svg)
      .resize(innerSize, innerSize)
      .toBuffer();

    await sharp({
      create: {
        width: size,
        height: size,
        channels: 4,
        background: { r: 37, g: 99, b: 235, alpha: 1 } // #2563eb
      }
    })
      .composite([{
        input: resized,
        top: padding,
        left: padding
      }])
      .png()
      .toFile(outputPath);
  } else {
    await sharp(svg)
      .resize(size, size)
      .png()
      .toFile(outputPath);
  }

  console.log(`Generated: ${outputPath}`);
}

async function generateFavicon(svgPath, outputPath) {
  const svg = readFileSync(svgPath);

  // Por simplicidad, usamos el de 32x32 como .ico (browsers modernos lo soportan)
  await sharp(svg)
    .resize(32, 32)
    .toFile(outputPath.replace('.ico', '-32.png'));

  // Copiar como favicon.ico (PNG renombrado - funciona en browsers modernos)
  await sharp(svg)
    .resize(48, 48)
    .png()
    .toFile(outputPath);

  console.log(`Generated: ${outputPath}`);
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
  const svgPath = join(publicDir, 'icon.svg');

  if (!existsSync(svgPath)) {
    console.error('Error: icon.svg not found in public/');
    process.exit(1);
  }

  console.log('Generating PWA assets...\n');

  // Generar iconos regulares
  for (const icon of icons) {
    await generateIcon(svgPath, join(publicDir, icon.name), icon.size);
  }

  // Generar iconos maskable
  for (const icon of maskableIcons) {
    await generateIcon(svgPath, join(publicDir, icon.name), icon.size, icon.padding);
  }

  // Generar favicon
  await generateFavicon(svgPath, join(publicDir, 'favicon.ico'));

  // Generar screenshots
  await generateScreenshot(join(publicDir, 'screenshot-wide.png'), 1280, 720, true);
  await generateScreenshot(join(publicDir, 'screenshot-narrow.png'), 640, 1136, false);

  console.log('\nAll PWA assets generated successfully!');
}

main().catch(console.error);
