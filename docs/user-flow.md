# User Flow

## Objetivo
Definir el recorrido principal del usuario para mantener decisiones de UX antes que decisiones de UI.

## Flujo principal (happy path)
1. **Inicio / Splash**
   - El sistema valida dependencias locales.
   - Se presenta estado listo sin bloquear al usuario más de lo necesario.
2. **Entrada de contenido**
   - Usuario arrastra archivo o selecciona desde picker.
   - Alternativa: pega URL y abre configuración.
3. **Configuración de transcripción**
   - Usuario confirma idioma, modelo y opciones de audio.
   - Acción principal: iniciar transcripción.
4. **Procesamiento**
   - Feedback claro de progreso y fase actual.
   - El usuario puede mantener contexto sin ruido visual excesivo.
5. **Resultado**
   - Vista de transcripción editable y navegable.
   - Acciones secundarias: buscar, copiar, exportar, revisar historial.
6. **Persistencia**
   - El resultado se guarda y aparece en historial/favoritos.

## Flujos alternos
- **Sin modelos/dependencias**: redirigir a Setup y volver al flujo principal al completar.
- **Error en procesamiento**: mostrar causa + acción recuperable (reintentar/ajustar).
- **Trabajo por lotes o cola**: encolar y abrir panel de cola sin perder foco.

## Criterios UX por paso
- Cada paso debe tener una acción primaria única y legible.
- Mensajes de estado en lenguaje consistente (español en UI actual).
- Animaciones: priorizar orientación/foco sobre decoración.
