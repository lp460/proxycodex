# ProxyCodex — publication sans App Store

ProxyCodex est distribué directement depuis GitHub. Aucun passage par le Mac App Store
n’est prévu.

Le dépôt contient trois automatisations :

- `pages.yml` publie la landing page bilingue depuis `docs/` ;
- `ci.yml` vérifie le site, teste l’application et assemble le bundle ;
- `release.yml` crée automatiquement le DMG et le flux de mise à jour Sparkle
  lorsqu’un push sur `main` modifie le code de l’application.

## 1. Activer GitHub Pages une seule fois

Dans **Settings → Pages → Build and deployment**, choisir **GitHub Actions**.

Le site sera disponible sur `https://lp460.github.io/proxycodex/`.

## 2. Ajouter les deux secrets Sparkle obligatoires

Sparkle permet à une copie déjà installée de vérifier qu’une mise à jour vient bien
de ce dépôt. Cette signature est indépendante du Mac App Store et ne nécessite pas
de compte Apple Developer.

Télécharger une distribution Sparkle sur un Mac, puis exécuter son outil
`bin/generate_keys`. La clé est créée une seule fois. Conserver la clé privée en
lieu sûr et copier :

| Secret GitHub | Valeur |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` | contenu de la clé privée EdDSA exportée par `generate_keys -x <fichier>` |
| `SPARKLE_PUBLIC_KEY` | clé publique affichée par `generate_keys` |

Ajouter ces valeurs dans **Settings → Secrets and variables → Actions → New
repository secret**.

Ne jamais committer la clé privée. Le workflow l’utilise uniquement en mémoire
pour signer le DMG dans `appcast.xml`. La clé publique est injectée dans
`Info.plist` au moment de la compilation.

## 3. Secrets Apple facultatifs

Ces secrets ne servent pas à l’App Store. Ils permettent seulement une signature
**Developer ID** et la notarisation Apple, afin que Gatekeeper ouvre le DMG sans
avertissement inhabituel.

| Secret GitHub facultatif | Valeur |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE` | certificat Developer ID Application `.p12`, encodé en base64 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | mot de passe d’export du `.p12` |
| `APPLE_ID` | identifiant Apple utilisé pour la notarisation |
| `APPLE_APP_SPECIFIC_PASSWORD` | mot de passe spécifique à l’application |
| `APPLE_TEAM_ID` | identifiant de l’équipe Apple Developer |

Il faut soit renseigner les cinq secrets Apple, soit n’en renseigner aucun :

- sans eux, le workflow produit un DMG signé ad hoc et Sparkle reste sécurisé par
  la signature EdDSA ; macOS peut demander un clic droit → **Ouvrir** au premier
  lancement ;
- avec eux, le même DMG est signé Developer ID, envoyé à la notarisation puis
  agrafé, toujours sans publication sur l’App Store.

Le secret `CI_KEYCHAIN_PASSWORD` n’est plus nécessaire : le workflow génère un mot
de passe temporaire à chaque exécution.

## Publication automatique

Après fusion sur `main`, tout push modifiant `Sources/`, `Resources/`, `Package.swift`
ou les scripts de build déclenche automatiquement :

1. les tests ;
2. la création d’un bundle universel Apple Silicon + Intel ;
3. la création de `ProxyCodex.dmg` ;
4. la signature du flux Sparkle ;
5. une GitHub Release avec une version automatique `1.0.<numéro du run>`.

Un changement uniquement dans `docs/` republie le site, sans créer inutilement une
nouvelle version de l’application.

Pour choisir exceptionnellement une version précise, lancer **Actions → Publish
macOS update → Run workflow** et saisir une version `X.Y.Z`.

La landing page récupère toujours le dernier DMG via l’API GitHub Releases. Les
copies installées utilisent l’URL Sparkle stable
`https://github.com/lp460/proxycodex/releases/latest/download/appcast.xml`.
Ainsi, ni le site ni l’application n’ont besoin d’être modifiés pour pointer vers
chaque nouvelle version.
