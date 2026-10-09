// Detección de números inventados en las respuestas del bot (#979).
//
// HEURÍSTICA, no prueba: marca sospechosos para que una persona los mire. Un
// número "respaldado" es uno que sale de lo que devolvieron las herramientas
// (tal cual, redondeado, en miles, un porcentaje de dos valores respaldados o
// la cantidad de elementos de una lista). Falsos negativos posibles: un número
// inventado que casualmente coincide con algún dato. Falsos positivos: una
// suma o diferencia que el modelo calculó bien (no se respalda a propósito:
// "el modelo suma de cabeza" es justo lo que queremos ver).

export interface NumeroTexto {
  /** Valor ya normalizado (con la escala aplicada si traía "M" o "mil"). */
  valor: number;
  /** Cantidad de decimales que mostraba el texto. */
  decimales: number;
  /** Margen de redondeo del texto (sólo con escala: "1,2 M" es 1.150.000-1.250.000). */
  tolerancia: number;
  porcentaje: boolean;
  escala: number;
  /** Cómo aparecía en el texto. */
  crudo: string;
}

// Lo que NO es un dato del negocio, sino fecha, hora, tamaño o presentación.
const IGNORAR: RegExp[] = [
  /\b\d{4}-\d{2}-\d{2}\b/g, // 2026-09-30
  /\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b/g, // 30/09/2026, 30-09-26
  /\b\d{1,2}\/\d{1,2}\b/g, // 30/09
  /\b\d{1,2}:\d{2}(?::\d{2})?\b/g, // 14:30
  /\b\d+(?:[.,]\d+)?\s*[x×]\s*\d+(?:[.,]\d+)?/gi, // 12 x 500
  /(?<![A-Za-z])[xX]\s*\d+(?:[.,]\d+)?/g, // x 6, x6
  /\b\d+(?:[.,]\d+)?\s*(?:lts?|litros?|cc|cm3|ml|grs?|gramos?|cm|mm|mts?)\b/gi, // 3 LT, 500 cc
  /\b\d+(?:[.,]\d+)?l\b/gi, // 3L
];

function limpiar(texto: string): string {
  let t = texto;
  for (const re of IGNORAR) t = t.replace(re, " ");
  return t;
}

function parsear(crudo: string): { valor: number; decimales: number } {
  const tienePunto = crudo.includes(".");
  const tieneComa = crudo.includes(",");
  let normal: string;
  if (tienePunto && tieneComa) {
    // El último separador es el decimal: "35.876,22" (es-AR) o "1,250.50" (en).
    normal = crudo.lastIndexOf(",") > crudo.lastIndexOf(".")
      ? crudo.replace(/\./g, "").replace(",", ".")
      : crudo.replace(/,/g, "");
  } else if (tienePunto) {
    // "1.250.130" y "1.250" son miles; "3.5" es decimal.
    normal = /^\d{1,3}(\.\d{3})+$/.test(crudo) ? crudo.replace(/\./g, "") : crudo;
  } else if (tieneComa) {
    // En es-AR la coma es siempre decimal ("1,250" = 1,25).
    normal = crudo.replace(/,/g, ".");
  } else {
    normal = crudo;
  }
  const dec = normal.includes(".") ? normal.split(".")[1].length : 0;
  return { valor: Number(normal), decimales: dec };
}

