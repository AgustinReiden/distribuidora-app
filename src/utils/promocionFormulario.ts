/**
 * El stock por bloque que manda el formulario de una promo de fracción.
 *
 * No es un campo visible: una promo nueva nace con 1 (un fardo del contenedor
 * por bloque cerrado). Pero una promo que ya tiene otro valor lo conserva. Antes
 * el formulario mandaba siempre 1: lo pisaba en silencio y, desde la 512
 * (`trg_promo_config_barra_con_pedidos`), con pedidos abiertos en la barra ni
 * siquiera dejaba estirar la vigencia, con un rechazo que nombra un campo que no
 * se ve (L3 de la revisión de la ola 1, plan #1603).
 */
export function stockPorBloqueDelFormulario(actual: number | string | null | undefined): number {
  const n = Number(actual)
  return Number.isInteger(n) && n > 0 ? n : 1
}
