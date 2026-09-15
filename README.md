# AI Provider Switcher

Barre de menus macOS pour piloter les providers compatibles avec **Codex** depuis un panneau unique : DeepSeek, GLM (Z.ai), OpenRouter, Ollama, Claude Code et OpenCode Zen, tout en conservant le provider OpenAI natif.

![Panneau de la barre de menus — fournisseurs, modèles et actions](docs/screenshots/panel.png)

> Capture du panneau en mode démonstration. Les statuts et présences de clés sont fictifs ; aucun secret n’est affiché.

![Icône de la barre de menus avec son état](docs/screenshots/menubar.png)

## Ce que fait l’application

- Affiche l’état de connexion et la présence d’une clé pour chaque provider.
- Affiche une section « Quota & utilisation » : fenêtres réelles, soldes/budgets, resets exposés et mini-résumés par provider.
- Pilote **Codex Multi-Agent V2** depuis la section « Agents Codex » : activation, nombre maximum de threads (l’agent principal inclus), avertissements de concurrence et recommandation issue du quota — sans jamais écraser une configuration écrite à la main.
- Journalise les événements techniques et les lectures de quota dans le journal local existant, sans jamais y écrire une clé.
- Change le provider et le modèle actifs depuis la barre.
- Quand une carte demande une clé absente, ouvre le champ de clé pour ce provider précis ; une fois la clé injectée, applique la sélection et relance Codex sans second clic.
- Distingue une clé refusée d’un provider indisponible : Z.ai répond parfois HTTP 200 avec une erreur d’authentification dans le corps — le test l’interprète comme une clé invalide au lieu d’afficher « Connecté ».
- Met à jour `model` et `model_provider` dans `~/.codex/config.toml` avec un override réversible.
- Relance Codex Desktop/ChatGPT lorsque cela est nécessaire pour recharger la configuration.
- Lance Codex CLI dans Terminal avec `--profile` et la revue automatique des approbations ; la clé reste dans l’adaptateur local.
- Génère un catalogue de modèles compatible avec le schéma Codex, limité au provider actif.
- Si un provider sert plus de modèles que Codex n'expose de slugs (6 aujourd'hui), le panneau affiche des cases à cocher pour choisir lesquels occuper ces emplacements — le choix est conservé entre les sessions.
- Démarre des proxies locaux pour adapter les providers qui n'exposent pas directement l'API Responses.
- Donne le même jeu de fonctionnalités à tous les providers : MCP, shell, `apply_patch`, plugins et skills.
- Interroge chaque provider pour connaître les modèles qu'il sert réellement, au lieu d'une liste figée.
- Préserve les sections utilisateur, notamment MCP, et crée des sauvegardes avant les modifications.
- Surveille `config.toml` dans les deux sens : un modèle choisi dans Codex Desktop resynchronise provider, état et panneau, et un retour au natif y est détecté.
- Vérifie chaque provider (« Tester tous ») et redémarre seul un adaptateur local devenu obsolète — nouvelle version ou nouvel appariement de slugs.

## Providers disponibles

