# Heuristics Checklist (UX)

Usar esta lista antes de mergear cambios de UI.

## 1) Visibilidad del estado
- [ ] Cada proceso largo muestra fase y progreso.
- [ ] Los errores explican qué pasó y qué hacer después.

## 2) Correspondencia con el mundo real
- [ ] Copy consistente en español (o idioma objetivo definido).
- [ ] Términos técnicos se explican con contexto breve.

## 3) Control y libertad del usuario
- [ ] Hay salida clara de paneles/modales.
- [ ] Acciones destructivas tienen confirmación o contexto.

## 4) Consistencia y estándares
- [ ] Se usan tokens de tema (tipografía/color/botones).
- [ ] No hay mezcla arbitraria ES/EN en la misma vista.

## 5) Prevención de errores
- [ ] Inputs inválidos se validan antes de ejecutar.
- [ ] Se evita estado ambiguo en transiciones.

## 6) Reconocimiento vs recuerdo
- [ ] Labels y ayudas son explícitas.
- [ ] Atajos y acciones frecuentes son visibles.

## 7) Flexibilidad y eficiencia
- [ ] Flujo principal requiere el menor número de pasos.
- [ ] Accesos rápidos (drag/drop, pegar URL, cola) funcionan.

## 8) Estética y diseño minimalista
- [ ] Animaciones orientan (no distraen).
- [ ] No hay más de una animación dominante por bloque principal.

## 9) Ayuda para recuperar errores
- [ ] Los mensajes de error ofrecen reintento o alternativa.
- [ ] Se conserva contexto del usuario tras fallo.

## 10) Ayuda y documentación
- [ ] Flujos críticos están documentados (`user-flow.md`).
- [ ] Estructura IA actualizada (`information-architecture.md`).
