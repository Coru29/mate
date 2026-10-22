# Mate — diseño

Fecha: 2026-10-22 · Estado: aprobado por el usuario en el chat ("perfecto")

> La carpeta del proyecto se llama `notch`; la app se llama **Mate** (elegido por el usuario: "vamos con Mate dale"). En Uruguay el mate se va recargando como un cupo, y en inglés *mate* es "compañero".

## Intención

El usuario quiere un clon gratis y open source de [Agent Limit](https://agentlimit.app) (USD 5,99): una app nativa que vive junto al notch del MacBook y muestra cuánto queda de los límites de sesión y semanales de los agentes de código. Es el segundo proyecto de la línea "nuestras propias apps gratis, versión open source" después de Rambla (`~/Desktop/Proyectos/scroll`), y sigue su mismo procedimiento: spec → plan → construcción → DMG → repo público en GitHub (Coru29) → web.

Lo que el usuario agrega sobre el original:

- **Todos los agentes**, no solo los cuatro de Agent Limit, con proveedores enchufables para sumar más.
- **Varias cuentas por agente.** El usuario tiene dos cuentas de Claude y una sola sesión de Claude Code, que cambia con `/login` cuando una se queda sin cupo. Cada persona tiene que poder agregar sus cuentas como quiera.
- **Usar las sesiones que ya están en la Mac** (si Claude Code está logueado, Mate la toma sola).
- **Consumir lo mínimo posible.**
- **Firmar con la misma identidad que Rambla** (está en el llavero).

## Objetivos

- Paridad funcional con Agent Limit: pill junto al notch, panel al pasar el mouse, ventana de uso, indicadores de ritmo, alertas desde el notch, asistente inicial, notch dibujado en Macs sin notch (lista completa en "Comportamiento").
- Proveedores: Claude, Codex, Cursor, Gemini CLI, GitHub Copilot y Grok en la 1.0, detrás de un protocolo común.
- Varias cuentas por proveedor, sumadas de tres maneras (detección automática, login desde la app, carpeta de configuración).
- Cambiar con un click la cuenta activa de Claude Code desde el notch (propuesto por Claude, aceptado por el usuario).
- Recursos: 0 % de CPU en reposo, sin polling continuo, < ~30 MB de memoria con el panel cerrado.
- Instalación por DMG, firmada con la identidad de Rambla, con auto-actualización desde GitHub igual que Rambla.
- Interfaz en español e inglés.

## No-objetivos

- Licencias, pagos, cuentas propias de Mate o telemetría.
- Intel (solo arm64, sin Xcode no hay binario universal), notarización o Developer ID.
- Consumir APIs de pago o pedir claves cuando el proveedor ya dejó una sesión en la Mac (Grok es la excepción: no tiene sesión local).
- Widgets de escritorio.

## Anti-objetivos (sería un fracaso aunque "funcione")

- **Desloguear al usuario de un agente o romperle la sesión.** En particular: refrescar el token de la cuenta que el agente está usando (los refresh tokens rotan; si Mate lo consume, Claude Code o Codex quedan con uno inválido).
- Mostrar datos de una cuenta con el nombre de otra.
- Usar CPU en reposo o hacer polling cada pocos segundos.
- Que el pill o el panel se coman clicks cuando no están visibles, o que el pill ocupe más que una franja angosta pegada al notch (como Agent Limit; no se intenta detectar espacio libre en la barra de menú).
- Pedir el permiso del llavero de nuevo en cada actualización.
- Mandar un token a otro servidor que no sea el de su proveedor.

## Entorno del usuario

- MacBook Pro M5 con notch, macOS 26.6.2, a veces con un monitor externo de 2560×1440 (ver spec de Rambla). Solo Command Line Tools (Swift 6.3.3), Swift Testing disponible, sin XCTest.
- Usa Claude Code con una sesión que alterna entre dos cuentas. No se verificó qué otros agentes tiene instalados (el clasificador de permisos bloquea explorar credenciales); el asistente inicial lo detecta.
- Rambla corre al mismo tiempo; Mate no tiene que interferir con su barra indicadora ni sus overlays.

## Comportamiento

### Modelo

- **Proveedor**: un agente (Claude, Codex…). Sabe dónde están sus sesiones locales, cómo pedir el uso, cómo leer sus logs y qué ventanas de límite tiene.
- **Cuenta**: una identidad de un proveedor (email o id de cuenta). Tiene nombre visible editable, color, fuente (cómo se sumó) y **dueño del token** (ver "Cuentas").
- **Ventana de límite**: sesión de 5 h, semanal, semanal por modelo (Opus/Sonnet), ciclo de facturación, presupuesto mensual, cupo diario por modelo. Cada una tiene % usado, fecha de reset y duración.
- **Muestra**: cada lectura de uso (cuenta, ventana, %, hora) se guarda para calcular el ritmo.

### Pill junto al notch

- Mientras haya un agente activo aparece a la derecha del notch un anillo con el % de la ventana más apretada del proveedor activo (la de mayor uso relativo al tiempo). Desaparece cuando no hay nada corriendo. Opción: "Mostrar siempre".
- **Activo** = algún log de sesión del proveedor se escribió en los últimos 2 minutos, o Cursor es la app al frente. La detección es por FSEvents sobre las carpetas de sesiones (ver "Recursos"), no por listar procesos.
- El color del anillo sigue el estado de ritmo (verde, amarillo, rojo).
- Si hay varios agentes activos, el pill muestra el último que escribió.

### Panel (hover)

- Al pasar el mouse por el notch o el pill se despliega hacia abajo un panel negro que continúa la forma del notch. Funciona aunque el pill esté oculto (pasar por el notch siempre lo abre).
- Muestra, para la cuenta seleccionada: medidores de sesión y semanal (y los extra que tenga), hora de reset de cada uno, estado de ritmo, el proyecto en el que estás (carpeta del último log) y una fila de sesión en vivo con proyecto, tiempo transcurrido y tokens usados.
- Abajo, puntitos por cada cuenta de cada proveedor habilitado. Scroll sobre el panel o click en un puntito para cambiar. Orden: proveedores en el orden de Configuración, cuentas dentro de cada uno.
- En cuentas de Claude que no son la activa de Claude Code aparece **"Usar en Claude Code"** (ver "Cambio de cuenta").
- Se cierra al sacar el mouse (con un pequeño retardo) o con Esc.
- Click derecho en el notch o el pill: menú con Uso, Configuración, Actualizar ahora, Pausar, Salir.

### Ventana de uso (click)

- Gráfico de tokens de los últimos 7 días (barras por día, apiladas por proveedor) y desglose de los últimos 30 días por modelo (tokens y costo estimado a precio de API, marcado como estimado).
- Totales de hoy por proveedor.
- Filtro por proveedor y por cuenta cuando el log permite saber la cuenta (Claude y Codex guardan el log por carpeta de configuración; las sesiones de la misma carpeta se atribuyen a la cuenta que estaba activa a esa hora, según el historial de cambios que Mate registra).
- Fuente: solo los logs locales de Claude Code, Codex y Gemini CLI. Cursor, Copilot y Grok solo muestran sus medidores.

### Ritmo

Para cada ventana con duración conocida:

- **Al día**: uso ≤ tiempo transcurrido + 5 puntos.
- **Va rápido**: por encima de eso, pero la proyección no llega a 100 % antes del reset.
- **Se acaba a las HH:MM** (rojo): proyección lineal con la tasa de las muestras de la última hora (o de toda la ventana si hay menos de una hora de muestras) llega a 100 % antes del reset.
- **Límite alcanzado**: ≥ 100 %, con la hora de reset.

### Alertas

- Bajan desde el notch, dicen una sola cosa ("Claude · Personal: 90 % de la sesión, se acaba 16:40") y vuelven a subir a los 4 s. Click lleva al panel.
- Se disparan al cruzar 75 %, 90 % y 100 % de cada ventana de cada cuenta, y cuando una ventana se reinicia (si estaba arriba del 75 %). Una vez por cruce y por período.
- Umbrales editables y alertas apagables por proveedor. Opción, apagada por defecto, para mandar además una notificación del sistema.

### Macs sin notch y pantallas externas

- En pantallas sin notch, Mate dibuja su propio notch negro centrado arriba (mismo tamaño que el del MacBook) y todo funciona igual.
- Pantalla: la integrada si existe; opción para elegir otra o "la que tiene el cursor".
- Cuando la barra de menú está oculta (app en pantalla completa), el pill se oculta; el hover sobre el borde superior sigue abriendo el panel.

### Cuentas

Tres maneras de sumar una cuenta, que conviven:

1. **Detección automática.** Mate lee la sesión que cada agente dejó en la Mac. Cada vez que aparece una identidad nueva (el usuario hizo `/login` con otra cuenta), Mate la suma como cuenta nueva. La anterior no se pierde: Mate se queda con una copia de sus tokens en su propio llavero y la sigue mostrando.
2. **"Agregar cuenta…" con el login del proveedor** desde Configuración (OAuth en el navegador, el mismo flujo que usa el CLI del proveedor), sin tocar la sesión del agente.
   En la 1.0 existe para Claude y Codex (reusan el flujo OAuth público de sus CLIs, igual que Agent Limit reusa sus sesiones). Cursor, Gemini y Copilot suman cuentas solo por detección automática: cada sesión nueva que aparece queda guardada.
3. **Carpeta de configuración**: apuntar a otro `CLAUDE_CONFIG_DIR` o `CODEX_HOME`, para quien corre dos instancias en paralelo. Esa carpeta pasa a vigilarse como la de por defecto.

Además: renombrar, elegir color, ocultar o borrar cada cuenta. Borrar una cuenta que Mate posee borra su copia de tokens; nunca toca la sesión del agente.

**Dueño del token.** Cada cuenta tiene exactamente un dueño:

- **El agente** (la cuenta es la que está logueada ahora en Claude Code o Codex): Mate solo la lee, nunca la refresca ni la reescribe. Si el token venció, Mate espera a que el agente lo refresque y mientras muestra el último dato con "hace N min".
- **Mate** (cuenta que el agente dejó de usar, o sumada con "Agregar cuenta…"): Mate guarda los tokens en su llavero y los refresca él. Si el refresh falla (token revocado), la cuenta queda "Sesión vencida" con un botón para volver a entrar con el login del proveedor.
- Cuando el agente vuelve a loguearse con una cuenta que Mate posee, la propiedad pasa al agente y Mate descarta su copia.

### Cambio de cuenta (Claude Code)

- "Usar en Claude Code" en una cuenta que posee Mate escribe sus credenciales en la sesión de Claude Code (el ítem del llavero y la identidad visible en `~/.claude.json`), y la que estaba activa pasa a ser de Mate. Las dos cuentas cambian de dueño en un solo paso; nunca hay dos dueños.
- Antes de escribir, Mate guarda una copia de lo que había (para deshacer si algo falla) y confirma con un diálogo la primera vez.
- Riesgo a verificar al construir: que una sesión de Claude Code abierta refresque y reescriba su token viejo encima del que escribió Mate (dos dueños, posible deslogueo). Si pasa, el botón queda deshabilitado mientras haya un proceso `claude` corriendo, con el texto "Cerrá las sesiones de Claude Code para cambiar". Si no pasa, solo se avisa que las sesiones abiertas siguen con la cuenta anterior hasta reiniciarse.
- Si resulta que `/login` o `/logout` revocan en el servidor los tokens de la cuenta anterior, la copia de Mate muere y la cuenta queda "Sesión vencida" con "Volver a entrar" (flujo OAuth propio). Por eso el login desde Mate es parte de la 1.0 para Claude.
- Lo mismo para Codex si es igual de directo (`auth.json`); si no, queda para después.

### Asistente inicial

- En el primer arranque: bienvenida, detección de qué agentes tienen sesión en la Mac, explicación del diálogo del llavero que macOS va a mostrar ("Mate quiere acceder a …": tocar "Permitir siempre") y opción de iniciar con la sesión.
- Al final muestra el panel por primera vez con una indicación de dónde vive.

### Configuración (SwiftUI, ventana con barra lateral)

- **General**: iniciar con la sesión, pantalla, mostrar pill siempre o solo con actividad, idioma (sistema/español/inglés).
- **Cuentas**: lista agrupada por proveedor con fuente, dueño y estado; agregar, renombrar, color, ocultar, borrar; habilitar o deshabilitar proveedores y su orden.
- **Alertas**: umbrales, por proveedor, notificación del sistema.
- **Grok**: management key y team id (en el llavero) y presupuesto mensual.
- **Actualizaciones** y **Acerca de** (versión, repo, licencia), como Rambla.
- Abrir Mate de nuevo desde Aplicaciones o Spotlight abre la Configuración.

### Persistencia

- Preferencias en `UserDefaults` (`io.github.coru29.Mate`).
- Cuentas, muestras de uso, offsets de logs y agregados diarios en `~/Library/Application Support/Mate/` (JSON o SQLite, a elección del constructor).
- Tokens que posee Mate y claves de Grok: solo en el llavero, servicio `io.github.coru29.Mate.<proveedor>`.

## Proveedores

Fuentes conocidas (de Agent Limit y del proyecto open source CodexBar); todas sin documentación oficial, así que se verifican al construir y se aíslan para poder cambiarlas en una actualización.

| Proveedor | Sesión local | Uso (ventanas) | Logs de tokens |
|---|---|---|---|
| Claude | Llavero, servicio `Claude Code-credentials` (con `CLAUDE_CONFIG_DIR` el nombre lleva un sufijo derivado de la carpeta); identidad en `~/.claude.json` (`oauthAccount`) | `GET https://api.anthropic.com/api/oauth/usage` con `anthropic-beta: oauth-2025-04-20`: `five_hour`, `seven_day`, `seven_day_opus`/`sonnet`, uso extra | `~/.claude/projects/**/*.jsonl` (`message.usage`, modelo, hora, `cwd`) |
| Codex | `~/.codex/auth.json` (o `$CODEX_HOME`); email del `id_token` | `GET https://chatgpt.com/backend-api/wham/usage` con `ChatGPT-Account-Id`: ventana primaria y secundaria. Respaldo: los eventos `token_count` del log traen `rate_limits` | `~/.codex/sessions/**/rollout-*.jsonl` |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (`cursorAuth/accessToken`, email) | API de uso de cursor.com: ciclo de facturación, % incluido y gasto on-demand | — |
| Gemini CLI | `~/.gemini/oauth_creds.json` | Cupo diario por modelo (`retrieveUserQuota` de Code Assist) | logs de `~/.gemini` si traen tokens |
| GitHub Copilot | token de `gh` o de las apps de Copilot (`~/.config/github-copilot`) | `copilot_internal/user`: cupo de premium requests y fecha de reset | — |
| Grok | ninguna: management key + team id en Configuración | gasto mensual de la API contra el presupuesto | — |

- Cada proveedor implementa un protocolo común (detectar sesiones, leer identidad, pedir uso, refrescar si es dueño, leer logs incrementalmente, describir sus ventanas). Sumar uno nuevo es agregar un archivo.
- Los tokens van solo al servidor de su proveedor. Las únicas otras conexiones de Mate son las del chequeo de actualizaciones a GitHub.

## Recursos

- **Nada de polling continuo.** La actividad sale de un único stream de FSEvents sobre las carpetas de sesiones (`~/.claude/projects`, `~/.codex/sessions`, `~/.gemini`, y las carpetas de configuración agregadas) con latencia de ~1 s, más `NSWorkspace` para la app al frente (Cursor). El estado "inactivo" se programa con un timer de una sola vez a los 2 min de la última escritura.
- **Pedidos de uso**: cada 5 min mientras hay actividad del proveedor o el panel está abierto; cada 30 min si no (para alertas y cuentas en reposo). Al abrir el panel se refresca si el dato tiene más de 1 min. Timers con tolerancia amplia para que el sistema los agrupe; `NSBackgroundActivityScheduler` para los de reposo.
- **Resets**: un timer de una sola vez a la hora de reset de cada ventana, no polling.
- **Logs**: lectura incremental desde el último offset guardado, solo de los archivos que FSEvents marcó; los agregados diarios se guardan y nunca se reprocesan enteros (salvo el primer arranque, en segundo plano y con prioridad baja).
- **UI**: las vistas SwiftUI del panel y de la ventana de uso se crean al abrirse y se liberan al cerrarse. El pill es una capa mínima.
- **Meta**: 0 % de CPU en reposo medido con `top`/Activity Monitor durante 10 min antes de cada release, y < ~30 MB de memoria con el panel cerrado. (En Rambla un loop de eventos quemó ~45 % de CPU sin que nadie lo notara: medirlo siempre.)

## Arquitectura

- Swift Package como Rambla: `MateCore` (lógica pura testeable: modelo, ritmo, umbrales de alertas, parseo de respuestas y de logs, agregados, reglas de dueño de token) + ejecutable `Mate` (AppKit + SwiftUI: ventanas del notch, llavero, red, FSEvents, configuración, actualizador) + `MateCoreTests` (Swift Testing).
- App agente (`LSUIElement`, sin Dock ni ícono en la barra de menú). Toda la UI del notch en un `NSPanel` no activante, sin sombra, por encima de la barra de menú, que solo acepta eventos del mouse en la zona visible (el resto deja pasar los clicks).
- Posición del notch con `NSScreen.safeAreaInsets` y `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`.
- Red con `URLSession` efímera, sin caché en disco.
- Acceso al llavero ajeno (ítem de Claude Code) con Security.framework; el diálogo de macOS aparece una vez y "Permitir siempre" se mantiene entre actualizaciones porque la firma es estable.
- Bundle id `io.github.coru29.Mate`.

### Firma, empaquetado, actualizaciones

- **Misma identidad que Rambla** ("Rambla Local Signing"): `scripts/sign.sh` usa el keychain `~/Desktop/Proyectos/scroll/.signing/rambla-signing.keychain-db` (ruta configurable por variable de entorno) y la contraseña de `RAMBLA_SIGNING_PASSWORD` o del ítem `io.github.coru29.Rambla.signing` del llavero de login. Nunca crea una identidad nueva: si no encuentra el keychain o la contraseña, falla con un mensaje claro.
- Scripts como Rambla: `build.sh`, `dmg.sh`, `install.sh`, `release.sh` (Conventional Commits, notas bilingües), `make-icon.swift`, `test.sh`, chequeo de localización.
- Auto-actualización desde los releases de GitHub (`Coru29/mate`, nombre del repo a confirmar si está tomado) con la misma verificación de firma que el `Updater` de Rambla.
- Requisitos: macOS 14+, arm64. MIT.

### Pruebas

- `MateCore` con TDD: ritmo, umbrales y rearmado de alertas, parseo de cada respuesta de proveedor (fixtures anonimizados), parseo incremental de logs, atribución de sesiones a cuentas, transiciones de dueño de token y del cambio de cuenta.
- App: verificación en vivo con un modo de prueba que usa un proveedor falso (sin red) para el pill, el panel, las alertas y la ventana de uso, y con las sesiones reales del usuario para Claude.
- Medición de CPU y memoria en reposo antes de cada release.

## Decisiones mías (a confirmar al leer)

- Seis proveedores en una sola 1.0 (Claude, Codex, Cursor, Gemini CLI, Copilot, Grok), construidos en ese orden: Claude completo primero (es el caso del usuario), después Codex, después el resto.
- "Agregar cuenta…" con login propio solo para Claude y Codex en la 1.0; los demás suman cuentas por detección.
- Cambio de cuenta bloqueado mientras corre Claude Code si se comprueba que pisa el token (ver "Cambio de cuenta").
- Pill a la derecha del notch; "activo" = log escrito en los últimos 2 min o Cursor al frente.
- Pedidos cada 5 min con actividad, 30 min en reposo.
- Sin ícono en la barra de menú: todo vive en el notch (click derecho para el menú) y reabrir la app abre Configuración, como Agent Limit.
- Costo estimado a precio de API en la ventana de uso, marcado como estimado.
- Notificaciones del sistema apagadas por defecto; las alertas son las del notch.
- La web y el dominio (por ejemplo `mate-mac.app`) quedan para después de la 1.0, como en Rambla.
