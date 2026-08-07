# AI Provider Switcher

Barre de menus macOS qui injecte les providers tiers (**DeepSeek, GLM (Z.ai), OpenRouter, Ollama, Claude Code**) dans **Codex Desktop** (app ChatGPT) et les sessions **Codex CLI** — tout en gardant Codex natif ChatGPT pleinement fonctionnel.

![Panneau de la barre de menus](docs/screenshots/panel.png)

## Fonctionnalités

- **Statuts en direct** : pastille de connexion + présence de clé pour chaque provider
- **Un clic = switch complet** : cliquer un fournisseur écrit la config (`model` + `model_provider`), injecte les clés et **relance ChatGPT/Codex** avec la bonne configuration
- **Sélecteur « Modèle actif »** dans la barre (les modèles du provider actif)
- **Gestion des clés intégrée** : saisie, collage, modification (« Voir la clé »), effacement — **persistées par défaut** (fichier 0600, hors iCloud) et rechargées au démarrage
- **Proxies locaux d'adaptation** : traduction de la liste `/models` et de l'API Responses pour chaque provider tiers (streaming, outils)
- **« Toujours une réponse »** : quand le modèle tente un outil non exécutable (Desktop), le proxy complète l'appel automatiquement et force une réponse texte
- **Claude Code via sa session** : jeton OAuth Anthropic du Trousseau (pas de clé API à saisir)
- **Codex CLI** : lancement dans Terminal avec la clé injectée (jamais dans les arguments)

![Icône dans la barre de menus](docs/screenshots/menubar.png)

## Principe de fonctionnement

1. **Barre de menus ⚡** : statuts, clés, modèle actif, actions.
2. **Un clic sur un fournisseur** : `model` + `model_provider` écrits dans `~/.codex/config.toml` (override réversible), clés injectées dans l'environnement, **ChatGPT/Codex relancé**.
3. **Carte OpenAI** : retour au natif (override supprimé).
4. **Choix des modèles** : dans la barre (« Modèle actif ») ou dans le sélecteur de Codex pour le provider actif.
5. **Watcher de config** : si le modèle change dans Codex Desktop, `model_provider` est resynchronisé automatiquement.

```
   ┌─────────────┐   clic DeepSeek   ┌──────────────────────────────┐
   │  Barre ⚡    │ ─────────────────►│ config.toml: model_provider  │
   │  statuts    │   + relance       │        = "deepseek"          │
   │  clés       │                   └──────────────┬───────────────┘
   └─────────────┘                                  ▼
                                       ┌──────────────────────────────┐
                                       │  ChatGPT/Codex relancé avec   │
                                       │  clés injectées (env)         │
                                       └──────────────┬───────────────┘
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │  Proxy local 127.0.0.1:18888  │
                                       │  /models traduit + API relay  │
                                       └──────────────┬───────────────┘
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │  api.deepseek.com (responses) │
                                       └──────────────────────────────┘
```

## Providers et proxies locaux

