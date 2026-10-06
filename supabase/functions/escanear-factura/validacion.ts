// Normalización y validación de lo que Gemini leyó de una factura (schema v2).
//
// Módulo PURO: sin Deno.env, sin red. Lo testea
// supabase/functions/tests/escanear_factura.test.ts con facturas sintéticas.
//
// Regla de oro: NUNCA "arreglar" un número. El modelo puede leer mal un 8 por
// un 3, y si acá se recalculara el importe a partir de cantidad × precio, la
// compra quedaría cargada con un número que no está en el papel y nadie lo
// vería. Lo que no cuadra se informa en `advertencias` con los dos números, y
// decide la persona que tiene la factura en la mano. Sí se normaliza el
// FORMATO (separadores de miles, CUIT con guiones, fecha a ISO): eso no cambia
// el valor.

// ---------------------------------------------------------------------------
// Tipos de salida (lo que recibe el front)
// ---------------------------------------------------------------------------

export type TipoComprobante = "A" | "B" | "C" | "remito" | "otro";
/** Tipo de compra de la app: FC = factura con IVA discriminado, ZZ = lo pagado es el costo. */
export type TipoFacturaApp = "FC" | "ZZ";

export interface LineaFactura {
  codigo: string | null;
  /** Tal cual está impresa. */
  descripcion: string;
  cantidad: number | null;
  unidad: "bulto" | "unidad" | null;
  unidadesPorBulto: number | null;
  precioUnitarioNeto: number | null;
  /** PORCENTAJE de bonificación de la línea (10 = 10%), no unidades sin cargo. */
  bonificacionPct: number | null;
  importeNeto: number | null;
  alicuotaIva: number | null;
  impuestoInternoMonto: number | null;
  legible: boolean;
}

export interface MontoPorAlicuota {
  alicuota: number;
  monto: number;
}

export interface MontoPorTasa {
  tasa: number | null;
  monto: number;
}

export interface DescuentoPie {
  descripcion: string;
  /** Positivo: lo que se descuenta. */
  monto: number;
}

export interface PieFactura {
  netoGravado: number | null;
  noGravado: number | null;
  exento: number | null;
  iva: MontoPorAlicuota[];
  impuestosInternos: MontoPorTasa[];
  percepcionIva: number | null;
  percepcionIibb: number | null;
  otrosTributos: number | null;
  descuentosPie: DescuentoPie[];
  total: number | null;
}

export interface FacturaV2 {
  version: 2;
  tipoComprobante: TipoComprobante;
  /** Ver `tipoFacturaApp`. null = el comprobante no dice (el usuario elige). */
  tipoFactura: TipoFacturaApp | null;
  puntoVenta: string | null;
  numero: string | null;
  /** "0005-00455160" — lo que va en el N° de factura de la compra. */
  numeroCompleto: string | null;
  fechaEmision: string | null;
  proveedor: { nombre: string | null; cuit: string | null };
  condicionVenta: string | null;
  items: LineaFactura[];
  pie: PieFactura;
  confianza: number;
}

export type NivelAdvertencia = "error" | "aviso";

export interface Advertencia {
  /** `error`: un número no cierra. `aviso`: algo para mirar, no necesariamente mal. */
  nivel: NivelAdvertencia;
  codigo: string;
  mensaje: string;
  /** 1-based. Ausente = advertencia de la factura entera. */
  linea?: number;
}

export interface ResultadoNormalizacion {
  data: FacturaV2;
  advertencias: Advertencia[];
}

// ---------------------------------------------------------------------------
// Tolerancias
// ---------------------------------------------------------------------------

/**
 * Cuánto se tolera entre dos montos antes de avisar: el mayor entre un peso y
 * el 0,1% del monto. Un peso cubre el redondeo de centavos línea por línea; el
 * relativo, un precio unitario impreso redondeado en una línea grande. Más
 * ancho deja pasar un dígito mal leído en una factura grande (el 0,5% de
 * $2.000.000 son $10.000).
 */
export const TOLERANCIA_ABSOLUTA = 1;
export const TOLERANCIA_RELATIVA = 0.001;

/** Por debajo de esta confianza declarada por el modelo, se avisa. */
export const CONFIANZA_MINIMA = 0.6;

export const ALICUOTAS_IVA_CONOCIDAS = [0, 2.5, 5, 10.5, 21, 27];

