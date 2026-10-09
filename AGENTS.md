# AGENTS.md — Guide des agents pour Cumulus

Ce document oriente les sessions d'agents (Claude Code, Codex) qui travaillent sur ce dépôt. Il décrit le produit, le workflow et les conventions. **Lis-le en premier.**

---

## 1. Vue d'ensemble

**Cumulus** (dépôt, target et équipe Linear : « Xcode Cloud Companion ») est une app macOS qui vit dans la barre des menus. Elle surveille la consommation Xcode Cloud d'un compte App Store Connect (heures de calcul utilisées par rapport au forfait) et liste les builds récents de chaque app.

| | |
|---|---|
| Plateforme | macOS 27.0+ (`MACOSX_DEPLOYMENT_TARGET = 27.0`) |
| Langage | Swift, SwiftUI pour les vues, AppKit pour la structure du menu |
| Target / scheme | `xcode-cloud-companion` (produit : `Cumulus.app`, module `XcodeCloudCompanion`, bundle ID `com.guik.xcode-cloud-companion`) |
| Sandbox | Activé (garder la porte du Mac App Store ouverte) |
| Dépendances | Aucune |

### Source de données : API App Store Connect

- Authentification par jeton JWT ES256, signé avec une clé API `.p8` (Issuer ID + Key ID). La clé est stockée dans le trousseau, jamais en clair.
- Chemin des données : `GET /v1/ciProducts` → `GET /v1/ciProducts/{id}/buildRuns` → `GET /v1/ciBuildRuns/{id}/actions`. Aucun endpoint ne liste d'un coup tous les builds de l'équipe.
- `ciBuildRuns` et `ciBuildActions` exposent `startedDate`, `finishedDate`, `executionProgress` (`PENDING`, `RUNNING`, `COMPLETE`) et `completionStatus` (`SUCCEEDED`, `FAILED`, `ERRORED`, `CANCELED`, `SKIPPED`). Les actions ont aussi `actionType` (`BUILD`, `ANALYZE`, `TEST`, `ARCHIVE`) et les builds `startReason`.
- ⚠️ **Aucun endpoint n'expose la consommation ni le quota Xcode Cloud** (vérifié dans la doc Apple le 09/10/2026). La consommation affichée est donc une **estimation** : la somme des durées des actions (elles tournent en parallèle sur des machines distinctes). Le forfait et le jour de réinitialisation sont saisis par l'utilisateur. Toujours présenter le chiffre comme une estimation.
- Un build `COMPLETE` ne change plus : il se met en cache et ne se redemande pas. Seuls les builds en cours ou récents se rafraîchissent, pour ménager la limite de requêtes de l'API.

### Interface : un vrai menu natif

Le modèle est CodexBar : un `NSStatusItem` + `NSMenu`, dont certaines lignes sont des vues SwiftUI hébergées (barres de progression, chiffres, histogramme). Le reste, ce sont des `NSMenuItem` standards (sous-menus, surlignage, navigation clavier). Ne pas remplacer par un popover ni par `MenuBarExtra(.window)`.

### Architecture

**Cycle de vie AppKit**, pas d'`App` SwiftUI : `AppDelegate` porte `@main` et lance `NSApplication`. Depuis macOS 14, la scène `Settings` de SwiftUI ne s'ouvre pas depuis un `NSMenu` ; les Réglages sont une `NSWindow` qui héberge une vue SwiftUI. Un menu principal minimal (`MainMenu`) reste indispensable : invisible dans une app `LSUIElement`, il porte quand même ⌘, ⌘Q, ⌘W et le menu Édition, sans lequel ⌘V ne marche pas dans les champs.