Codex Desktop exige : (1) la liste de modèles dans **son** schéma (`{"models": [...]}` — les endpoints OpenAI-compatibles renvoient `{"data": [...]}` et sont rejetés) et (2) l'**API Responses** (`/v1/responses`). Chaque provider tiers passe donc par un petit **proxy d'adaptation local** (`Resources/provider-proxy.py`, démarré automatiquement par l'app) :

| Provider | Port | Adaptateur | Rôle |
|---|---|---|---|
| DeepSeek | 18888 | relay | traduit `/models`, relaie l'API |
| GLM (Z.ai) | 18889 | relay | idem |
| OpenRouter | 18890 | relay | idem |
| Claude Code | 18891 | anthropic | traduit Responses ↔ Messages (streaming + outils) |
| Ollama | — | natif | local, sans clé |

### Comportements du proxy (côté Desktop, `tools=0`)

- **Note « pas d'outils »** injectée dans le prompt : le modèle répond en texte au lieu de décrire des appels impossibles.
- **Complétion automatique des appels d'outils** : si le modèle émet un `function_call`, le proxy y répond par « outil indisponible » et relance le modèle (max 2 tours) jusqu'à une réponse texte. L'objectif : **toujours une réponse au problème**.
- **Streaming** : les réponses stream sont bufferisées, complétées si besoin, puis ré-émises en SSE valide. Les sessions CLI (`tools>0`) passent en streaming live sans aucune modification.
- **Log par requête** : modèle, nombre d'outils, stream (utile pour diagnostiquer).

## Claude Code

Aucune clé API à saisir — l'adaptateur utilise **l'environnement de Claude Code** dans cet ordre :

1. **Trousseau macOS** (`Claude Code-credentials` → `claudeAiOauth.accessToken`, jeton OAuth `sk-ant-oat01-…`) → `api.anthropic.com` avec `anthropic-beta: oauth-2025-04-20` (comme le CLI), **refresh automatique** du jeton ;
2. sinon `~/.claude/settings.json` (`ANTHROPIC_AUTH_TOKEN` + `ANTHROPIC_BASE_URL`) ;
3. sinon une clé API passée dans la requête.

Modèles : `claude-sonnet-4-6` (défaut de la famille), `claude-opus-4-6`, `claude-opus-4-7`, `claude-opus-4-8`, `claude-sonnet-5`, `claude-opus-5`, `claude-haiku-4-5` (seul non rate-limité sur certains comptes).

## Clés API

- Saisie/mise à jour dans le panneau (champ + « Coller », « Voir la clé » pour modifier, « Effacer »).
- **Persistées par défaut** dans `~/Library/Application Support/AI Provider Switcher/providers.json` (0600, hors iCloud) et **rechargées au démarrage**.
- Toggle « Clé locale (0600) » pour désactiver la persistance.
- Injectées **uniquement** dans l'environnement des processus relancés — jamais dans `config.toml`, jamais dans les arguments de processus, jamais dans les logs.

## Installation

```bash
./scripts/build-app.sh --open
```

L'app est ad-hoc signée (Hardened Runtime), non sandboxée (elle doit lancer Codex). Depuis Xcode : schéma `AIProviderSwitcher` (les messages `linkd.autoShortcut` dans la console sont du bruit macOS sans conséquence).

## Architecture

```
Sources/
├── AIProviderSwitcher/            # App (barre de menus, panneau, état)
│   ├── AIProviderSwitcherApp.swift
│   ├── AppState.swift             # bootstrap, select, clés, proxies, watcher config
│   ├── PanelView.swift            # panneau minimal : statuts + clés + modèle + actions
│   └── Brand.swift                # identité visuelle par provider
└── AIProviderSwitcherCore/        # Bibliothèque (41 tests)
    ├── Providers.swift            # catalogue (OpenAI, DeepSeek, GLM, OpenRouter, Ollama, Claude)
    ├── CodexConfigGenerator.swift # blocs TOML, ports proxies, catalogue JSON
    ├── CodexConfigStore.swift     # install/uninstall/override réversible + catalogue
    ├── CompatibilityChecker.swift # test de connexion (via proxy)
    ├── KeyStore.swift             # clés en mémoire + persistance 0600
    └── ProviderRouter.swift       # état actif (provider/modèle)
Resources/
└── provider-proxy.py              # proxy d'adaptation (relay / anthropic)
```

### Fichiers générés dans `~/.codex/`

- `config.toml` : blocs `[model_providers.<id>]` (additifs, balisés `provider-switcher`) + override `model`/`model_provider` (réversible) + `model_catalog_json`.
- `<id>.config.toml` : profils pour `codex --profile <id>`.
- `catalog.json` : catalogue des modèles du provider actif (supprimé en natif OpenAI).
- `provider-switcher-state.json` : état de l'override (restauré au démarrage).

## Tests

```bash
swift test        # 41 tests
./scripts/build-app.sh   # build du bundle
```

## Limites connues

- **Codex Desktop n'attache aucun outil aux providers tiers** (`tools=0` dans les requêtes — vérifié) : les skills/instructions arrivent au modèle mais l'exécution d'outils n'est possible qu'en **Codex CLI**. Le proxy compense en garantissant une réponse texte.
- Le sélecteur de modèles du Desktop n'affiche qu'un provider à la fois (comportement de l'app OpenAI) et sa liste dépend du backend du compte (quota « Codex et Work » : la liste ChatGPT peut rester vide tant que le quota est épuisé).
- L'app ChatGPT affiche ses propres messages système dans la conversation (non masquables depuis l'extérieur).
- DeepSeek renvoie parfois des 503 transitoires sous charge ; les modèles Claude sonnet/opus peuvent être en rate-limit horaire selon le plan.
- Les proxies tournent tant que l'app de la barre de menus est active.