export function cuadra(a: number, b: number): boolean {
  const tol = Math.max(TOLERANCIA_ABSOLUTA, TOLERANCIA_RELATIVA * Math.max(Math.abs(a), Math.abs(b)));
  return Math.abs(a - b) <= tol;
}

// ---------------------------------------------------------------------------
// Parsers de formato
// ---------------------------------------------------------------------------

/**
 * Número en formato argentino ("1.234,56", "$ 1.234", "12,5") o JSON. Devuelve
 * null si no se puede leer — nunca adivina un 0.
 *
 * Con punto y coma a la vez, el que aparece último es el decimal. Con un solo
 * punto seguido de exactamente tres dígitos ("1.234") es separador de miles,
 * que es como se imprime en Argentina; cualquier otro punto solo es decimal.
 */
export function parseNumeroAR(v: unknown): number | null {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v !== "string") return null;
  let s = v.trim().replace(/\$|\s|ARS/gi, "");
  if (!s) return null;
  let negativo = false;
  if (/^\(.*\)$/.test(s)) {
    negativo = true;
    s = s.slice(1, -1);
  }
  if (s.startsWith("-")) {
    negativo = !negativo;
    s = s.slice(1);
  }
  if (!/^[\d.,]+$/.test(s)) return null;

  const ultimaComa = s.lastIndexOf(",");
  const ultimoPunto = s.lastIndexOf(".");
  let normal: string;
  if (ultimaComa >= 0 && ultimoPunto >= 0) {
    normal = ultimaComa > ultimoPunto
      ? s.replace(/\./g, "").replace(",", ".")
      : s.replace(/,/g, "");
  } else if (ultimaComa >= 0) {
    const comas = s.split(",").length - 1;
    normal = comas > 1 ? s.replace(/,/g, "") : s.replace(",", ".");
  } else if (ultimoPunto >= 0) {
    const puntos = s.split(".").length - 1;
    const decimales = s.length - ultimoPunto - 1;
    normal = puntos > 1 || decimales === 3 ? s.replace(/\./g, "") : s;
  } else {
    normal = s;
  }
  if (!/^\d+(\.\d+)?$/.test(normal)) return null;
  const n = Number(normal);
  if (!Number.isFinite(n)) return null;
  return negativo ? -n : n;
}

const PESOS_CUIT = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2];

/**
 * CUIT a "XX-XXXXXXXX-X". `valido` dice si el dígito verificador cierra; uno
 * que no cierra se devuelve igual (formateado) y se avisa: puede ser un dígito
 * mal leído, y corregirlo acá sería inventar un CUIT.
 */
export function normalizarCuit(v: unknown): { cuit: string | null; valido: boolean; crudo: string | null } {
  if (typeof v !== "string" && typeof v !== "number") return { cuit: null, valido: false, crudo: null };
  const crudo = String(v).trim();
  if (!crudo) return { cuit: null, valido: false, crudo: null };
  const digitos = crudo.replace(/\D/g, "");
  if (digitos.length !== 11) return { cuit: null, valido: false, crudo };
  const suma = PESOS_CUIT.reduce((acc, p, i) => acc + p * Number(digitos[i]), 0);
  let dv = 11 - (suma % 11);
  if (dv === 11) dv = 0;
  const valido = dv !== 10 && dv === Number(digitos[10]);
  return {
    cuit: `${digitos.slice(0, 2)}-${digitos.slice(2, 10)}-${digitos.slice(10)}`,
    valido,
    crudo,
  };
}

function esFechaValida(y: number, m: number, d: number): boolean {
  if (y < 2000 || y > 2100 || m < 1 || m > 12 || d < 1) return false;
  const dt = new Date(Date.UTC(y, m - 1, d));
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 && dt.getUTCDate() === d;
}

/** "YYYY-MM-DD", "DD/MM/YYYY", "DD-MM-YY"… → "YYYY-MM-DD", o null. */
export function normalizarFecha(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const s = v.trim();
  let y: number, m: number, d: number;
  let match = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
  if (match) {
    [y, m, d] = [Number(match[1]), Number(match[2]), Number(match[3])];
  } else {
    match = s.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2}|\d{4})$/);
    if (!match) return null;
    d = Number(match[1]);
    m = Number(match[2]);
    y = Number(match[3]);
    if (match[3].length === 2) y += 2000;
  }
  if (!esFechaValida(y, m, d)) return null;
  return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