| Dossier / fichier | Rôle | Isolation |
|---|---|---|
| `AppDelegate.swift` | Point d'entrée ; crée les modèles, branche veille et réveil sur la synchronisation | `MainActor` |
| `MainMenu.swift`, `StatusItemController.swift` | Menu principal invisible, élément de la barre des menus | `MainActor` |
| `AppStoreConnect/` | Jeton JWT, requêtes, décodage JSON:API, modèles `CIProduct` / `CIBuildRun` / `CIBuildAction` | `nonisolated`, sauf `AppStoreConnectClient` (`actor`, protège le jeton) |
| `Settings/` | Trousseau (`KeychainCredentialsStore`), forfait (`UsagePlan`), ouverture à la connexion, fenêtre et modèles des Réglages | modèles d'interface `MainActor`, le reste `nonisolated` |
| `Sync/` | `BuildSynchronizer` (calcul `@concurrent` d'un nouvel instantané), `BuildCacheStore` (cache JSON dans le conteneur), `SyncSchedule`, `BuildStore` (source de vérité des builds, `@Observable`) | `BuildStore` `MainActor`, le reste `nonisolated` |
| `Usage/` | Minutes facturées : lecture de l'export CSV d'App Store Connect, registre `UsageLedger`, `UsageStore` + `DirectoryWatcher` (import automatique depuis Téléchargements). `UsageCalculator` combine minutes exactes et estimation calibrée par workflow. Diagnostic Debug | `UsageStore` `MainActor`, le reste `nonisolated` |
| `Menu/` | Construction du menu de la barre : `StatusMenuBuilder` (ordre des sections), `LatestBuildsMenu` (5 derniers builds), `AppBuildsMenu` (lignes d'apps et sous-menus), blocs SwiftUI hébergés (`UsageGaugeView`, `MeasuringHeaderView`), `BuildStatus` et `BuildStatusDot` (points d'état), `MenuBarBadge` (état de la pastille) et `MenuBarIcon` (image de la barre, symboles `logo` et `logo.badge`), `UsageFormat` | `MainActor`, sauf `UsageFormat`, `BuildStatus` et `MenuBarBadge` (`nonisolated`) |

**Source des minutes** (XCO-6, mesuré sur 55 builds réels le 09/10/2026) : Apple facture **par machine**. Chaque destination de test paie son temps d'exécution (`destinationTestResults[].duration`, sommé par appareil) plus ~4,5 min de préparation, et deux fois ses tests quand l'un d'eux échoue (rejoué) ; une archive réussie paie son calcul seul, pas l'envoi à TestFlight : on prend son passage réussi le plus court. Le tout dans `MachineModel`. Résultat : +2 % sur 30 jours, 4 min d'écart moyen par build, sauf certains échecs rejoués (jusqu'à −40 min). La durée murale d'un test ne dit **ni** le nombre de simulateurs **ni** leur attente : ne jamais l'additionner. L'export CSV d'Apple (XCO-14) reste la source exacte quand il est importé.

**Pièges de la barre des menus** (vérifiés sur le vrai bouton le 09/10/2026) :
- L'image du bouton vient des symboles du catalogue (`MenuBarIcon`) : `logo` seul en template, ou `logo.badge` en palette (pastille = niveau primaire, à la couleur de l'état ; nuage = niveau secondaire, à la couleur du texte résolue **au dessin**, sinon il prend l'apparence de l'app et non celle de la barre). Les deux se chargent par `NSImage(symbolName:bundle:)` : l'icône d'app s'appelle aussi « logo ». Aucune vue n'est posée sur le bouton.
- Une icône ajoutée alors que la barre est pleine est **masquée** (icône « « » de débordement) : pour voir sa propre instance, libérer de la place ou quitter une autre instance de l'app.
- En Debug, `XCC_BADGE=running|failed|succeeded|stopped|none` force la pastille de la barre.
- `NSMenuItem.badge` n'accepte ni couleur ni style : l'âge des builds et les minutes des apps y sont des textes courts ; les points d'état et le carré de couleur d'une app sont des caractères teintés (« • », « ◉ », « ■ ») en tête du titre attribué : le menu n'affiche **aucune** `NSMenuItem.image` (ni dessinée, ni symbole SF), vérifié le 09/10/2026.

**Mesure au premier chargement** : les résultats de tests par appareil arrivent par lots de 12 actions, du build le plus récent au plus ancien, un lot par minute (`BuildSynchronizer`). Tant que le cycle en a en attente, `UsageSummary.measurement.isMeasuring` est vrai et le menu n'affiche aucun chiffre qui dépendrait d'eux. Une action refusée trois fois par Apple est abandonnée (`BuildSnapshot.testResultAttempts`) ; un 429 ne coûte aucune tentative.

**Localisation** (XCO-21 à 23) : langue source anglaise, `Localizable.xcstrings` traduit en français. `xcodebuild` ne met pas à jour le catalogue source (seul Xcode le fait) : après l'ajout d'une chaîne, le resynchroniser avec `xcrun xcstringstool sync xcode-cloud-companion/Localizable.xcstrings --stringsdata <DerivedData>/…/Objects-normal/arm64/*.stringsdata`, puis traduire la nouvelle entrée (le test `FrenchLocalizationTests` échoue sinon). Le schéma fixe la langue des tests à l'anglais. Un `NSMenuItem` n'affiche aucune `image` dans ce menu : voir les pièges ci-dessus.

