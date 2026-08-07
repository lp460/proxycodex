# AI Provider Switcher

Barre de menus macOS qui injecte les providers tiers (DeepSeek, GLM, OpenRouter, Ollama, Claude Code) dans **Codex Desktop** (app ChatGPT) et les sessions **Codex CLI**, tout en gardant Codex natif ChatGPT pleinement fonctionnel.

## Principe

- **Barre de menus ⚡** : statuts des providers + gestion des clés (saisie, modification, effacement) + lancement des sessions.
- **Un clic sur un provider** : écrit la config (`model` + `model_provider` dans `~/.codex/config.toml`), injecte les clés et **relance ChatGPT/Codex** avec la bonne configuration.
- **Carte OpenAI** : retour au natif (override supprimé, Codex/ChatGPT comme avant).
- **Choix des modèles dans Codex** : le sélecteur affiche les modèles du provider actif (catalogue statique + réponse `/models` traduite par un proxy local).

## Pourquoi des proxies locaux ?

Codex Desktop exige :
1. une liste de modèles dans son **propre schéma** (`{"models": [...]}`) — les endpoints OpenAI-compatibles renvoient `{"data": [...]}` et sont rejetés ;
2. l'API **Responses** (`/v1/responses`).

Chaque provider tiers passe par un petit **proxy d'adaptation local** (`Resources/provider-proxy.py`) qui traduit et relaie :

| Provider | Port | Adaptateur |
|---|---|---|
| DeepSeek | 18888 | relay |
| GLM (Z.ai) | 18889 | relay |
| OpenRouter | 18890 | relay |
| Claude Code | 18891 | anthropic (Responses ↔ Messages, streaming + outils) |
| Ollama | — | natif (local, sans clé) |

Les proxies sont démarrés automatiquement par l'app à son lancement (script copié dans `~/Library/Application Support/AI Provider Switcher/`).

## Claude Code

Aucune clé API à saisir : l'adaptateur lit **l'environnement de Claude Code** (`~/.claude/settings.json`) — `ANTHROPIC_AUTH_TOKEN` (jeton OAuth) et `ANTHROPIC_BASE_URL` — et l'utilise pour authentifier les requêtes vers `/v1/messages`. Modèles disponibles : `claude-sonnet-4-6` (défaut), `claude-opus-4-6`, `claude-opus-4-7`, `claude-opus-4-8`, `claude-sonnet-5`, `claude-opus-5`, `claude-haiku-4-5`.

## Clés API

- Saisie/mise à jour intégrée au panneau (champ + bouton « Coller », « Voir la clé » pour modifier).
- **Persistées par défaut** dans `~/Library/Application Support/AI Provider Switcher/providers.json` (0600, hors iCloud) et **rechargées au démarrage** — aucune resaisie nécessaire.
- Le toggle « Clé locale (0600) » du panneau désactive la persistance.
- Les clés sont injectées **uniquement** dans l'environnement des processus relancés (jamais dans `config.toml`, jamais dans les arguments de processus, jamais dans les logs).

## Installation

```bash
./scripts/build-app.sh --open
```

L'app est ad-hoc signée (Hardened Runtime), non sandboxée (elle doit lancer Codex). Depuis Xcode, lancez le schéma `AIProviderSwitcher` (les messages `linkd.autoShortcut` dans la console sont du bruit macOS sans conséquence).

## Architecture

```
Sources/
├── AIProviderSwitcher/          # App (barre de menus, panneau, état)
│   ├── AIProviderSwitcherApp.swift
│   ├── AppState.swift           # bootstrap, select, clés, proxies, watcher config
│   ├── PanelView.swift          # panneau minimal : statuts + clés + actions
│   └── Brand.swift              # identité visuelle par provider
└── AIProviderSwitcherCore/      # Bibliothèque (tests)
    ├── Providers.swift          # catalogue (OpenAI, DeepSeek, GLM, OpenRouter, Ollama, Claude)
    ├── CodexConfigGenerator.swift  # blocs TOML, ports proxies, catalogue JSON
    ├── CodexConfigStore.swift   # install/uninstall/override réversible + catalogue
    ├── CompatibilityChecker.swift # test de connexion (via proxy)
    ├── KeyStore.swift           # clés en mémoire + persistance 0600
    └── ProviderRouter.swift     # état actif (provider/modèle)
```

### Fichiers générés dans `~/.codex/`

- `config.toml` : blocs `[model_providers.<id>]` (additifs, balisés `provider-switcher`) + override `model`/`model_provider` (réversible) + `model_catalog_json`.
- `<id>.config.toml` : profils pour `codex --profile <id>`.
- `catalog.json` : catalogue des modèles du provider actif (supprimé en natif OpenAI).
- `provider-switcher-state.json` : état de l'override (restauré au démarrage).

### Watcher de configuration

L'app surveille `~/.codex/config.toml` : si le modèle change dans le sélecteur de Codex Desktop, `model_provider` est synchronisé automatiquement (Codex exige un `model_provider` explicite pour router un modèle tiers — sans lui, il route vers le backend ChatGPT et échoue avec « model is not supported when using Codex with a ChatGPT account »).

## Tests

```bash
swift test
```

## Limites connues

- Le sélecteur de modèles de Codex Desktop n'affiche qu'un provider à la fois (comportement de l'app OpenAI).
- La liste `/models` d'un provider n'est refetchée par le serveur Codex que si le cache est absent — après un premier échec (parsif de schéma), le cache peut rester vide jusqu'à sa suppression manuelle (`~/.codex/models_cache.json`).
- Les conversations ChatGPT sont liées au compte ; un bandeau « Quota Codex et Work épuisé » (réinitialisation périodique) peut masquer la liste des conversations.
- Z.ai applique son propre quota horaire à l'API Anthropic (visible via le proxy).
