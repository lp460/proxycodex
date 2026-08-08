# AI Provider Switcher

Barre de menus macOS pour piloter les providers compatibles avec **Codex** depuis un panneau unique : DeepSeek, GLM (Z.ai), OpenRouter, Ollama et Claude Code, tout en conservant le provider OpenAI natif.

![Panneau de la barre de menus — fournisseurs, modèles et actions](docs/screenshots/panel.png)

> Capture du panneau en mode démonstration. Les statuts et présences de clés sont fictifs ; aucun secret n’est affiché.

![Icône de la barre de menus avec son état](docs/screenshots/menubar.png)

## Ce que fait l’application

- Affiche l’état de connexion et la présence d’une clé pour chaque provider.
- Change le provider et le modèle actifs depuis la barre.
- Met à jour `model` et `model_provider` dans `~/.codex/config.toml` avec un override réversible.
- Relance Codex Desktop/ChatGPT lorsque cela est nécessaire pour recharger la configuration.
- Lance Codex CLI dans Terminal avec `--profile` et une clé injectée uniquement dans l’environnement.
- Génère un catalogue de modèles compatible avec le schéma Codex, limité au provider actif.
- Démarre des proxies locaux pour adapter les providers qui n’exposent pas directement l’API Responses.
- Préserve les sections utilisateur, notamment MCP, et crée des sauvegardes avant les modifications.

## Providers disponibles

| Provider | Transport utilisé par Codex | Authentification | Adapter local |
|---|---|---|---:|
| OpenAI | Natif Codex | Session Codex | Non |
| DeepSeek | Responses via proxy | `DEEPSEEK_API_KEY` | `127.0.0.1:18888` |
| GLM (Z.ai) | Responses via proxy | `ZAI_API_KEY` | `127.0.0.1:18889` |
| OpenRouter | Responses via proxy | `OPENROUTER_API_KEY` | `127.0.0.1:18890` |
| Claude Code | Responses ↔ Anthropic Messages | Session Claude Code / Trousseau | `127.0.0.1:18891` |
| Ollama | Provider local Codex | Aucune | Non |

Les providers tiers sont déclarés dans `[model_providers.<id>]` avec :

```toml
[model_providers.deepseek]
name = "DeepSeek"
base_url = "http://127.0.0.1:18888/v1"
env_key = "DEEPSEEK_API_KEY"
requires_openai_auth = false
wire_api = "responses"
```

`requires_openai_auth = false` est important : Codex ne doit pas essayer d’appliquer le flux d’authentification OpenAI à un endpoint tiers. Les clés ne sont jamais écrites dans `config.toml`.

## Comment un changement de provider fonctionne

1. L’application vérifie la clé ou le mode sans clé.
2. Elle rafraîchit le bloc du provider et son profil `~/.codex/<id>.config.toml`.
3. Elle génère `~/.codex/catalog.json` pour le provider actif uniquement.
4. Elle applique un override réversible de `model` et `model_provider`.
5. Elle teste le endpoint `/v1/responses` via le proxy lorsque nécessaire.
6. Elle relance Codex Desktop/ChatGPT avec les variables d’environnement disponibles.

La carte OpenAI supprime l’override et revient à la configuration native. Les paramètres utilisateur et les serveurs MCP ne sont pas supprimés lors d’un changement de provider.

## Tools : ce qui est réellement pris en charge

Il faut distinguer **la capacité annoncée** et **l’exécution effective** :

| Situation | Tools envoyés par Codex | Résultat |
|---|---:|---|
| Codex CLI | Oui, selon le modèle et la session | Le proxy transmet les function tools ; Codex peut exécuter ses tools et MCP |
| Codex Desktop avec provider tiers, comportement observé | Non (`tools=0`) | Le proxy demande une réponse texte et évite les appels impossibles |
| Client qui envoie des tools au proxy | Oui | Les appels de fonctions sont conservés et retournés au client |
| Model provider qui émet un tool call sans tools reçus | Non | Le proxy ajoute un résultat synthétique « outil indisponible » et demande une réponse texte |

Le catalogue généré déclare les capacités attendues par le contrat Codex :

- `apply_patch_tool_type = "freeform"`
- `web_search_tool_type = "text_and_image"`
- `supports_parallel_tool_calls = true`
- `supports_search_tool = true`
- `tool_mode = "code_mode_only"`
- modalités texte et image

Ces champs aident Codex à considérer le modèle comme compatible avec son contrat d’agent ; ils ne constituent pas une certification des capacités réelles de chaque endpoint upstream. Ils ne peuvent toutefois pas forcer une version de Codex Desktop à ajouter des tools à une requête qui part avec `tools=[]`. Dans ce cas, l’application conserve le comportement sûr : réponse texte plutôt qu’un faux appel d’outil.

Le flag natif suivant est également ajouté de façon marquée et réversible :

```toml
[tools]
web_search = true
```

Si l’utilisateur possède déjà une valeur `web_search`, elle est conservée. Les blocs MCP existants sont conservés. Pour une exécution fiable de shell, édition de fichiers, `apply_patch` et MCP avec un provider tiers, le chemin recommandé reste **Codex CLI**.

## Proxy local

`Resources/provider-proxy.py` expose un endpoint local compatible avec Codex :

- transforme `GET /v1/models` vers le catalogue attendu par Codex ;
- relaie les requêtes Responses vers les providers OpenAI-compatible ;
- traduit Responses ↔ Anthropic Messages pour Claude Code ;
- traduit les tools Responses vers les tools Anthropic ;
- transmet les function calls lorsque le client a réellement envoyé des tools ;
- bufferise uniquement les sessions Desktop `tools=0` afin de terminer proprement une réponse ;
- conserve un log technique par requête : provider, modèle, nombre de tools et streaming.