Les tests s'exécutent **dans l'app** (`TEST_HOST`) : `AppDelegate` ne démarre pas la synchronisation quand `XCTestConfigurationFilePath` est défini, pour ne jamais appeler l'API avec la vraie clé pendant les tests.

---

## 2. Workflow

### Branches

Le travail se fait sur une **branche de feature** au format `claude/<description>-<hash>` (ou `codex/…` pour Codex), créée **dans le dossier principal** du dépôt, pas dans un `git worktree`. **Ne jamais commiter directement sur `main`**, ne pas pousser la branche vers `origin` ni ouvrir de PR de soi-même : le travail reste **local** pendant tout le statut **In Review**, pour que l'utilisateur le teste sur sa machine.

Un ticket demandé en cours de session se développe **sur la branche en cours**, avec son propre commit. Ne changer de branche que si l'utilisateur le demande.

Une fois l'utilisateur revenu avec sa validation (ticket → **Done**, cf. § Tickets) : squash-merge de la branche dans `main` en local, puis suppression de la branche.

```bash
git checkout main
git merge --squash claude/<branche>
git commit -m "XCO-12: …"          # ou « projet: <nom du projet> », cf. § Style de commits
git branch -D claude/<branche>     # -D : après un squash, git ne voit pas la branche comme fusionnée
```

Plusieurs sessions peuvent tourner en parallèle dans ce dossier :
- toujours stager des **chemins explicites** (`git add <chemins>`), jamais `git add -A`, `git add .` ni `git commit -a` ;
- `git status --short` et `git branch --show-current` juste avant chaque commit ;
- jamais de `git reset --hard`, `git stash` ni `git checkout -- .` global.

Les reformatages massifs faits par Xcode (imports, accolades) se laissent tels quels.

### Style de commits