/**
 * Comprobante → tipo de compra de la app.
 *
 *   A       → FC. Es la única que discrimina IVA a un Responsable Inscripto: ese
 *             IVA es crédito fiscal y el costo es el neto.
 *   B, C    → ZZ. No discriminan IVA (la B lo trae adentro del precio, la C es
 *             de un monotributista y no tiene): no hay crédito que computar y
 *             lo pagado ES el costo, que es exactamente la regla de ZZ.
 *   remito  → ZZ. Mercadería sin factura: lo pagado es el costo.
 *   otro    → null. No se sabe (nota de crédito, ticket, ilegible): no se le
 *             cambia el tipo a la compra y elige el usuario.
 */
export function tipoFacturaApp(tipo: TipoComprobante): TipoFacturaApp | null {
  switch (tipo) {
    case "A":
      return "FC";
    case "B":
    case "C":
    case "remito":
      return "ZZ";
    default:
      return null;
  }
}

function normalizarTipoComprobante(v: unknown): TipoComprobante {
  if (typeof v !== "string") return "otro";
  const s = v.trim().toUpperCase();
  if (s === "A" || s === "B" || s === "C") return s;
  if (s === "REMITO" || s === "R" || s === "X" || s === "ZZ") return "remito";
  return "otro";
}

function texto(v: unknown): string | null {
  if (typeof v !== "string" && typeof v !== "number") return null;
  const s = String(v).trim();
  return s ? s : null;
}

function soloDigitos(v: unknown): string | null {
  const s = texto(v);
  if (!s) return null;
  const d = s.replace(/\D/g, "");
  return d ? d : null;
}

