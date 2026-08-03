# Equipo de Desarrollo Autónomo

Una canalización de desarrollo completamente automatizada que convierte incidencias en solicitudes de extracción fusionadas — sin intervención humana requerida. Escanea incidencias con la etiqueta `autonomous`, envía un **Agente de Desarrollo** para implementar la funcionalidad con pruebas en un worktree aislado, y entrega el resultado a un **Agente de Revisión** para la revisión de código con verificación E2E opcional. Todo el ciclo se ejecuta sin supervisión en un horario cron.

- **Plataformas de código**: GitHub y GitLab (gitlab.com o cualquier instancia auto-gestionada estándar) mediante interfaces de proveedor intercambiables — véase [Soporte para GitLab](#gitlab-support).
- **CLIs de agentes**: Claude Code, Codex CLI, Kiro CLI, opencode, Cursor Agent, Antigravity CLI (agy) y la mayoría de las CLIs con una bandera no interactiva `-p <prompt>` — véase [docs/agent-clis.md](docs/agent-clis.md).

## Inicio Rápido

### Opción A: Instalar como habilidades portátiles (recomendado)

```bash
npx skills add zxkane/autonomous-dev-team
```

| Habilidad | Descripción |
|-------|-------------|
| **autonomous-dev** | Flujo de trabajo TDD con aislamiento de worktree, lienzo de diseño, desarrollo basado en pruebas, revisión de código y verificación CI |
| **autonomous-review** | Revisión de PR con verificación de lista de comprobación, resolución de conflictos de fusión, pruebas E2E y auto-fusión |
| **autonomous-dispatcher** | Escáner de incidencias que envía agentes de desarrollo y revisión en un horario cron |
| **autonomous-common** | Hooks de aplicación de flujo de trabajo compartidos y scripts utilitarios invocables por agentes |
| **create-issue** | Creación estructurada de incidencias con plantillas, orientación de etiqueta autonomous y adjuntos de cambios de espacio de trabajo |

Compatible con Claude Code, Cursor, Windsurf, Antigravity, Kiro CLI y [40+ agentes](https://skills.sh). Después de la instalación, sigue **[docs/installation.md](docs/installation.md)** para la configuración posterior (symlinks, plugins, `autonomous.conf`, etiquetas) — incluye un prompt copiable que permite a tu agente de IA conducir toda la configuración.

### Opción B: Usar como plantilla (canalización completa)

1. **Clonar y configurar**:
   ```bash
   gh repo create my-project --template zxkane/autonomous-dev-team
   cd my-project
   cp scripts/autonomous.conf.example scripts/autonomous.conf
   # Editar autonomous.conf — véase docs/installation.md Paso 4 para cada clave.
   ```

2. **Crear las etiquetas de la canalización**:
   ```bash
   ( source scripts/autonomous.conf && bash scripts/setup-labels.sh "$REPO" )
   ```

3. **Programar el tick del dispatcher.** Cualquier cosa que pueda ejecutar un comando shell con periodicidad funciona:

   | Host | Cuándo usarlo | Comando del tick |
   |------|------------|--------------|
   | [OpenClaw](https://github.com/OpenClaw/OpenClaw) (recomendado) | Runtime de habilidades dedicado | `openclaw run skills/autonomous-dispatcher/SKILL.md` |
   | Cron puro | Cero infraestructura adicional | `bash skills/autonomous-dispatcher/scripts/dispatcher-tick.sh` |
   | Programación de GitHub Actions / cualquier runtime programado | Infraestructura gestionada | mismo script de tick (o `dispatcher-multi-tick.sh` para multi-proyecto) |

   ```cron
   */5 * * * * cd /path/to/project && bash skills/autonomous-dispatcher/scripts/dispatcher-tick.sh
   ```

   El script de tick es independiente del host — solo necesita `jq`, una credencial de plataforma de código y un `autonomous.conf` accesible. El CLI del agente es invocado por el **wrapper** que el tick genera, no por el tick en sí.

4. **Crear una incidencia** con la etiqueta `autonomous` y observar cómo funciona la canalización — el dispatcher genera agentes, rastrea el progreso mediante etiquetas y fusiona la PR cuando la revisión aprueba.

## Cómo Funciona

```
Incidencia (etiqueta autonomous)
   │
   ▼
Dispatcher (tick cron) ──▶ Agente de Desarrollo ──────────▶ Agente de Revisión
   escanear + enviar        worktree + TDD              encontrar PR + revisar
   concurrencia + reintento  implementar + probar         verificación E2E opcional
                            abrir PR                      aprobar + fusionar
```

Las incidencias avanzan a través de etiquetas gestionadas automáticamente por los agentes:

```
autonomous → in-progress → pending-review → reviewing → approved (merged)
                                                 │
                                                 └─→ pending-dev (bucle si la revisión falla)
```

Con la etiqueta `no-auto-close`, la PR es aprobada pero no se fusiona automáticamente — se notifica al propietario del repositorio en su lugar.

Toda operación de incidencia/plataforma de código enruta a través de **interfaces de proveedor intercambiables** (`ISSUE_PROVIDER` / `CODE_HOST`): verbos abstractos con hojas por proveedor, probados por una suite de conformidad parametrizada por proveedor. El contrato normativo vive en [docs/pipeline/provider-spec.md](docs/pipeline/provider-spec.md).

| Componente | Wrapper / entrada | Habilidad | Detalles |
|---|---|---|---|
| Agente de Desarrollo | `scripts/autonomous-dev.sh` | `skills/autonomous-dev/SKILL.md` | aislamiento de worktree, TDD, seguimiento de casillas de verificación, reanudación tras retroalimentación |
| Agente de Revisión | `scripts/autonomous-review.sh` | `skills/autonomous-review/SKILL.md` | descubrimiento de PR, rebase de conflictos, revisores bots, veredictos multi-agente, E2E, auto-fusión |
| Dispatcher | `scripts/dispatcher-tick.sh` | `skills/autonomous-dispatcher/SKILL.md` | escaneo de incidencias, control de concurrencia, detección de obsoletas |

La revisión multi-agente (`AGENT_REVIEW_AGENTS`), los bots de revisión externos (`REVIEW_BOTS`) y la configuración por CLI se cubren en [docs/agent-clis.md](docs/agent-clis.md).

## Soporte para GitLab

Ambas interfaces de proveedor aceptan `gitlab`: incidencias y solicitudes de fusión en gitlab.com o cualquier instancia CE/EE auto-gestionada cuya API responda a autenticación PAT estándar contra `/api/v4`.

```bash
# scripts/autonomous.conf
ISSUE_PROVIDER="gitlab"
CODE_HOST="gitlab"
GITLAB_HOST="gitlab.example.com"          # valor predeterminado gitlab.com
GITLAB_TOKEN="glpat-…"                    # token PAT / proyecto / grupo, ámbito `api`
GITLAB_PROJECT="group%2Fsubgroup%2Fproject"   # namespace/nombre codificado en URL
```

- **Guía de configuración**: [docs/gitlab-setup.md](docs/gitlab-setup.md) — creación de tokens, configuración de instancias auto-gestionadas, el modelo de autenticación y pasos de verificación.
- **Puertas de enlace de autenticación personalizadas** (instancias con cookie SSO, mTLS, transportes bifurcados): compatibles **fuera del árbol** mediante `GITLAB_TRANSPORT_HOOK` — un archivo propiedad del operador que reemplaza el primitivo HTTP único mientras la biblioteca mantiene la paginación, retroceso y semánticas de cierre ante fallos. El contrato está en [docs/pipeline/provider-spec.md](docs/pipeline/provider-spec.md) §transport.
- **Diferencias de capacidades vs GitHub** (declaradas en `providers/chp-gitlab.caps`, los llamantes bifurcan automáticamente): sin bots de revisión externos (`review_bots=0`), sin objeto REST "request changes" (los hallazgos se publican como comentarios + etiquetas), el cierre automático se dispara solo al fusionar en la rama predeterminada, y los tokens de agente están confinados por convención (GitLab no tiene equivalente a GitHub App — véase [docs/security.md](docs/security.md)).

GitHub sigue siendo el valor predeterminado: una configuración existente sin claves de proveedor se comporta de forma idéntica a nivel de bytes.

## Seguridad

**Diseñado para repositorios privados y entornos de confianza.** La canalización ejecuta el contenido de las incidencias como instrucciones del agente — en un repositorio público, eso es una superficie de inyección de prompt. Lee **[docs/security.md](docs/security.md)** para el modelo de riesgo, recomendaciones por entorno, la lista de verificación de mitigaciones y la postura de tokens por plataforma de código. Mínimo para repositorios públicos: restringir quién puede aplicar la etiqueta `autonomous`, y usar `no-auto-close` para que las fusiones se mantengan manuales.

## Flujo de Trabajo de Desarrollo Interactivo

Más allá del modo autónomo, los mismos hooks aplican un flujo de trabajo TDD para sesiones interactivas de agentes de código:

```
Lienzo de Diseño → Worktree → Casos de Prueba → Implementación → Pruebas Unitarias
   → code-simplifier → commit → pr-review → push → CI → E2E
```

- Flujo de trabajo paso a paso: [CLAUDE.md](CLAUDE.md)
- Referencia de hooks + gestor de estado:
  [skills/autonomous-common/hooks/README.md](skills/autonomous-common/hooks/README.md)
- Soporte de hooks entre agentes (Kiro, Cursor, …):
  [docs/cross-agent-hooks.md](docs/cross-agent-hooks.md)

## Índice de Documentación

| Tema | Dónde |
|---|---|
| Instalar + configurar (impulsado por agente, paso a paso) | [docs/installation.md](docs/installation.md) |
| CLIs de agentes: matriz de soporte, banderas por CLI, revisión multi-agente | [docs/agent-clis.md](docs/agent-clis.md) |
| Configuración de GitLab (tokens, auto-gestionado, hook de transporte) | [docs/gitlab-setup.md](docs/gitlab-setup.md) |
| Autenticación de GitHub App (identidades de bots, división de dos tokens) | [docs/github-app-setup.md](docs/github-app-setup.md) |
| Modelo de seguridad + mitigaciones | [docs/security.md](docs/security.md) |
| Visión general de la canalización (arquitectura, concurrencia) | [docs/autonomous-pipeline.md](docs/autonomous-pipeline.md) |
| Especificación de la canalización (máquina de estados, invariantes, flujos) | [docs/pipeline/](docs/pipeline/) |
| Interfaces de proveedor (verbos ITP/CHP, conformidad, transporte) | [docs/pipeline/provider-spec.md](docs/pipeline/provider-spec.md) |
| Referencia de hooks + gestor de estado | [skills/autonomous-common/hooks/README.md](skills/autonomous-common/hooks/README.md) |
| Configuración del flujo de trabajo CI | [docs/github-actions-setup.md](docs/github-actions-setup.md) |
| Flujo de trabajo TDD interactivo | [CLAUDE.md](CLAUDE.md) |

## Proyecto de Referencia

Esta plantilla se basa en la implementación del sistema de memoria y hooks de Claude Code de [Openhands Infra](https://github.com/zxkane/openhands-infra).

## Licencia

Licencia MIT