Titres courts **en français, à l'indicatif, qui disent l'effet produit** plutôt que le fichier touché (« Le menu montre les heures consommées sur le cycle », « Un build échoué s'affiche en rouge dans le sous-menu de son app »). Préfixe :

- **un ticket** : son identifiant, sans type ni parenthèses — `XCO-12: Le menu montre les heures consommées sur le cycle`. Plusieurs tickets dans un même commit : le préfixe une seule fois, puis les numéros séparés par des tirets — `XCO-3-4: …` (chaque numéro est cité, ce n'est pas un intervalle) ;
- **un projet Linear entier, squash-mergé d'un coup** : `projet: <nom du projet>`. Le corps du commit liste alors les tickets, un par ligne (`XCO-12 Le menu montre les heures consommées sur le cycle`), puisque le squash efface les commits par ticket ;
- **aucun ticket** (retouche d'AGENTS.md, rapports) : le titre seul, sans préfixe.

### Granularité des commits

Sur une branche qui traite plusieurs tickets, faire **un commit distinct par ticket** dès que son implémentation est cohérente (tests ciblés inclus). Ne pas accumuler les changements jusqu'à la fin du lot, et ne pas mélanger les fichiers de tickets indépendants dans un même commit. Si un fichier partagé est modifié par plusieurs tickets, séparer ses hunks dans l'index.

### Tickets (Linear)

<CRITICAL_INSTRUCTION>

Le suivi se fait dans **Linear**, team **« Xcode Cloud Companion »**, préfixe **`XCO-`**. L'identifiant `XCO-xx` est attribué par Linear à la création : ne jamais le choisir ni le reporter dans le titre. Les outils Linear passent par le connecteur claude.ai (`save_issue`, `save_comment`, `get_issue`…, à charger via ToolSearch) ; essayer ces outils avant de conclure que Linear est inaccessible.

`Status` a 9 valeurs, dans cet ordre de maturité :
- **Backlog** — idée brute ou en cours de rédaction, pas encore groomée.
- **Ready** — groomé et sélectionné par l'utilisateur. ⚠️ **Réservé à l'utilisateur : un agent ne développe jamais un ticket en Ready**, sauf si l'utilisateur désigne explicitement son numéro.
- **Ready for IA** — groomé **et** confié aux agents. ⚠️ Toujours **attendre le feu vert explicite de l'utilisateur** avant d'en attaquer un : ce statut signale l'éligibilité, pas l'autorisation de démarrer.
- **In Progress** — en cours d'implémentation.
- **Blocked** — développement entamé puis arrêté : critère ambigu, question à trancher, ou action de l'utilisateur nécessaire.
- **In Review** — implémentation terminée, en attente de validation utilisateur.
- **Done** — validé par l'utilisateur.
- **Canceled** — abandonné (garder la trace, ne pas supprimer).
- **Duplicate** — doublon d'un autre ticket.

**Avant toute modification de code non triviale** (feature, bug, refactor demandé) :
1. Chercher si un ticket existe déjà dans la team XCO (`list_issues`, par titre ou mot-clé).
2. Sinon, **créer le ticket avant de commencer** (`save_issue`, team « Xcode Cloud Companion ») : titre clair **préfixé d'un emoji pertinent** (« 📊 Calcul de l'usage par cycle », « 🐛 … »), description avec critères d'acceptation en checklist (`- [ ] #1 …`, **18 critères au plus** : au-delà, Linear transforme `#19`… en liens vers des PR sans rapport ; découper en tickets liés). Statut : **Backlog** si la demande est encore une idée, **Ready for IA** si elle est groomée et actionnable. Ne jamais poser **Ready** soi-même.
3. Labels : le type (`Feature`, `Bug`, `Improvement`, `Chore`, `Research`) + les labels thématiques existants du workspace qui conviennent (`ui`, `ux`, `infra`, `tooling`, `notifications`, `security`…) ; en créer un si aucun ne convient. Un ticket parent qui regroupe un chantier porte `Epic`. Dépendances via `blockedBy` / `blocks`.

**Au moment de commencer** (ticket désigné par l'utilisateur) : passer le ticket en **In Progress** tout de suite, avant la première ligne de code. L'utilisateur suit l'activité depuis Linear.

**Pendant le travail** : consigner les découvertes, décisions et écarts de scope en **commentaires** sur le ticket (`save_comment`) au fil de l'eau, pas seulement à la fin. En cas de blocage, passer en **Blocked** et écrire pourquoi, plutôt que deviner et continuer.

**Une fois l'implémentation terminée** :
- vérifier chaque critère d'acceptation un par un et cocher (`- [x]`) ceux satisfaits ; un critère devenu hors scope se documente, il ne se coche pas ;
- ajouter une section « Réalisé » à la description, résumé durable de ce qui a été fait ;
- passer en **In Review**, jamais directement en Done.

**Points restants** : tout « à trancher » ou « reste à faire » relevé en cours de route devient un **ticket lié** (`relatedTo`), en Ready for IA s'il est actionnable, en Backlog s'il attend un arbitrage. Pas de liste de questions laissée dans la réponse finale.

**Après validation de l'utilisateur** : relancer le build et les tests concernés. Passer en **Done** et squash-merger dans `main` **seulement après succès**. En cas d'échec, garder le ticket en In Review (ou repasser en In Progress), documenter le résultat et ne pas merger.

⚠️ Toute mention d'un autre ticket en texte brut (`XCO-12`) devient un lien Linear : une faute de frappe crée un lien silencieusement faux. Vérifier le numéro avant de l'écrire.

</CRITICAL_INSTRUCTION>

### Vérifier avant de rendre

Xcode est installé sur cette machine : compiler soi-même ses changements et rapporter le résultat.

```bash
# Build
xcodebuild build -scheme xcode-cloud-companion -project xcode-cloud-companion.xcodeproj \
  -destination 'platform=macOS'

# Tests
xcodebuild test -scheme xcode-cloud-companion -project xcode-cloud-companion.xcodeproj \
  -destination 'platform=macOS'
```

- **Zéro erreur, zéro warning.** Tout code nouveau ou modifié n'en introduit aucun, et un warning rencontré sur du code touché se corrige dans la foulée. Un build incrémental masque les warnings des fichiers non recompilés : faire un `clean build` pour un état des lieux fiable. Seul le message d'outillage `appintentsmetadataprocessor: Metadata extraction skipped` ne compte pas.
- Le scheme `xcode-cloud-companion` est **partagé** (`xcshareddata/xcschemes/`) et lance la target `xcode-cloud-companionTests` : toute nouvelle target de tests s'y ajoute.
- **Toolchain de référence : la dernière version publique d'Xcode** (Xcode 27.1 RC au 09/10/2026, `/Applications/Xcode-27.1.0-Release.Candidate.app`). Si le Xcode sélectionné est une bêta, valider avec `DEVELOPER_DIR` pointé sur la version publique. N'utiliser aucune API ni syntaxe propre à une bêta.
- **Compiler l'app au moins une fois en `Release`** (`xcodebuild build -configuration Release`) avant de clore un lot : un `#Preview` qui lit un membre DEBUG-only casse uniquement la Release. Les tests, eux, ne se compilent qu'en Debug (`@testable import` exige la testabilité).
- Si Xcode est ouvert, `xcodebuild` peut échouer sur `database is locked` : passer `-derivedDataPath` vers un dossier de travail.
- Pour une modification visuelle, un build vert ne suffit pas : lancer l'app et vérifier le rendu du menu.

---

## 3. Conventions de code

- **Concurrence Swift 6 stricte, isolation par défaut `MainActor`** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`). Chaque type reçoit une isolation choisie, pas subie :
  - **`MainActor` seulement pour ce qui touche l'interface** : vues SwiftUI, `NSStatusItem` / `NSMenu`, état observé par les vues ;
  - **`nonisolated` pour tout le reste** : modèles de données (structs `Sendable`), décodage, calcul de l'usage, construction des requêtes, formatage. C'est le cas le plus fréquent ;
  - **un `actor` seulement s'il protège un état mutable partagé** (cache, jeton JWT en cours de validité) ;
  - **de l'asynchrone seulement quand c'est indispensable** (réseau, disque, trousseau). Une fonction de calcul reste synchrone ;
  - **pas de saut d'acteur inutile** : on ne fait pas d'aller-retour vers le `MainActor` pour une donnée qui peut se calculer ailleurs, et on ne passe à l'interface que le résultat final.
- **Économie de données** : ne demander à l'API que ce qui sert (`fields[…]`, `limit`, `include` ciblés), ne pas redemander ce qui est en cache, ne garder en mémoire que ce que l'interface affiche.
- **Pas de contournement** : ni `nonisolated(unsafe)`, ni `@unchecked Sendable`, ni `@preconcurrency import`. Chercher la vraie isolation ; si un contournement semble inévitable, le signaler et le justifier.
- **Ajout de fichiers** : le projet utilise des groupes synchronisés, un fichier créé dans `xcode-cloud-companion/` est pris en compte sans éditer `project.pbxproj`.
- **Secrets** : la clé `.p8`, l'Issuer ID et le Key ID vivent dans le trousseau. Ne jamais les écrire dans le code, les logs, les tests ni les tickets.
- **Tests** : Swift Testing. Le calcul de l'usage (cycles, quota, rythme) et le décodage des réponses de l'API se testent avec des fixtures JSON, sans appel réseau.
- **Commentaires** : aucun par défaut. Seulement pour un *why* non évident (contrainte de l'API, invariant caché).
- **Pas d'emoji dans les fichiers source**, sauf demande explicite.

---

## 4. Quand demander confirmation

- Modifier `project.pbxproj` à la main (préférer Xcode ou ses outils).
- Ajouter une dépendance externe (SPM) : l'app est volontairement sans dépendances.
- Changer les entitlements, le sandbox ou le bundle ID.
- `git push --force` : à éviter complètement, sauf demande explicite.
- Supprimer un test existant (préférer `.disabled("…raison…")`).

---

## 5. Conventions de réponse

- **Langue** : français par défaut.
- **Ton** : concis, factuel, sans enthousiasme de façade.
- **Traçabilité** : tout raisonnement, décision d'implémentation ou évolution de scope va dans le ticket Linear (commentaire ou description), pas seulement dans la conversation.
- **Faits durables** : quand une information stable se re-dérive à chaque session (architecture, points d'entrée, commandes), l'ajouter à ce fichier plutôt que dans la mémoire de l'agent. Une information périmée ici se corrige ici.

---

## 6. À ne pas faire

- ❌ Refactorer un sous-système sans demande explicite.
- ❌ Mettre à jour `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` automatiquement.
- ❌ Toucher aux assets `Assets.xcassets` (gérés par Xcode).
- ❌ Créer des fichiers `*.md` supplémentaires non demandés.
- ❌ Présenter la consommation estimée comme un chiffre officiel d'Apple.
- ❌ Mentionner l'identifiant interne du modèle dans un commit, une PR ou un commentaire de code.