/** Números del texto con su detalle (los que importan para validar). */
export function extraerNumerosDetallados(texto: string): NumeroTexto[] {
  const t = limpiar(texto);
  const re =
    /(\d[\d.,]*\d|\d)(?:\s?(%)|\s?(millones|[Mm]illón|M(?![A-Za-z])|mil(?![a-záéíóúñ])))?/g;
  const out: NumeroTexto[] = [];
  for (const m of t.matchAll(re)) {
    const { valor: base, decimales } = parsear(m[1]);
    if (!Number.isFinite(base)) continue;
    const porcentaje = m[2] === "%";
    let escala = 1;
    if (m[3]) escala = m[3] === "mil" ? 1e3 : 1e6;
    // Un año ("en 2026") no es un dato del negocio.
    const antes = t.slice(Math.max(0, (m.index ?? 0) - 8), m.index ?? 0);
    if (
      escala === 1 && !porcentaje && /^(19|20)\d{2}$/.test(m[1]) &&
      /(de|en|del|año|desde|hasta)\s*$/i.test(antes)
    ) {
      continue;
    }
    const valor = base * escala;
    // Menores a 10 son demasiado ambiguos (cantidades chicas, "2 pedidos"), salvo "1,2 M".
    if (escala === 1 && Math.abs(valor) < 10) continue;
    out.push({
      valor,
      decimales,
      tolerancia: escala > 1 ? 0.5 * Math.pow(10, -decimales) * escala : 0,
      porcentaje,
      escala,
      crudo: m[0].trim(),
    });
  }
  return out;
}

/** Los números (ya parseados, en formato es-AR) que aparecen en la respuesta. */
export function extraerNumeros(texto: string): number[] {
  return extraerNumerosDetallados(texto).map((n) => n.valor);
}

/** Todos los valores numéricos de los resultados, y los largos de cada lista. */
function aplanar(resultados: unknown[]): { valores: number[]; largos: Set<number> } {
  const valores = new Set<number>();
  const largos = new Set<number>();
  const visitar = (v: unknown, prof: number) => {
    if (prof > 12 || v == null) return;
    if (typeof v === "number") {
      if (Number.isFinite(v)) valores.add(Math.abs(v));
    } else if (typeof v === "string") {
      // Los numeric de Postgres llegan como string.
      if (/^-?\d+(\.\d+)?$/.test(v.trim())) valores.add(Math.abs(Number(v)));
    } else if (Array.isArray(v)) {
      largos.add(v.length);
      for (const x of v) visitar(x, prof + 1);
    } else if (typeof v === "object") {
      for (const x of Object.values(v as Record<string, unknown>)) visitar(x, prof + 1);
    }
  };
  for (const r of resultados) visitar(r, 0);
  return { valores: [...valores], largos };
}

const redondear = (n: number, dec: number) => Math.round(n * 10 ** dec) / 10 ** dec;

function respaldado(
  n: NumeroTexto,
  valores: number[],
  largos: Set<number>,
  pares: number[],
): boolean {
  const v = n.valor;
  if (n.escala === 1 && Number.isInteger(v) && largos.has(v)) return true;
  for (const r of valores) {
    if (n.escala > 1) {
      if (Math.abs(r - v) <= n.tolerancia) return true;
      continue;
    }
    if (r === v || redondear(r, 2) === v || redondear(r, 1) === v || Math.round(r) === v) {
      return true;
    }
    // "Miles": $1.250 que en los datos es 1.250.130.
    if (Math.round(r / 1000) === v) return true;
  }
  if (n.porcentaje) {
    // Un porcentaje de dos valores respaldados: round(a / b * 100).
    for (const a of pares) {
      for (const b of pares) {
        if (b !== 0 && Math.round((a / b) * 100) === v) return true;
      }
    }
  }
  return false;
}

/**
 * Los números de la respuesta que no salen de ningún resultado de herramienta.
 * Respaldado = igual a un valor, igual tras redondear a 0, 1 o 2 decimales, en
 * miles (valor/1000 redondeado), con escala "M"/"mil" dentro del margen de
 * redondeo, un porcentaje round(a/b*100) de dos valores, o la cantidad de
 * elementos de alguna lista de los resultados.
 */
export function numerosInventados(texto: string, resultados: unknown[]): number[] {
  const { valores, largos } = aplanar(resultados);
  // Para los porcentajes se prueban pares: se acota para no explotar en listas largas.
  const pares = valores.slice(0, 600);
  const inventados: number[] = [];
  for (const n of extraerNumerosDetallados(texto)) {
    if (!respaldado(n, valores, largos, pares) && !inventados.includes(n.valor)) {
      inventados.push(n.valor);
    }
  }
  return inventados;
}