| Provider | Transport utilisé par Codex | Authentification | Adapter local | Vu par Codex comme | MCP · shell · apply_patch | Images | Web search |
|---|---|---|---:|:---:|:---:|:---:|:---:|
| OpenAI | Natif Codex | Session Codex | Non | lui-même | natif | oui | native |
| DeepSeek | Responses via proxy | Clé dans l'adaptateur (importable d'OpenCode) | `127.0.0.1:18888` | slug natif | ponté | non | non |
| GLM (Z.ai) | Responses via proxy | Clé dans l'adaptateur (importable d'OpenCode) | `127.0.0.1:18889` | slug natif | ponté | non | non |
| OpenRouter | Responses via proxy | Clé dans l'adaptateur (importable d'OpenCode) | `127.0.0.1:18890` | slug natif | ponté | oui | non |
| Claude Code | Responses ↔ Anthropic Messages | Trousseau Claude Code, `ANTHROPIC_*` (settings.json ou config Codex), clé API optionnelle | `127.0.0.1:18891` | slug natif | ponté | oui | serveur Anthropic |
| OpenCode Zen | Responses via proxy | Clé Zen optionnelle (saisie ou `opencode auth login`) | `127.0.0.1:18892` | slug natif | ponté | non | non |
| OpenCode Go | Responses via proxy | Clé Go requise (abonnement, saisie ou credential `opencode-go` d'OpenCode) | `127.0.0.1:18893` | slug natif | ponté | oui | non |
| Ollama | Provider local Codex | Aucune | Non | son vrai slug | function tools | non | non |

### Quota & utilisation

La section reste une couche d’observation : un quota indisponible ne change jamais la compatibilité du provider ni le routage Codex. Les valeurs absentes restent absentes — aucune donnée manquante n’est convertie en zéro.

| Provider | Donnée disponible |
|---|---|
| OpenAI/Codex | Fenêtres quota + reset + crédits si exposés, via `codex app-server --stdio` |
| DeepSeek | Solde API exposé par `GET /user/balance` |
| OpenRouter | Budget de la clé courante + consommation, via `GET /api/v1/key` |
| GLM/Z.ai | Quota Coding Plan exposé par l’endpoint monitor Z.ai |
| Claude Code | Non exposé par une API supportée |
| OpenCode Zen | Non exposé si aucune API publique |
| Ollama | Local / sans quota fournisseur |

Le provider actif affiche une carte détaillée ; les autres providers apparaissent en mini-cartes. Le refresh utilise un cache mémoire d’environ 90 secondes. Un clic sur **Actualiser** force la lecture du provider actif ; **Actualiser tous les quotas** est disponible dans Maintenance. Les résultats et erreurs détaillées vont dans le journal repliable.

Pour Z.ai, l’endpoint monitor reçoit le token brut sans préfixe `Bearer`, comme le plugin officiel. Si aucune heure de reset n’est exposée, l’interface le dit explicitement : elle n’infère jamais une fenêtre depuis l’heure de lecture.

Pour OpenRouter, `/api/v1/key` décrit le **budget de la clé courante**, pas le solde du compte. La version actuelle n’ajoute pas de Management Key et n’appelle donc pas l’endpoint account-level `/credits`.

« Slug natif » : le provider est exposé sous un slug de Codex, voir [Les providers passent pour des modèles de Codex](#les-providers-passent-pour-des-modèles-de-codex). « Ponté » : l’adaptateur traduit les familles de tools propres à OpenAI et restitue les items d’origine, voir [Parité des fonctionnalités](#parité-des-fonctionnalités-mcp-shell-apply_patch-plugins).

Les providers tiers sont déclarés dans `[model_providers.<id>]` avec :

```toml
[model_providers.deepseek]
name = "DeepSeek"
base_url = "http://127.0.0.1:18888/v1"
requires_openai_auth = false
wire_api = "responses"
```

`requires_openai_auth = false` est important : Codex ne doit pas essayer d’appliquer le flux d’authentification OpenAI à un endpoint tiers. **Aucun `env_key`** : une seule source de vérité pour les clés, l’adaptateur local, alimenté par le panneau. Une clé déclarée dans l’environnement de Codex deviendrait périmée dès qu’on la change dans le panneau, c’est exactement ce que cette architecture supprime. Les clés ne sont jamais écrites dans `config.toml`.

GLM (Z.ai) expose le catalogue Responses sous `https://api.z.ai/api/v1` — la base historique `/api/paas/v4` ne sert que `/chat/completions` et renvoyait 404 sur `/v1/responses`. Les modèles proposés sont ceux du **coding plan** Z.AI (`glm-5.2`, `glm-5.2-highspeed`, `glm-5-turbo`, `glm-5.3`, `glm-4.7`) et la clé attendue est de la forme `ID.secret` (et non `sk-…`), vérifiée à la saisie.

## Codex Multi-Agent V2

![Section « Agents Codex » — Multi-Agent V2 activé, preset Recommandé, quota confortable](docs/screenshots/panel-multi-agent.png)

> Capture de la section en mode démonstration : activation, preset `Recommandé · 8 threads`, décomposition « 1 agent principal + jusqu’à 7 sous-agents », recommandation issue du quota et statut Multi-Agent du modèle actif.

La section **Agents Codex** du panneau pilote la parallélisation de Codex elle-même. C’est une capacité d’orchestration de Codex : elle ne dépend pas du provider actif, et le panneau ne parle donc jamais d’« agents DeepSeek » ou d’« agents GLM ».

```toml
# >>> provider-switcher multi-agent >>>
[features.multi_agent_v2]
enabled = true
max_concurrent_threads_per_session = 8
# <<< provider-switcher multi-agent <<<
```

`max_concurrent_threads_per_session` compte **tous les threads de la session, l’agent principal inclus**. Le nombre de sous-agents vaut donc toujours `threads − 1` :

| Réglage | Composition réelle |
|---|---|
| 4 threads | 1 agent principal + jusqu’à 3 sous-agents |
| 8 threads | 1 agent principal + jusqu’à 7 sous-agents |
| 12 threads | 1 agent principal + jusqu’à 11 sous-agents |
| 16 threads | 1 agent principal + jusqu’à 15 sous-agents |

Le panneau n’affiche jamais « 8 threads = 8 sous-agents ».

### Presets

| Preset | Threads | Intention |
|---|---:|---|
| Économe | 4 | consommation modérée |
| Recommandé | 8 | valeur par défaut lors de la première activation |
| Intensif | 12 | consommation élevée |
| Très intensif | 16 | concurrence très élevée |
| Personnalisé | 1 → 40 | valeur libre ; 1 thread ne permet aucun sous-agent |

`40` threads reste possible en Personnalisé, mais le panneau le signale comme très agressif. Les valeurs hors bornes (`0`, négatives, ou au-delà du plafond accepté) sont refusées par le magasin de configuration, qui ne réécrit alors rien.

### Fonction Codex stable, désactivée par défaut

`multi_agent_v2` est une fonctionnalité avancée de Codex : elle est stable, mais désactivée par défaut. Proxycodex peut donc légitimement proposer de l’activer — il ne la présente pas comme expérimentale.

### Ce que l’activation change (et ne change pas)

Activer Multi-Agent signifie que **Codex peut** utiliser des sous-agents, pas qu’il en lancera 7 à chaque demande : la délégation dépend du prompt, de la tâche, du modèle et du contexte. Le panneau parle donc de « jusqu’à 7 sous-agents », jamais de « 7 agents actifs » — aucun suivi live des sous-agents n’est exposé dans cette version. Proxycodex n’injecte jamais « utilise des sous-agents » dans vos prompts à votre place.

Exemple de prompt :

```text
Utilise plusieurs sous-agents en parallèle pour les tâches indépendantes.
Répartis le travail puis fais une synthèse et une validation finale.
```

### Risque de quota

Une concurrence élevée peut consommer plus rapidement les quotas Codex et provoquer des erreurs de rate limit / HTTP 429. Le panneau gradué suit cette échelle : consommation modérée (4), recommandé (8), consommation élevée (12), concurrence très élevée (16 et plus), puis avertissement explicite à partir de 24 threads (risque élevé d’erreurs 429 et d’épuisement rapide du quota).

La section réutilise la lecture de quota existante (aucun second service) pour recommander une valeur : « quota confortable → 8 à 12 threads confortables », « 40–69 % → 8 threads recommandé », « 20–39 % → 4 à 8 threads conseillés », « moins de 20 % → mode Économe recommandé ». C’est une **recommandation d’affichage uniquement** : aucun auto-throttling, le réglage ne change jamais tout seul. Si le quota n’est pas disponible, le panneau le dit et Multi-Agent reste utilisable.

### Respect de votre `config.toml`

- **Configuration utilisateur** : un `[features.multi_agent_v2]` écrit à la main, sans marqueurs Proxycodex, est détecté comme externe. Le panneau affiche « Configuration externe détectée » avec le nombre de threads, désactive le toggle, propose « Ouvrir config.toml » et n’édite rien : un `16` utilisateur n’est jamais remplacé par `8`. La forme inline `multi_agent_v2 = { enabled = true, max_concurrent_threads_per_session = 8 }` dans `[features]` est reconnue de la même façon.
- **Configuration gérée** : seul le bloc encadré `provider-switcher multi-agent` est réécrit. Les autres clés de `[features]`, les tables imbriquées (`[features.other]`), les valeurs personnalisées et les commentaires sont préservés — comme pour le reste des blocs gérés. Une configuration existante (`[features]` déjà présent) reste un TOML valide une fois le sous-table `[features.multi_agent_v2]` ajouté.
- **Désactivation** : le bloc reste en place avec `enabled = false`. Le réglage est donc réversible, le nombre de threads est conservé, et les autres features ne sont pas touchées.
- **Prise en compte** : Codex lit `config.toml` au démarrage d’une session. La nouvelle limite s’applique **à la prochaine session Codex** ; le panneau le rappelle et ne relance pas ChatGPT/Codex pour un simple changement de threads.

`multi_agent_version`, présent dans le catalogue des modèles, est une métadonnée de modèle : elle n’a rien à voir avec `features.multi_agent_v2`, qui est un réglage global de session. Les deux ne sont pas confondus.

### Compatibilité Multi-Agent apprise à l’usage

Activer Multi-Agent n’est pas la même chose que savoir si un modèle donné sait réellement s’en servir. Proxycodex répond à cette seconde question par l’observation, jamais par un test :

- **Proxycodex ne benchmarke pas automatiquement tous les modèles.** Aucun scan, aucune boucle de certification, aucun bouton « Tester ». Ouvrir le panneau, rafraîchir les modèles, changer de provider ou changer de modèle ne déclenche **aucune requête** vers un modèle.
- **La compatibilité est apprise passivement, pendant l’utilisation réelle.** Le proxy note uniquement ce que le protocole montre : les outils du namespace `collaboration` exposés par Codex, l’appel de fonction réellement émis par le provider, l’appel restauré pour Codex, la création d’un thread enfant, le retour du résultat. Le texte du modèle n’est jamais une preuve : « j’ai créé un sous-agent » ne valide rien.
- **Un modèle est marqué « Validé » uniquement lorsqu’un vrai sous-agent a été créé par Codex dans une session réelle** : le modèle a émis l’appel, le bridge l’a restauré pour Codex, et Codex a démarré un thread enfant dont la requête est revenue au proxy avec le `parent_thread_id` de la session. Le proxy ne lit jamais le contenu d’un sous-agent : il ne sait pas ce qu’il a répondu, seulement que le cycle a réellement démarré. Si une erreur provider interrompt le cycle juste après la création du sous-agent, la validation n’est pas accordée. Si le modèle ne délègue jamais, le statut reste « Non vérifié » — c’est un résultat parfaitement normal, et il n’est jamais forcé.
- **Les erreurs de quota, d’authentification, de réseau ou de rate limit ne signifient pas qu’un modèle est incompatible** : 401, 402, 403, 429, timeouts, DNS, 5xx, crédit épuisé ou clé absente produisent « Non vérifié · dernier essai non concluant » avec la cause, et une validation déjà acquise est conservée. Un statut « Non compatible » est réservé à une incompatibilité technique reproductible.

Les statuts affichés sont volontairement courts :

| Statut | Signification |
|---|---|
| Non vérifié | Jamais observé, ou dernier essai non concluant (quota, auth, réseau) |
| Utilisation observée | Un vrai appel Multi-Agent est passé par le bridge, le cycle complet n’est pas encore prouvé |
| Validé avec ce modèle | Un sous-agent réellement créé par Codex dans une session, sans erreur provider interrompant le cycle |
| Non compatible | Incompatibilité technique reproductible, jamais déduite d’une erreur temporaire |
| À revalider | Validation acquise avec un bridge plus ancien ; se revalidera toute seule à la prochaine utilisation réelle |

La compatibilité est enregistrée par **provider + modèle** (`glm/glm-5.3` et `opencode-go/grok-4.6` sont deux entrées distinctes), avec la version de Codex et la version du bridge qui ont servi à la validation. Une nouvelle version du bridge rend les anciennes validations « À revalider », sans lancer aucune requête. Le fichier ne contient que ces métadonnées : jamais de prompt, d’arguments d’outil, de résultat de sous-agent, de clé ni de jeton.

### Bridge des namespaces Codex (providers routés)

Codex expose une partie de ses outils sous forme de **namespaces** (par exemple `collaboration`, avec `spawn_agent`, `wait_agent`, `send_message`, `list_agents`, `interrupt_agent`, `followup_task`). Les providers routés ne connaissent pas cette forme : leur API n’accepte que des fonctions classiques. Sans traitement, ces outils disparaissent et Multi-Agent devient inutilisable avec GLM, DeepSeek, OpenRouter, Claude ou OpenCode.

Le proxy applique donc trois étapes, génériques et sans nom codé en dur :

```text
Codex : namespace collaboration + spawn_agent
   ↓  flatten (bridge_tools)
provider : function collaboration__spawn_agent
   ↓  le provider répond function_call collaboration__spawn_agent
   ↓  restore (restore_output_items), via le mapping du bridge — jamais en découpant le nom
Codex : function_call namespace=collaboration + name=spawn_agent
   ↓  Codex exécute, renvoie l’historique
   ↓  bridge_input_items re-aplatit pour le tour suivant
provider : collaboration__spawn_agent, la conversation continue
```

Le mapping du bridge reste la source de vérité : le namespace n’est jamais déduit d’un `split("__")`, ce qui permet à une fonction `search`, à `alpha__search` et à `beta__search` de coexister. Les appels restaurés conservent `id`, `call_id`, `status` et `arguments` d’origine, donc la corrélation `function_call_output` reste intacte. Un namespace au format inattendu est ignoré avec un log technique minimal : la requête et les autres outils continuent de fonctionner.

Chaque cycle observé alimente le journal (`Multi-Agent · glm-5.3 : compatibilité validée.`) et les logs du proxy restent techniques et sans contenu utilisateur :

```text
[proxy GLM] namespace collaboration.spawn_agent -> collaboration__spawn_agent
[proxy GLM] restore collaboration__spawn_agent -> collaboration.spawn_agent
```

Ce chemin est identique pour tout futur namespace Codex : aucun code spécifique à `collaboration` n’est nécessaire.

## Comment un changement de provider fonctionne

1. L’application vérifie la clé ou le mode sans clé. Si la clé manque, elle ouvre le champ pour ce provider précis ; l’injection applique ensuite la sélection et relance Codex.
2. Elle rafraîchit le bloc du provider et son profil `~/.codex/<id>.config.toml`.
3. Elle génère `~/.codex/catalog.json` pour le provider actif uniquement, sous les slugs de Codex.
4. Elle applique un override réversible de `model` (le slug) et `model_provider`. Le modèle réel est conservé dans `provider-switcher-state.json`.
5. Elle teste le endpoint `/v1/responses` via le proxy lorsque nécessaire.
6. Elle relance Codex Desktop/ChatGPT avec les variables d’environnement disponibles.

La carte OpenAI supprime l’override et revient à la configuration native. Les paramètres utilisateur et les serveurs MCP ne sont pas supprimés lors d’un changement de provider.

## Les providers passent pour des modèles de Codex

Codex conditionne une partie de ses fonctionnalités au **modèle** qu’il croit interroger : un slug inconnu peut perdre les outils, MCP, les plugins, les apps ou les skills, quoi que déclare le catalogue. Chaque provider routé par un adapter est donc exposé sous les **slugs de Codex lui-même**, avec la métadonnée que Codex a réellement téléchargée pour ces slugs (`~/.codex/models_cache.json`), instructions système comprises.

```text
Codex                      config.toml               adapter local            provider
gpt-5.6-sol  ──────────►  model = "gpt-5.6-sol"  ──►  swap du modèle  ──►  claude-haiku-4-5
             ◄──────────  model_provider = …     ◄──  slug restauré   ◄──
```

- Le panneau continue d’afficher les vrais modèles (`claude-haiku-4-5`) ; il indique en légende le slug vu par Codex.
- Les slugs proviennent **exclusivement** de `models_cache.json` : rien n’est inventé. Sans ce fichier, le masquage est désactivé et les vrais noms de modèles sont utilisés.
- Le modèle par défaut du provider prend le slug principal (`gpt-5.6-sol`), puis chaque modèle reçoit le suivant. La liste de slugs de Codex étant finie, un provider déclarant plus de modèles que Codex n’a de slugs n’expose que les premiers ; le sélecteur n’affiche que ceux-là.
- Avant écriture, le catalogue est vérifié champ par champ contre les entrées du cache. S’il manque quoi que ce soit, il n’est pas écrit et l’application retombe sur les vrais slugs — un catalogue invalide ne dégrade pas le provider, il fait **rejeter tout `config.toml`** par Codex : providers, serveurs MCP, sandbox, tout.
- Les slugs internes de Codex (`gpt-reserve`, `codex-auto-review`) sont mappés sur le modèle par défaut, pour que les requêtes internes (revue automatique, délégation) aboutissent aussi.
- Le nom affiché nomme le modèle qui répond vraiment, en premier : `claude-haiku-4-5 · Claude Code`. Seul le slug est masqué, pas l’information.
- `~/.codex/<provider>.config.toml` utilise le même slug, donc Codex CLI (`--profile`) bénéficie du même contrat.
- Deux commutateurs natifs ne sont pas hérités : `use_responses_lite` (format de requête interne à OpenAI, non traduit par les adaptateurs) et `tool_mode = "code_mode_only"` (qui remplacerait le jeu d’outils classique — shell, apply_patch, MCP — par un unique outil de code).

Ollama et LM Studio sont des providers intégrés à Codex, sans adapter local : aucun composant ne peut réécrire le nom du modèle, ils gardent donc leurs vrais slugs.

À noter : les requêtes envoyées au provider tiers portent un nom de modèle OpenAI, et le journal local de Codex affichera `gpt-5.6-sol` là où DeepSeek ou Claude a répondu. C’est le prix du contrat natif ; la légende du panneau et la description du catalogue gardent la correspondance visible.

## Découverte des modèles

Les listes déclarées se périment dès qu'un provider sort un modèle. L'application demande donc à chaque provider ce qu'il sert, au lancement et via **Rafraîchir les modèles** dans le panneau.

La requête passe par l'adaptateur local (`GET /_switcher/upstream-models`), seul composant qui connaisse à la fois l'URL upstream et son authentification :

| Provider | Source interrogée |
|---|---|
| DeepSeek, GLM, OpenRouter | `/v1/models` de l'upstream (GLM : catalogue Responses sous `api.z.ai/api/v1/models`) |
| OpenCode Zen | `opencode models opencode` via la CLI détectée — la passerelle ne distingue pas le palier gratuit |
| OpenCode Go | `/v1/models` de la passerelle Go, tel quel (plafonné à 64 entrées) ; l’adaptateur traduit ensuite Responses → Chat Completions pour les modèles qui ne parlent pas Responses nativement |
| Claude Code | `/v1/models` d'Anthropic, avec le jeton de Claude Code |
| Ollama | interrogé directement, sans adaptateur |

Règles appliquées :

- une liste de plus de 30 modèles n'est pas un sélecteur utilisable (OpenRouter en sert plus de 400) : la liste curée est conservée ;
- l'ordre du provider est respecté, le modèle par défaut est remonté en tête puisqu'il prend le slug natif principal ;
- un provider qui ne répond pas — clé absente, authentification cassée — garde sa liste déclarée, sans erreur bloquante ;
- le résultat est conservé dans `~/Library/Application Support/AI Provider Switcher/discovered-models.json`, donc un relancement repart du dernier état connu ;
- si la liste du provider actif change, les adaptateurs redémarrent avec le nouvel appariement et le catalogue est régénéré ; sinon `config.toml` n'est pas touché.

## Parité des fonctionnalités (MCP, shell, apply_patch, plugins)

Codex envoie plusieurs **familles d’outils** dans une même requête :

| Famille | Exemples | Qui l’exécute |
|---|---|---|
| function tools | `shell`, `update_plan`, `view_image`, **tous les tools MCP** | Codex |
| custom tools freeform | `apply_patch`, `exec`, code mode | Codex |
| `local_shell` | commande shell native | Codex |
| tools hébergés | `web_search` | le provider |

Seul OpenAI implémente les familles non-`function` sur le fil. Le proxy ne les jette plus : il les **traduit en function tools** à l’aller et **reconstruit l’item d’origine** au retour (`custom_tool_call`, `local_shell_call`, nom MCP original). Codex exécute donc lui-même shell, édition de fichiers, `apply_patch`, plugins, skills et serveurs MCP avec n’importe quel provider.

| Étage | Aller (Codex → provider) | Retour (provider → Codex) |
|---|---|---|
| `apply_patch` freeform | function tool `apply_patch({input})` | `custom_tool_call` avec le patch brut |
| `local_shell` | function tool `local_shell({command,…})` | `local_shell_call` avec son `action` |
| tool MCP `mcp.node_repl/run` | nom assaini `mcp_node_repl_run` | nom d’origine restauré |
| historique `custom_tool_call(_output)` | `function_call(_output)` | inchangé |
| `web_search` | Anthropic : outil serveur natif · autres : retiré | `web_search_call` |

Comme le provider passe pour un modèle de Codex, le catalogue conserve les capacités natives (`apply_patch_tool_type = "freeform"`, `shell_type = "shell_command"`, instructions plugins/apps/skills, `multi_agent_version`) : c’est le pont qui les rend exécutables. Pour Ollama, sans adapter, la saveur portable est utilisée à la place (`apply_patch_tool_type = "function"`, niveaux de raisonnement limités à `low`/`medium`/`high`).

Le proxy nettoie aussi la requête : les champs liés au compte OpenAI (`service_tier`, `prompt_cache_key`, `safety_identifier`) sont retirés et `reasoning.effort` est ramené à une valeur portable.

Reste une limite côté client, indépendante de l’application :

| Situation | Tools envoyés par Codex | Résultat |
|---|---:|---|
| Codex CLI | Oui | Toutes les familles sont pontées ; Codex exécute tools et MCP |
| Client qui envoie des tools au proxy | Oui | Les appels sont pontés puis restitués au client |
| Codex Desktop, sessions observées avec `tools=0` | Non | Le proxy demande une réponse texte plutôt qu’un faux appel d’outil |
| Provider qui émet un tool call sans tools reçus | Non | Résultat synthétique « outil indisponible » puis réponse texte |

Le flag natif suivant est également ajouté de façon marquée et réversible :

```toml
[tools]
web_search = true
```

Si l’utilisateur possède déjà une valeur `web_search`, elle est conservée (une seconde affectation dans la même table rendrait `config.toml` invalide). Les blocs MCP existants sont conservés tels quels : MCP est configuré dans `[mcp_servers.*]` et exécuté par Codex, donc il fonctionne avec le provider actif quel qu’il soit.

## Proxy local

`Resources/provider-proxy.py` expose un endpoint local compatible avec Codex :

- transforme `GET /v1/models` vers le catalogue attendu par Codex ;
- relaie les requêtes Responses vers les providers OpenAI-compatible ;
- traduit Responses ↔ Anthropic Messages pour Claude Code ;
- ponte toutes les familles de tools Codex vers des function tools, puis restitue les items d’origine ;
- réécrit l’historique des appels d’outils, sans quoi la conversation casse dès le premier tour ponté ;
- assainit les noms de tools (les tools MCP peuvent contenir `.` ou `/`, refusés par plusieurs endpoints) ;
- retire les champs propres au compte OpenAI et borne `reasoning.effort` ;
- transmet les function calls lorsque le client a réellement envoyé des tools ;
- bufferise les sessions Desktop `tools=0` et les réponses à restituer, afin de terminer proprement ;
- conserve un log technique par requête : provider, modèle, nombre de tools, streaming et pontages ;
- injecte une note système quand la session n’envoie aucun outil, pour obtenir une réponse texte au lieu d’appels impossibles à exécuter ;
- complète automatiquement les appels d’outils orphelins — jusqu’à deux rounds où chaque appel en attente reçoit « outil non disponible » — afin de garantir une réponse texte ;
- rafraîchit au mieux un jeton OAuth Claude Code expiré avant de renvoyer l’erreur.

MCP est configuré et exécuté par Codex : le proxy voit les tools MCP comme des function tools ordinaires et les transmet. Il faut donc toujours vérifier que le provider gère correctement les schémas d’arguments de vos serveurs MCP.

## Cycle de vie des adaptateurs locaux

Au lancement, `provider-proxy.py` est recopié dans `~/Library/Application Support/AI Provider Switcher/` puis exécuté depuis cet emplacement : l’app installée ne dépend plus du dépôt et une mise à jour du script se propage au prochain démarrage.

Chaque adaptateur laisse une fiche `proxy-<port>.json` (version, provider, capacités, appariement slug ↔ modèle, pid), relue au démarrage suivant :

- port ouvert et fiche conforme à l’état attendu : l’adaptateur en place est conservé ;
- version du script, provider ou appariement des slugs changés — par exemple parce que Codex a rafraîchi `models_cache.json` : l’adaptateur géré est arrêté puis relancé avec le nouvel appariement ;
- fiche perdue (App Support nettoyé) alors que le proxy tourne encore : il est identifié par sa ligne de commande complète — script **et** port — jamais par le port seul, avant redémarrage ;
- port occupé par un processus externe : il est conservé, l’application signale qu’un redémarrage manuel est nécessaire.

## Claude Code

Claude Code n’exige pas de clé saisie dans le panneau. Le proxy cherche, dans cet ordre :

1. une clé API Anthropic saisie dans le panneau, si l’utilisateur en a enregistré une ;
2. le jeton OAuth Claude Code dans le Trousseau macOS (`Claude Code-credentials`), rafraîchi s’il a expiré ;
3. `ANTHROPIC_AUTH_TOKEN` et `ANTHROPIC_BASE_URL` dans `~/.claude/settings.json` ;
4. les mêmes variables dans `~/.codex/config.toml` (`[shell_environment_policy.set]`), c’est-à-dire l’environnement que Codex lui-même fournit à Claude Code — le cas d’un backend compatible comme Z.ai.

Le couple jeton/base reste cohérent : un jeton Z.ai n’est jamais envoyé à `api.anthropic.com`. Sans aucune source, le proxy répond une erreur explicite au lieu d’émettre un `x-api-key` vide. Les blocs `thinking` renvoyés par un backend à raisonnement étendu sont restitués comme items `reasoning`, jamais perdus.

Le proxy convertit les messages et les tools entre le format Responses de Codex et le format Messages d’Anthropic. Trois points spécifiques à cet adaptateur :

- les images (`input_image`, captures, résultats de `view_image`) sont transmises comme vrais blocs image, data URL comprises, au lieu d’un marqueur texte ;
- `web_search` est mappé sur la recherche web côté serveur d’Anthropic, et la réponse est restituée en `web_search_call` ; si le compte ou le modèle la refuse (400), le tour est rejoué sans cet outil au lieu d’échouer ;
- `max_tokens` vaut 16384 par défaut, une valeur acceptée par les modèles Claude actuels et suffisante pour un patch complet.

## OpenCode

La CLI OpenCode est un agent, pas un backend HTTP : elle n'expose que son propre protocole de sessions (`opencode serve` → `POST /session/{id}/prompt`), inutilisable comme model provider. Ce qui est intégré ici est donc la passerelle que la CLI interroge elle-même : **OpenCode Zen** et, séparément, l'abonnement **OpenCode Go**. Les deux bases sont compatibles OpenAI ; chacune sert `/v1/responses` pour une partie de son catalogue et `/v1/chat/completions` pour le reste, et c'est l'adaptateur qui présente à Codex le contrat Responses qu'il attend.

### OpenCode Go

`opencode-go` utilise `https://opencode.ai/zen/go/v1` (adaptateur `127.0.0.1:18893`) et demande une clé Go distincte d'une éventuelle clé Zen. Le proxy lit la clé saisie dans le panneau, puis l'entrée `opencode-go` de `~/.local/share/opencode/auth.json` créée par `/connect` → `OpenCode Go`. Contrairement à Zen, il n'y a pas de repli sur une clé publique.

Go route ses modèles vers Responses, Chat Completions ou Anthropic Messages selon le modèle. Codex, lui, parle toujours Responses à l’adaptateur : c’est l’adaptateur qui s’aligne sur le contrat réel du modèle. `grok-4.6`, `gpt-5.6-luna`, `muse-spark-1.3-contributor` et `muse-spark-1.2-contributor` répondent Responses directement ; tous les autres modèles du catalogue Go sont traduits vers `/v1/chat/completions` avant l’envoi. La découverte annonce donc l’ensemble du catalogue de la passerelle (source `gateway`) plutôt que de masquer un modèle dont le contrat diffère : la différence est absorbée par l’adaptateur, pas par l’utilisateur.

Cette liste ne dit rien de la compatibilité Multi-Agent : elle est apprise passivement, modèle par modèle, pendant de vrais workflows (voir « Compatibilité Multi-Agent apprise à l’usage »). Rien ne garantit que les quelque soixante modèles Go se comportent tous de la même façon, et chacun garde son propre statut.

Les résultats d’outils suivent le même alignement. Responses accepte un `function_call_output` sous forme de liste de parties `input_text`, ce que Codex utilise pour les outils qui renvoient du contenu riche (computer-use, vision). Chat Completions ne connaît que `text`, `image_url` et `file`, et la passerelle rejette la requête entière sur une partie inconnue : `messages[186]: unknown variant input_text, expected one of text, image_url, file`. Ces sorties sont donc converties en texte pour les modèles traduits vers Chat, et un résultat dont aucun type de partie n’est reconnu est transmis en JSON plutôt que perdu.

Le proxy ajoute les en-têtes `x-opencode-session`, `x-opencode-request`, `x-opencode-client` et `User-Agent` attendus pour le routage et l'affinité de cache. L'identifiant de session est dérivé de façon stable à partir de l'ID explicite de la requête ou du premier message utilisateur ; aucune clé n'est écrite dans ces en-têtes ni dans les journaux.

Pour Zen, aucune clé n'est requise à la base. Le proxy cherche, dans cet ordre :

1. une clé Zen saisie dans le panneau (clé privée de l'adaptateur) ;
2. une clé transmise par la requête (clé Zen payante relayée par Codex) ;
3. l'entrée `opencode` de `~/.local/share/opencode/auth.json`, écrite par `opencode auth login` ;
4. la clé publique documentée du palier gratuit.

Si la passerelle refuse la requête (le palier gratuit via l'API directe est désormais restreint, la CLI garde ses sessions), le message d'erreur le dit et indique la marche à suivre : `opencode auth login`, ou une clé Zen saisie dans le panneau.

La CLI est **détectée, pas requise** : la passerelle répond sans elle. Le panneau affiche l'état sous la grille des fournisseurs — version trouvée et origine de la clé, ou l'absence de la CLI. Les emplacements inspectés sont ceux de l'installeur OpenCode (`~/.opencode/bin`, Homebrew, `/usr/local/bin`, `~/.local/bin`). Seuls les **noms** des credentials sont lus, jamais les valeurs.

Les modèles Zen déclarés sont ceux du palier gratuit, tels que listés par `opencode models opencode` :

```bash
opencode models opencode
```

## Écritures de config.toml

Codex recharge toute sa configuration — et relance sa connexion — à chaque modification de `config.toml`. Trois règles en découlent :

- une sélection complète (blocs providers, catalogue, `[tools]`, override) ne fait **qu'une seule** écriture ;
- une écriture au contenu identique n'a pas lieu, et ne crée donc pas de sauvegarde ;
- quand Codex a lui-même écrit la sélection voulue — l'utilisateur change de modèle dans le Desktop — seul l'état sidecar est mis à jour, `config.toml` n'est pas retouché.

La disposition des blocs gérés est déterministe (providers, puis `[features.multi_agent_v2]`, puis `[tools]`, catalogue en tête). Sans cela, chaque installation permutait leur ordre : le fichier différait à chaque fois, Codex rechargeait, et les lignes vides laissées par les retraits s'accumulaient — un `config.toml` observé avait 483 lignes vides consécutives sur 886 lignes.

Tous ces blocs sont édités **en texte**, jamais via un encodeur TOML : commentaires, ordre et sections utilisateur restent intacts. Le bloc Multi-Agent suit la même règle et n’est réécrit que lorsqu’il appartient à Proxycodex (marqueurs `provider-switcher multi-agent`).

## Surveillance de config.toml

L’application observe le fichier (événements filesystem, traitement différé d’1,5 s pour laisser finir une écriture) et resynchronise son état quand **Codex** y écrit lui-même :

- Le sélecteur du Desktop n’écrit que `model`, jamais `model_provider`. Comme les providers routés sont exposés sous les slugs natifs de Codex, cette valeur seule ne suffit plus à identifier le provider : `model_provider` reste la source de vérité, et le slug y est résolu vers le vrai modèle (`provider-switcher-state.json` et panneau mis à jour).
- Si le fichier porte déjà exactement la sélection voulue, seul l’état sidecar est mis à jour : `config.toml` n’est pas réécrit, donc Codex ne recharge pas sa configuration et ne perd pas sa connexion.
- Si `model_provider` disparaît ou redevient `openai` alors qu’un override était actif, le fichier est honoré : override révoqué, retour au natif dans le panneau.
- Un slug que le provider actif ne connaît pas est résolu vers son modèle par défaut plutôt que de faire échouer la requête.

Pendant une sélection faite depuis le panneau, la surveillance est suspendue puis relancée : le watcher ne doit jamais réagir aux écritures de l’application elle-même.

## Clés et sécurité

- Les clés sont gardées en mémoire pendant la session.
- La persistance locale est activée par défaut dans `~/Library/Application Support/AI Provider Switcher/providers.json`.
- Le fichier est limité à `0600`, son dossier à `0700`, et exclu des sauvegardes iCloud/Time Machine.
- Les clés ne sont pas écrites dans `config.toml`, les profils, le catalogue, les arguments de processus ni les fichiers temporaires.
- Les clés déjà accordées à OpenCode (`~/.local/share/opencode/auth.json`) sont importées dans le trousseau local de l’app au premier lancement, pour les providers qui n’en ont pas encore : l’utilisateur ne ressaisit pas une clé qu’il a déjà donnée.
- ChatGPT/Codex n’est plus relancé avec des secrets dans son environnement : chaque provider routé reçoit sa clé de son adaptateur local, qui la garde et l’applique.
- Chaque modification de `config.toml` crée une sauvegarde dans `~/.codex/backup-provider-switcher/`.

## Installation

```bash
./scripts/build-app.sh --install --open
```

L’icône est générée par code, donc modifiable sans éditer de binaire :

```bash
swift scripts/make-app-icon.swift
```

Le script écrit `Resources/AppIcon.icns` (les dix représentations, chacune dessinée à sa taille native) que `build-app.sh` embarque dans le bundle. Le mark reprend le glyphe de la barre de menus (`bolt.horizontal.circle.fill`) sur une tuile turquoise → bleu, les deux couleurs d’accent du panneau.

`--install` copie le bundle dans `/Applications` (l’instance en cours est quittée avant remplacement) ; sans ce drapeau, l’app reste dans `build/`. L’application est construite en release, signée ad hoc avec Hardened Runtime et non sandboxée afin de pouvoir lancer Codex et Terminal. L’adaptateur `provider-proxy.py` est embarqué dans `Contents/Resources`, donc l’app installée ne dépend plus du dépôt.

Pour générer une capture reproductible du panneau :

```bash
./scripts/build-app.sh --no-sign
open "build/AIProviderSwitcher.app" --args --panel-screenshot
```

> Important : lancez toujours `build/AIProviderSwitcher.app` avec `open`, et non
> `.build/release/AIProviderSwitcher` ou `Contents/MacOS/AIProviderSwitcher` directement.
> `MenuBarExtra` a besoin du bundle `.app` et de son `CFBundleIdentifier` pour être
> enregistré correctement par macOS. L’icône apparaît ensuite dans la barre des menus.

Le mode `--panel-screenshot` utilise des données fictives, désactive les actions mutantes et ne touche ni `~/.codex` ni les clés locales.

## Fichiers générés

```text
~/.codex/config.toml                         configuration additive, override actif et réglage Multi-Agent V2 géré
~/.codex/<provider>.config.toml              profil CLI sans secret
~/.codex/catalog.json                        catalogue du provider actif
~/.codex/provider-switcher-state.json       état réversible de l’override
~/.codex/backup-provider-switcher/           sauvegardes avant modification
~/Library/Application Support/AI Provider Switcher/providers.json
                                             clés locales optionnelles, mode 0600
~/Library/Application Support/AI Provider Switcher/discovered-models.json
                                             dernières listes de modèles annoncées par les providers
~/Library/Application Support/AI Provider Switcher/model-capabilities.json
                                             compatibilité Multi-Agent observée, par provider + modèle
~/Library/Application Support/AI Provider Switcher/multi-agent-events.jsonl
                                             observations techniques du proxy, consommées puis vidées
~/Library/Application Support/AI Provider Switcher/provider-proxy.py
                                             copie exécutée de l’adaptateur, rafraîchie à chaque lancement
~/Library/Application Support/AI Provider Switcher/proxy-<port>.json
                                             fiche d’état de chaque adaptateur (version, capacités, pid)
```

Les blocs gérés sont encadrés par `provider-switcher`. La désinstallation retire uniquement les blocs, profils et catalogues gérés par l’application, puis restaure la configuration native et préserve les sections utilisateur. Les emplacements sous `~/.codex` respectent la variable d’environnement `CODEX_HOME`.

## Diagnostic

Vérifier le provider actif (le `model` est le slug vu par Codex, pas le modèle réel) :

```bash
awk '/^(model|model_provider) =/{print}' ~/.codex/config.toml
```

Vérifier la correspondance slug → modèle réel :

```bash
python3 -m json.tool ~/.codex/provider-switcher-state.json
```

Vérifier le catalogue et ses capacités :

```bash
python3 -m json.tool ~/.codex/catalog.json | grep -E 'slug|tool|patch|search|parallel'
```

Vérifier que **Codex** accepte ce catalogue — c'est le contrôle qui compte : refusé, il repart sur ses défauts natifs et ignore providers tiers comme sections utilisateur.

```bash
/Applications/ChatGPT.app/Contents/Resources/codex debug models
```

Vérifier les proxies :

```bash
curl -s http://127.0.0.1:18888/v1/models | python3 -m json.tool
curl -s http://127.0.0.1:18889/v1/models | python3 -m json.tool
curl -s http://127.0.0.1:18890/v1/models | python3 -m json.tool
curl -s http://127.0.0.1:18892/v1/models | python3 -m json.tool
```

Vérifier ce qu’un provider sert réellement — route privée utilisée par « Rafraîchir les modèles », qui renvoie ses vrais identifiants :

```bash
curl -s http://127.0.0.1:18888/_switcher/upstream-models | python3 -m json.tool
```

Si le Desktop affiche le provider mais n’exécute pas les tools, inspecter le log du proxy :

```text
[proxy DeepSeek] POST /v1/responses model=... tools=0 stream=True
```

`tools=0` signifie que la limitation vient du client Codex Desktop ou de la session active, pas du modèle upstream. Avec `tools>0`, les function calls sont conservés par le proxy.

Le pontage des tools est journalisé quand il modifie une définition, ce qui permet de vérifier qu’`apply_patch` et les tools MCP arrivent bien au modèle :

```text
[proxy Claude Code] bridge: apply_patch->apply_patch:custom, mcp.node_repl/run->mcp_node_repl_run:function
```

Le masquage du modèle est journalisé de la même façon :

```text
[proxy Claude Code] modele: gpt-5.6-sol -> claude-haiku-4-5
```

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
    ├── ModelMasquerade.swift             slugs natifs Codex ↔ modèles réels
    ├── ModelSelectionStore.swift         sélection persistée des modèles exposés (≤ 6)
    ├── OpenCodeCLI.swift                 détection de la CLI OpenCode
    ├── ModelDiscovery.swift              modèles réellement servis + persistance
    ├── CodexConfigGenerator.swift        TOML et catalogue avec capacités tools
    ├── CodexConfigStore.swift             installation, override et réversibilité
    ├── CompatibilityChecker.swift         test de `/v1/responses` (détecte aussi les erreurs d'auth dans un corps 2xx)
    ├── KeyStore.swift                     mémoire et persistance 0600
    ├── ProviderRouter.swift               état actif provider/modèle
    └── Support/
        ├── HTTPClient.swift                  client URLSession async
        ├── Logging.swift                     journal unifié, secrets masqués avant toute écriture
        └── Secrets.swift                     clé en mémoire effaçable, jamais une String ordinaire

Resources/provider-proxy.py               relay Responses, adaptateur Anthropic, pont d'outils
docs/screenshots/                         captures utilisées dans ce README
```

## Tests et build

```bash
swift test
swift build -c release
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile Resources/provider-proxy.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest Tests/ProxyBehaviorTests.py
./scripts/build-app.sh --no-sign
plutil -p build/AIProviderSwitcher.app/Contents/Info.plist | grep CFBundleIdentifier
open build/AIProviderSwitcher.app
```

Si l’icône n’apparaît pas, quittez une ancienne instance puis relancez le bundle :

```bash
pkill -x AIProviderSwitcher 2>/dev/null || true
open build/AIProviderSwitcher.app
```

Les messages `com.apple.linkd.autoShortcut` peuvent être générés par macOS et ne
sont généralement pas la cause du problème. Le message `missing main bundle identifier`
indique en revanche que le binaire a été lancé hors de son bundle `.app`.

## Limites connues

- Codex Desktop peut afficher un provider tiers sans lui envoyer de tools ; les métadonnées du catalogue ne suffisent pas à modifier ce comportement du client. Avec `tools=0`, aucun pontage n’est possible.
- Le pontage garantit le transport des outils, pas la qualité du modèle : un provider qui suit mal un schéma d’arguments produira des appels `apply_patch` ou MCP invalides.
- Lorsqu’une réponse doit être reconstruite (`apply_patch`, `local_shell`, nom MCP assaini), le streaming est bufferisé : la réponse arrive d’un bloc au lieu d’être affichée token par token.
- Les tools hébergés côté OpenAI autres que `web_search` (`file_search`, `image_generation`, `code_interpreter`) sont retirés : aucun provider tiers ne peut les exécuter.
- Un slug natif ne peut être attribué qu’une fois : un provider offrant plus de modèles que Codex n’a de slugs n’expose que les premiers dans le sélecteur.
- La liste de slugs de Codex change avec ses versions — `gpt-reserve` en a disparu en cours de route. Le masquage suit le cache, donc le nombre de modèles exposés peut varier après une mise à jour de Codex.
- Le journal et la télémétrie locale de Codex attribuent la requête au slug natif, pas au provider réel.
- Le palier gratuit d'OpenCode Zen est désormais restreint : l'API directe répond `MissingSessionID`, `AuthError` ou `Internal server error` sans clé. Le panneau le signale et propose d'exécuter `opencode auth login` ou de saisir une clé Zen. La CLI, elle, continue d'utiliser sa propre session.
- Les noms des modèles gratuits d'OpenCode Zen sont des préversions et changent régulièrement ; ils sont déclarés en dur et se vérifient avec `opencode models opencode`.
- Les modèles Go changent régulièrement. Seule leur famille Responses est exposée ; l'ajout d'une passerelle Chat/Messages distincte serait nécessaire pour exposer les autres sans conflit de schéma.
- Ollama est un provider intégré à Codex, sans adapter local : il reçoit les function tools du catalogue, mais pas le nettoyage de requête du proxy (un `service_tier` global dans `config.toml` lui est transmis tel quel).
- Les providers OpenAI-compatible n’implémentent pas tous Responses, le streaming, les images ou les tools de façon identique.
- Les proxies tournent tant que l’application de la barre de menus est active.
- Un adaptateur dont le port est occupé par un processus externe n’est pas remplacé : l’application le signale et demande un redémarrage manuel.
- La complétion automatique des tools orphelins effectue au plus deux rounds ; au-delà, la réponse du modèle est renvoyée telle quelle.
- Les modèles, quotas et noms de modèles peuvent évoluer côté provider.

## Références

- [Codex configuration](https://github.com/openai/codex/blob/main/docs/config.md)
- [Codex model catalog](https://github.com/openai/codex/blob/main/codex-rs/models-manager/models.json)
- [Codex model metadata implementation](https://github.com/openai/codex/blob/main/codex-rs/models-manager/src/model_info.rs)
- [Codex configuration reference discussion](https://github.com/openai/codex/issues/2760)