Le proxy ne reçoit pas automatiquement les tools MCP. MCP est exécuté par Codex, principalement dans les sessions CLI, puis les définitions de tools sont envoyées au model provider lorsque le client les active. Il faut donc vérifier la compatibilité réelle du provider avec les schémas d’arguments et les résultats d’outils.

## Claude Code

Claude Code n’utilise pas une clé saisie dans le panneau. Le proxy cherche, dans cet ordre :

1. le jeton OAuth Claude Code dans le Trousseau macOS (`Claude Code-credentials`) ;
2. `ANTHROPIC_AUTH_TOKEN` et `ANTHROPIC_BASE_URL` dans `~/.claude/settings.json` ;
3. une clé éventuellement fournie par la requête.

Le proxy convertit les messages, les images texte et les function tools entre le format Responses de Codex et le format Messages d’Anthropic.

## Clés et sécurité

- Les clés sont gardées en mémoire pendant la session.
- La persistance locale est activée par défaut dans `~/Library/Application Support/AI Provider Switcher/providers.json`.
- Le fichier est limité à `0600`, son dossier à `0700`, et exclu des sauvegardes iCloud/Time Machine.
- Les clés ne sont pas écrites dans `config.toml`, les profils, le catalogue ou les arguments de processus.
- Au lancement de ChatGPT/Codex, les clés sont injectées dans l’environnement du processus.
- Chaque modification de `config.toml` crée une sauvegarde dans `~/.codex/backup-provider-switcher/`.

## Installation

```bash
./scripts/build-app.sh --open
```

L’application est construite en release, signée ad hoc avec Hardened Runtime et non sandboxée afin de pouvoir lancer Codex et Terminal.

Pour générer une capture reproductible du panneau :

```bash
./scripts/build-app.sh --no-sign
.build/release/AIProviderSwitcher --panel-screenshot
```

Le mode `--panel-screenshot` utilise des données fictives, désactive les actions mutantes et ne touche ni `~/.codex` ni les clés locales.

## Fichiers générés

```text
~/.codex/config.toml                         configuration additive et override actif
~/.codex/<provider>.config.toml              profil CLI sans secret
~/.codex/catalog.json                        catalogue du provider actif
~/.codex/provider-switcher-state.json       état réversible de l’override
~/.codex/backup-provider-switcher/           sauvegardes avant modification
~/Library/Application Support/AI Provider Switcher/providers.json
                                             clés locales optionnelles, mode 0600
```

Les blocs gérés sont encadrés par `provider-switcher`. La désinstallation retire uniquement les blocs, profils et catalogues gérés par l’application, puis restaure la configuration native et préserve les sections utilisateur.

## Diagnostic

Vérifier le provider actif :

```bash
awk '/^(model|model_provider) =/{print}' ~/.codex/config.toml
```

Vérifier le catalogue et ses capacités :

```bash
python3 -m json.tool ~/.codex/catalog.json | grep -E 'slug|tool|patch|search|parallel'
```

Vérifier les proxies :

```bash
curl -s http://127.0.0.1:18888/v1/models | python3 -m json.tool
curl -s http://127.0.0.1:18889/v1/models | python3 -m json.tool
curl -s http://127.0.0.1:18890/v1/models | python3 -m json.tool
```

Si le Desktop affiche le provider mais n’exécute pas les tools, inspecter le log du proxy :

```text
[proxy DeepSeek] POST /v1/responses model=... tools=0 stream=True
```

`tools=0` signifie que la limitation vient du client Codex Desktop ou de la session active, pas du modèle upstream. Avec `tools>0`, les function calls sont conservés par le proxy.

## Architecture

```text
Sources/
├── AIProviderSwitcher/
│   ├── AIProviderSwitcherApp.swift       MenuBarExtra et icône
│   ├── AppState.swift                    bootstrap, sélection, clés, proxies, watcher
│   ├── PanelView.swift                   panneau et interactions
│   └── Brand.swift                       identité visuelle des providers
└── AIProviderSwitcherCore/
    ├── Providers.swift                   catalogue providers/modèles
    ├── CodexConfigGenerator.swift        TOML et catalogue avec capacités tools
    ├── CodexConfigStore.swift             installation, override et réversibilité
    ├── CompatibilityChecker.swift         test de `/v1/responses`
    ├── KeyStore.swift                     mémoire et persistance 0600
    └── ProviderRouter.swift               état actif provider/modèle

Resources/provider-proxy.py               relay Responses et adaptateur Anthropic
docs/screenshots/                         captures utilisées dans ce README
```

## Tests et build

```bash
swift test
swift build -c release
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile Resources/provider-proxy.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest Tests/ProxyBehaviorTests.py
./scripts/build-app.sh --no-sign
```

## Limites connues

- Codex Desktop peut afficher un provider tiers sans lui envoyer de tools ; les métadonnées du catalogue ne suffisent pas à modifier ce comportement du client.
- Les tools et MCP dépendent de la version de Codex, du modèle et de la session ; Codex CLI est le chemin le plus complet pour l’exécution agentique.
- Les providers OpenAI-compatible n’implémentent pas tous Responses, le streaming, les images ou les tools de façon identique.
- Les proxies tournent tant que l’application de la barre de menus est active.
- Les modèles, quotas et noms de modèles peuvent évoluer côté provider.

## Références

- [Codex configuration](https://github.com/openai/codex/blob/main/docs/config.md)
- [Codex model catalog](https://github.com/openai/codex/blob/main/codex-rs/models-manager/models.json)
- [Codex model metadata implementation](https://github.com/openai/codex/blob/main/codex-rs/models-manager/src/model_info.rs)
- [Codex configuration reference discussion](https://github.com/openai/codex/issues/2760)
