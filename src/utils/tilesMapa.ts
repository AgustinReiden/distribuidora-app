/**
 * Base de mosaicos del mapa Leaflet (MapaRuta).
 *
 * Desde el 28/08/2026 CARTO exige API key en basemaps.cartocdn.com: sin `?key=`
 * no falla, devuelve 200 con cada mosaico estampado "API KEY REQUIRED". La key
 * es pública por diseño (viaja en el bundle) y se protege por referer en el
 * panel de CARTO: una para prod (el dominio) y otra aparte para localhost,
 * porque CARTO no deja mezclar los dos en la misma key.
 *
 * Sin key (worktree sin `.env`, staging) cae a OpenStreetMap en vez de mostrar
 * la marca de agua. Se usan los subdominios a/b/c porque la CSP (index.html y
 * el nginx de Coolify) habilita `*.tile.openstreetmap.org`, que no cubre el
 * host pelado.
 */

export interface TilesMapa {
  url: string;
  subdomains: string;
  maxZoom: number;
  attribution: string;
}

const ATRIBUCION_OSM =
  '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';

export function tilesMapa(cartoKey: string | undefined): TilesMapa {
  const key = cartoKey?.trim();
  if (key) {
    return {
      // CARTO Voyager. {r} sirve mosaicos @2x en pantallas retina (celulares).
      url: `https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png?key=${encodeURIComponent(key)}`,
      subdomains: 'abcd',
      maxZoom: 20,
      attribution: `${ATRIBUCION_OSM} &copy; <a href="https://carto.com/attributions">CARTO</a>`,
    };
  }
  return {
    url: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
    subdomains: 'abc',
    maxZoom: 19,
    attribution: ATRIBUCION_OSM,
  };
}