function esObjeto(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function lista(v: unknown): unknown[] {
  return Array.isArray(v) ? v : [];
}

function fmt(n: number): string {
  return n.toLocaleString("es-AR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function suma(ns: Array<number | null>): number {
  return ns.reduce<number>((acc, n) => acc + (n ?? 0), 0);
}

// ---------------------------------------------------------------------------
// Normalización + validación
// ---------------------------------------------------------------------------

/**
 * Toma el JSON crudo del modelo (ya parseado, sin confiar en su forma) y
 * devuelve la factura normalizada más las advertencias. No tira: lo que no se
 * puede leer queda en null y se avisa.
 */
export function normalizarFactura(crudo: unknown): ResultadoNormalizacion {
  const adv: Advertencia[] = [];
  const raw = esObjeto(crudo) ? crudo : {};

  // --- Cabecera ------------------------------------------------------------
  const tipoComprobante = normalizarTipoComprobante(raw.tipoComprobante);
  const tipoFactura = tipoFacturaApp(tipoComprobante);
  if (tipoComprobante === "B" || tipoComprobante === "C") {
    adv.push({
      nivel: "aviso",
      codigo: "FACTURA_SIN_IVA_DISCRIMINADO",
      mensaje: `Factura ${tipoComprobante}: no discrimina IVA, así que se carga como ZZ (lo pagado es el costo).`,
    });
  }
  if (tipoComprobante === "otro") {
    adv.push({
      nivel: "aviso",
      codigo: "TIPO_DESCONOCIDO",
      mensaje: "No se reconoció el tipo de comprobante (A, B, C o remito). Elegí FC o ZZ a mano.",
    });
  }

  const puntoVenta = soloDigitos(raw.puntoVenta);
  const numero = soloDigitos(raw.numero);
  const numeroCompleto = numero
    ? puntoVenta ? `${puntoVenta.padStart(4, "0")}-${numero.padStart(8, "0")}` : numero.padStart(8, "0")
    : null;

  const fechaCruda = texto(raw.fechaEmision);
  const fechaEmision = normalizarFecha(fechaCruda);
  if (fechaCruda && !fechaEmision) {
    adv.push({
      nivel: "aviso",
      codigo: "FECHA_INVALIDA",
      mensaje: `La fecha leída ("${fechaCruda}") no es una fecha válida. Cargala a mano.`,
    });
  }

  const provRaw = esObjeto(raw.proveedor) ? raw.proveedor : {};
  const cuit = normalizarCuit(provRaw.cuit);
  if (cuit.crudo && !cuit.cuit) {
    adv.push({
      nivel: "aviso",
      codigo: "CUIT_INVALIDO",
      mensaje: `El CUIT leído ("${cuit.crudo}") no tiene 11 dígitos.`,
    });
  } else if (cuit.cuit && !cuit.valido) {
    adv.push({
      nivel: "aviso",
      codigo: "CUIT_DIGITO_VERIFICADOR",
      mensaje: `El CUIT ${cuit.cuit} no pasa el dígito verificador: puede haber un número mal leído.`,
    });
  }

  // --- Líneas --------------------------------------------------------------
  const items: LineaFactura[] = [];
  lista(raw.items).forEach((itemCrudo) => {
    if (!esObjeto(itemCrudo)) return;
    const n = items.length + 1;
    const unidadCruda = typeof itemCrudo.unidad === "string" ? itemCrudo.unidad.trim().toLowerCase() : null;
    const linea: LineaFactura = {
      codigo: texto(itemCrudo.codigo),
      descripcion: texto(itemCrudo.descripcion) ?? "",
      cantidad: parseNumeroAR(itemCrudo.cantidad),
      unidad: unidadCruda === "bulto" || unidadCruda === "unidad" ? unidadCruda : null,
      unidadesPorBulto: parseNumeroAR(itemCrudo.unidadesPorBulto),
      precioUnitarioNeto: parseNumeroAR(itemCrudo.precioUnitarioNeto),
      bonificacionPct: parseNumeroAR(itemCrudo.bonificacionPct),
      importeNeto: parseNumeroAR(itemCrudo.importeNeto),
      alicuotaIva: parseNumeroAR(itemCrudo.alicuotaIva),
      impuestoInternoMonto: parseNumeroAR(itemCrudo.impuestoInternoMonto),
      legible: itemCrudo.legible !== false,
    };
    items.push(linea);
    validarLinea(linea, n, adv);
  });

  if (items.length === 0) {
    adv.push({
      nivel: "error",
      codigo: "SIN_LINEAS",
      mensaje: "No se leyó ninguna línea de producto.",
    });
  }

  // --- Pie -----------------------------------------------------------------
  const pieRaw = esObjeto(raw.pie) ? raw.pie : raw;
  const iva: MontoPorAlicuota[] = [];
  for (const e of lista(pieRaw.iva)) {
    if (!esObjeto(e)) continue;
    const alicuota = parseNumeroAR(e.alicuota);
    const monto = parseNumeroAR(e.monto);
    if (alicuota == null || monto == null) continue;
    iva.push({ alicuota, monto });
  }
  const impuestosInternos: MontoPorTasa[] = [];
  for (const e of lista(pieRaw.impuestosInternos)) {
    if (!esObjeto(e)) continue;
    const monto = parseNumeroAR(e.monto);
    if (monto == null) continue;
    impuestosInternos.push({ tasa: parseNumeroAR(e.tasa), monto });
  }
  const descuentosPie: DescuentoPie[] = [];
  for (const e of lista(pieRaw.descuentosPie)) {
    if (!esObjeto(e)) continue;
    const monto = parseNumeroAR(e.monto);
    if (monto == null) continue;
    // El signo con que venga impreso ("-3.000") no importa: es un descuento.
    descuentosPie.push({ descripcion: texto(e.descripcion) ?? "Descuento", monto: Math.abs(monto) });
  }
  const pie: PieFactura = {
    netoGravado: parseNumeroAR(pieRaw.netoGravado),
    noGravado: parseNumeroAR(pieRaw.noGravado),
    exento: parseNumeroAR(pieRaw.exento),
    iva,
    impuestosInternos,
    percepcionIva: parseNumeroAR(pieRaw.percepcionIva),
    percepcionIibb: parseNumeroAR(pieRaw.percepcionIibb),
    otrosTributos: parseNumeroAR(pieRaw.otrosTributos),
    descuentosPie,
    total: parseNumeroAR(pieRaw.total),
  };

  validarPie(items, pie, tipoComprobante, adv);

  // --- Confianza -----------------------------------------------------------
  const confRaw = parseNumeroAR(raw.confianza);
  const confianza = confRaw == null ? 0 : Math.min(1, Math.max(0, confRaw));
  if (confianza < CONFIANZA_MINIMA) {
    adv.push({
      nivel: "aviso",
      codigo: "CONFIANZA_BAJA",
      mensaje: `La lectura tiene confianza baja (${Math.round(confianza * 100)}%). Revisá todo contra el papel.`,
    });
  }

  return {
    data: {
      version: 2,
      tipoComprobante,
      tipoFactura,
      puntoVenta,
      numero,
      numeroCompleto,
      fechaEmision,
      proveedor: { nombre: texto(provRaw.nombre), cuit: cuit.cuit },
      condicionVenta: texto(raw.condicionVenta),
      items,
      pie,
      confianza,
    },
    advertencias: adv,
  };
}

function validarLinea(l: LineaFactura, n: number, adv: Advertencia[]): void {
  if (!l.legible) {
    adv.push({
      nivel: "aviso",
      codigo: "LINEA_ILEGIBLE",
      linea: n,
      mensaje: `La línea ${n} no se leyó con claridad: comparala con el papel.`,
    });
  }
  if (!l.descripcion) {
    adv.push({ nivel: "aviso", codigo: "LINEA_SIN_DESCRIPCION", linea: n, mensaje: `La línea ${n} no tiene descripción.` });
  }
  if (l.cantidad != null && l.cantidad <= 0) {
    adv.push({
      nivel: "error",
      codigo: "CANTIDAD_INVALIDA",
      linea: n,
      mensaje: `La línea ${n} tiene cantidad ${l.cantidad}.`,
    });
  }
  if (l.bonificacionPct != null && (l.bonificacionPct < 0 || l.bonificacionPct > 100)) {
    adv.push({
      nivel: "error",
      codigo: "BONIFICACION_FUERA_DE_RANGO",
      linea: n,
      mensaje: `La línea ${n} tiene una bonificación de ${l.bonificacionPct}%: tiene que estar entre 0 y 100.`,
    });
  }
  if (l.alicuotaIva != null && !ALICUOTAS_IVA_CONOCIDAS.includes(l.alicuotaIva)) {
    adv.push({
      nivel: "aviso",
      codigo: "ALICUOTA_INUSUAL",
      linea: n,
      mensaje: `La línea ${n} tiene IVA ${l.alicuotaIva}%, que no es una alícuota habitual.`,
    });
  }
  if (l.cantidad == null || l.precioUnitarioNeto == null || l.importeNeto == null) {
    adv.push({
      nivel: "aviso",
      codigo: "LINEA_INCOMPLETA",
      linea: n,
      mensaje: `A la línea ${n} le falta cantidad, precio o importe: no se pudo verificar la cuenta.`,
    });
    return;
  }
  const bonif = l.bonificacionPct ?? 0;
  const esperado = l.cantidad * l.precioUnitarioNeto * (1 - bonif / 100);
  if (!cuadra(esperado, l.importeNeto)) {
    const detalleBonif = bonif ? ` − ${bonif}%` : "";
    adv.push({
      nivel: "error",
      codigo: "LINEA_NO_CUADRA",
      linea: n,
      mensaje: `Línea ${n}: ${l.cantidad} × $${fmt(l.precioUnitarioNeto)}${detalleBonif} da $${fmt(esperado)}, ` +
        `pero el importe leído es $${fmt(l.importeNeto)}.`,
    });
  }
}

function validarPie(items: LineaFactura[], pie: PieFactura, tipo: TipoComprobante, adv: Advertencia[]): void {
  const sumaLineas = suma(items.map((l) => l.importeNeto));
  const descuentos = suma(pie.descuentosPie.map((d) => d.monto));
  const hayBase = pie.netoGravado != null || pie.exento != null || pie.noGravado != null;
  const base = suma([pie.netoGravado, pie.exento, pie.noGravado]);

  // Σ líneas vs neto gravado + exento + no gravado (− descuentos al pie)
  if (hayBase && items.length > 0) {
    if (!cuadra(sumaLineas - descuentos, base)) {
      if (descuentos > 0 && cuadra(sumaLineas, base)) {
        adv.push({
          nivel: "aviso",
          codigo: "DESCUENTOS_PIE_NO_RESTADOS",
          mensaje: `Las líneas suman lo mismo que el neto ($${fmt(base)}) sin restar los descuentos al pie ` +
            `($${fmt(descuentos)}). Revisá si el descuento ya está aplicado en las líneas.`,
        });
      } else {
        const conDesc = descuentos > 0 ? ` menos $${fmt(descuentos)} de descuentos al pie` : "";
        adv.push({
          nivel: "error",
          codigo: "SUMA_LINEAS_NO_CUADRA",
          mensaje: `Las líneas suman $${fmt(sumaLineas)}${conDesc}, pero neto gravado + exento + no gravado ` +
            `da $${fmt(base)}. Puede faltar una línea o haber un importe mal leído.`,
        });
      }
    }
  }

  // IVA por alícuota contra las líneas de esa alícuota
  if (tipo === "A" && pie.iva.length === 0) {
    adv.push({
      nivel: "aviso",
      codigo: "FACTURA_A_SIN_IVA",
      mensaje: "Es factura A pero no se leyó el IVA discriminado al pie.",
    });
  }
  const lineasGravadas = items.filter((l) => l.alicuotaIva != null && l.alicuotaIva > 0 && l.importeNeto != null);
  const sumaGravadas = suma(lineasGravadas.map((l) => l.importeNeto));
  // Los descuentos al pie bajan la base de IVA: se reparten en proporción
  // usando el neto gravado impreso, que ya los tiene restados.
  const factor = pie.netoGravado != null && sumaGravadas > 0 ? pie.netoGravado / sumaGravadas : 1;
  const alicuotasPie = new Set(pie.iva.map((e) => e.alicuota));
  for (const e of pie.iva) {
    let baseAlicuota: number | null;
    if (lineasGravadas.length > 0) {
      baseAlicuota = suma(lineasGravadas.filter((l) => l.alicuotaIva === e.alicuota).map((l) => l.importeNeto)) * factor;
    } else if (pie.iva.length === 1 && pie.netoGravado != null) {
      baseAlicuota = pie.netoGravado;
    } else {
      baseAlicuota = null;
    }
    if (baseAlicuota == null) continue;
    const esperado = baseAlicuota * e.alicuota / 100;
    if (!cuadra(esperado, e.monto)) {
      adv.push({
        nivel: "error",
        codigo: "IVA_NO_CUADRA",
        mensaje: `IVA ${e.alicuota}%: sobre una base de $${fmt(baseAlicuota)} daría $${fmt(esperado)}, ` +
          `pero el leído es $${fmt(e.monto)}.`,
      });
    }
  }
  if (pie.iva.length > 0) {
    const sinPie = [...new Set(lineasGravadas.map((l) => l.alicuotaIva as number))].filter((a) => !alicuotasPie.has(a));
    for (const a of sinPie) {
      adv.push({
        nivel: "aviso",
        codigo: "ALICUOTA_SIN_IVA_AL_PIE",
        mensaje: `Hay líneas al ${a}% de IVA pero al pie no figura IVA ${a}%.`,
      });
    }
  }

  // Impuesto interno: por línea vs al pie
  const iiLineas = items.filter((l) => l.impuestoInternoMonto != null);
  const iiPie = suma(pie.impuestosInternos.map((e) => e.monto));
  if (iiLineas.length > 0 && pie.impuestosInternos.length > 0) {
    const sumaIiLineas = suma(iiLineas.map((l) => l.impuestoInternoMonto));
    if (!cuadra(sumaIiLineas, iiPie)) {
      adv.push({
        nivel: "aviso",
        codigo: "II_LINEAS_VS_PIE",
        mensaje: `El impuesto interno de las líneas suma $${fmt(sumaIiLineas)} y el del pie $${fmt(iiPie)}.`,
      });
    }
  }

  // Total = suma de las partes
  if (pie.total == null) {
    adv.push({ nivel: "aviso", codigo: "SIN_TOTAL", mensaje: "No se leyó el total de la factura." });
    return;
  }
  const neto = hayBase ? base : sumaLineas - descuentos;
  const iiTotal = pie.impuestosInternos.length > 0 ? iiPie : suma(iiLineas.map((l) => l.impuestoInternoMonto));
  const partes = neto +
    suma(pie.iva.map((e) => e.monto)) +
    iiTotal +
    suma([pie.percepcionIva, pie.percepcionIibb, pie.otrosTributos]);
  if (!cuadra(partes, pie.total)) {
    adv.push({
      nivel: "error",
      codigo: "TOTAL_NO_CUADRA",
      mensaje: `Neto + IVA + impuestos internos + percepciones + otros tributos da $${fmt(partes)}, ` +
        `pero el total leído es $${fmt(pie.total)}.`,
    });
  }
}
