# AGENTS.md — Guide des agents pour Cumulus

Ce document oriente les sessions d'agents (Claude Code, Codex) qui travaillent sur ce dépôt. Il décrit le produit, le workflow et les conventions. **Lis-le en premier.**

---

## 1. Vue d'ensemble

**Cumulus** (dépôt, target et équipe Linear : « Xcode Cloud Companion ») est une app macOS qui vit dans la barre des menus. Elle surveille la consommation Xcode Cloud d'un compte App Store Connect (heures de calcul utilisées par rapport au forfait) et liste les builds récents de chaque app.

| | |
|---|---|
| Plateforme | macOS 27.0+ (`MACOSX_DEPLOYMENT_TARGET = 27.0`) |
| Langage | Swift, SwiftUI pour les vues, AppKit pour la structure du menu |
| Target / scheme | target `xcode-cloud-companion`, scheme `Cumulus` (produit : `Cumulus.app`, module `XcodeCloudCompanion`, bundle ID `com.guik.xcode-cloud-companion`) |
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

**Cycle de vie AppKit**, pas d'`App` SwiftUI : `AppDelegate` porte `@main` et lance `NSApplication`. Depuis macOS 14, la scène `Settings` de SwiftUI ne s'ouvre pas depuis un `NSMenu` ; les Réglages sont une `NSWindow` qui héberge une vue SwiftUI. `MainMenu` est un menu complet (Cumulus, Fichier, Édition, Présentation, Fenêtre, Aide) : invisible tant que l'app est `.accessory`, il porte quand même ⌘, ⌘Q ⌘W ⌘0 et le menu Édition, sans lequel ⌘V ne marche pas dans les champs. La fenêtre principale est une `NSWindow` (une scène SwiftUI `Window` ne s'ouvre pas depuis un `NSMenu`), comme les Réglages ; un clic sur un build du menu l'ouvre sur ce build.

| Dossier / fichier | Rôle | Isolation |
|---|---|---|
| `AppDelegate.swift` | Point d'entrée ; crée les modèles, branche veille et réveil sur la synchronisation | `MainActor` |
| `MainMenu.swift`, `StatusItemController.swift` | Menu principal invisible, élément de la barre des menus | `MainActor` |
| `AppStoreConnect/` | Jeton JWT, requêtes, décodage JSON:API, modèles `CIProduct` / `CIBuildRun` / `CIBuildAction` | `nonisolated`, sauf `AppStoreConnectClient` (`actor`, protège le jeton) |
| `Settings/` | Trousseau (`KeychainCredentialsStore`), forfait (`UsagePlan`), ouverture à la connexion, fenêtre et modèles des Réglages, onglet Agents (liens de la commande et du skill) | modèles d'interface `MainActor`, le reste `nonisolated` |
| `Sync/` | `BuildSynchronizer` (calcul `@concurrent` d'un nouvel instantané), `BuildCacheStore` (cache JSON dans le conteneur), `SyncSchedule`, `BuildStore` (source de vérité des builds, `@Observable`) | `BuildStore` `MainActor`, le reste `nonisolated` |
| `Usage/` | Minutes facturées : lecture de l'export CSV d'App Store Connect, registre `UsageLedger`, `UsageStore` + `DirectoryWatcher` (import automatique depuis Téléchargements). `UsageCalculator` combine minutes exactes et estimation calibrée par workflow. Diagnostic Debug | `UsageStore` `MainActor`, le reste `nonisolated` |
| `Window/` | Fenêtre principale (`NSWindow` hébergeant `MainWindowView`, `NavigationSplitView` à 3 colonnes), `NavigationModel` (sélection partagée entre le menu, l'URL `cumulus://build/<id>` et la fenêtre), `ActivationPolicyCoordinator` (`.regular` à l'ouverture pour le Dock et le menu principal, `.accessory` à la fermeture ; réglage « Afficher dans le Dock »), `Sidebar/`, `Builds/` (liste par jour), `Details/` (fiche d'un build, onglets, cache `BuildDetails/`), `Workflows/`, `Launch/` (lancement, voir ci-dessous), `Components/` (style « Verre et chronologie ») | `MainActor`, sauf `CumulusURL` (`nonisolated`) |
| `Notifications/` | Notifications locales : `BuildNotificationPlanner` (calcul pur de ce qui mérite une bannière entre deux instantanés), `NotificationCoordinator` (autorisation en contexte, envoi), `NotificationPreferences` (réglages), `SystemNotificationCenter` et `NotificationResponder` (enveloppe d'`UNUserNotificationCenter`) | `NotificationCoordinator` et `NotificationPreferences` `MainActor`, le reste `nonisolated` |
| `Menu/` | Construction du menu de la barre : `StatusMenuBuilder` (ordre des sections), `LatestBuildsMenu` (5 derniers builds), `AppBuildsMenu` (lignes d'apps et sous-menus), blocs SwiftUI hébergés (`UsageGaugeView`, `MeasuringHeaderView`), `BuildStatus` et `BuildStatusDot` (points d'état), `MenuBarBadge` (état de la pastille) et `MenuBarIcon` (image de la barre, symboles `logo` et `logo.badge`), `UsageFormat` | `MainActor`, sauf `UsageFormat`, `BuildStatus` et `MenuBarBadge` (`nonisolated`) |
| `CLI/` (racine du dépôt) | La commande `cumulus` embarquée dans `Cumulus.app/Contents/Helpers` : analyse des arguments, commandes, sortie. Tout sauf `main.swift` est aussi compilé dans l'app, pour être testé et réutilisé par les Réglages | `nonisolated` |

**Cible `cumulus`** (XCO-57, vérifié le 10/10/2026) : un outil en ligne de commande (bundle ID `com.guik.xcode-cloud-companion.cli`, Info.plist embarqué dans le binaire), signé avec **sa propre** sandbox et l'app group `4HYT2U85R2.com.guik.cumulus` (`Config/cumulus-cli.entitlements` ; l'app porte le même groupe par `Config/Cumulus.entitlements`). Un helper signé « inherit » serait tué dès qu'on le lance depuis un terminal. Il ne lit ni le trousseau ni le réseau : seulement ce que l'app écrit dans le conteneur de groupe (`SharedContainer.applicationSupport` : `BuildCache.json`, `UsageLedger.json`, `UsagePlan.json`, `BuildDetails/`, `WorkflowDetails/`). `CacheMigration` y déplace une fois les caches d'avant. Le forfait vit dans les préférences de l'app, hors de portée du CLI : `SettingsModel` en tient une copie par `SharedPlanStore`. Les fichiers de l'app que le CLI compile sont listés un par un dans `project.pbxproj` (`PBXFileSystemSynchronizedBuildFileExceptionSet` de la cible `cumulus`) : un nouveau fichier partagé s'y ajoute à la main ; aucun fichier qui importe AppKit ou SwiftUI.

**Contrat de la commande `cumulus`** (XCO-58) : `status`, `apps`, `builds`, `build <App#42 | id>`, `workflows`, `usage`, `open`, `refresh [--wait]`. JSON dans un tube, tableau sur un terminal (`--json` / `--table`). Enveloppe `{ data, meta }` ; `meta.lastSuccessfulSync` dit l'âge du cache, `meta.appRunning` si l'app répond sur son socket, et `meta.isEstimate` signale des minutes estimées. Erreurs sur stderr (`{ error: { code, message, suggestions } }`), codes de sortie 0, 1, 2 (usage), 3 (pas de cache ou pas de clé), 4 (app injoignable), 5 (introuvable ou ambigu), 6 (délai dépassé). Les noms de propriétés des types de `CLI/CLIModels.swift` **sont** les clés JSON publiques : en renommer une casse les agents, et `CLICommandTests` le signale. Sortie en anglais, hors catalogue de traduction. `CLIQueryRunner` répond à une `CLIQuery` ; la ligne de commande et le serveur MCP passent tous deux par lui.

**Socket entre l'app et `cumulus`** (XCO-59, vérifié le 10/10/2026) : l'app écoute un socket Unix `ipc.sock` à la racine du conteneur de groupe, le seul endroit où la sandbox en permet un (`IPCSocketServer`, POSIX + Dispatch ; le chemin tient en 103 octets, d'où la racine et un identifiant de groupe court). Un objet JSON par ligne dans chaque sens (`CLI/IPC/`) : `ping`, `refresh { wait }`, `open { buildRunID }`, `loadDetails { buildRunID }`. Aucune méthode n'écrit chez Apple. `AppIPCService` refuse une synchro de moins de 30 s (`recent`) et n'en lance pas une seconde (`syncing`). `loadDetails` charge les problèmes, tests et artefacts d'un build terminé comme le fait sa fiche : c'est ce qui permet à `cumulus build` de répondre sur un build jamais ouvert dans la fenêtre. Un socket accepté hérite du mode non bloquant de l'écoute sur macOS : il est remis en bloquant. Les attentes sur socket se font sur une file Dispatch, jamais sur le pool de concurrence Swift. Une seconde instance de l'app laisse le socket de la première ; le serveur ne démarre pas sous tests.

**Serveur MCP** (XCO-60, vérifié avec Claude Code le 10/10/2026) : `cumulus mcp` parle Model Context Protocol sur stdio, écrit à la main dans `CLI/MCP/` (JSON-RPC 2.0, un message par ligne ; `initialize`, `ping`, `tools/list`, `tools/call` ; versions 2025-03-26, 2025-06-18 et 2025-11-25). Sept outils, chacun rendant le JSON de la commande correspondante en texte et en `structuredContent` : `get_status`, `list_apps`, `list_builds`, `get_build`, `list_workflows`, `get_usage`, `refresh`. Une erreur métier est un résultat `isError: true` que le modèle lit, jamais une erreur JSON-RPC. Rien d'autre que le protocole ne s'écrit sur stdout ; `--verbose` journalise sur stderr. Un outil s'ajoute dans `MCPTools.all`, avec sa description écrite pour un agent ; aucun outil ne lance de build.

**Réglages › Agents** (XCO-64) : cinquième onglet des Réglages (`AgentsSettingsView`, `AgentsSettingsModel`, `AgentLinks.swift`). Il installe la commande et le skill par **liens symboliques** depuis un dossier que l'utilisateur choisit dans un panneau (c'est ce choix qui ouvre le dossier à la sandbox ; un signet à portée de sécurité est gardé pour pouvoir retirer le lien plus tard) : `<dossier du PATH>/cumulus` vers `Contents/Helpers/cumulus`, `~/.claude/skills/cumulus` et `~/.codex/skills/cumulus` vers `Contents/Resources/AgentSkill/cumulus`. La sandbox laisse l'app **lire** ces liens sans autorisation, d'où l'état affiché sans rien demander (vérifié le 10/10/2026). Un lien n'est remplacé ou retiré que s'il mène dans un bundle Cumulus. Le skill (`xcode-cloud-companion/AgentSkill/cumulus/`, en anglais, copié tel quel dans le bundle par `explicitFolders` du groupe synchronisé) est la documentation que lisent les agents : `AgentSkillBundleTests` échoue si une commande, un outil MCP, un de ses arguments ou un code d'erreur n'y figure pas. Les lignes d'enregistrement du serveur MCP par client sont dans `AgentClient`.

**Nom et icône d'une app** (XCO-73, vérifié sur le vrai compte le 10/10/2026) : l'interface affiche `CIProduct.displayName` (le nom du Store quand le produit est une app qui en a un, sinon le nom du produit). `product.name` **reste la clé** de la couleur d'une app (`AppPalette`), de ses minutes d'usage (l'export d'Apple parle en noms de produits) et des références du CLI (`App#42`, `--app`) : ne jamais les passer au nom du Store. Là où la place est comptée (colonne d'app du menu, ligne d'un build), `CIProduct.compact` coupe le nom à 14 caractères. L'icône vient de l'`iconAssetToken` d'un build : un gabarit `https://…mzstatic.com/…/{w}x{h}bb.{f}` servi sans authentification, dont le chemin finit par `.icns` pour une app Mac (dessinée telle quelle ; les autres sont des carrés pleins, arrondis dans l'app). Une requête au plus par jour (`BuildSynchronizer.refreshedIcons`) : `GET /v1/apps?include=builds&limit[builds]=1` tant qu'aucune icône n'est connue ou qu'une app apparaît (toutes les apps d'un coup, mais le build inclus n'est **pas** forcément le plus récent), puis `GET /v1/builds?sort=-uploadedDate&include=app` (les builds les plus récents, où se voit un changement d'icône). Les jetons vivent dans `BuildSnapshot.appIcons` (par `appID`), les images dans `Caches/AppIcons` (`AppIconCache`, un fichier par app et par jeton), chargées par `AppIconStore` pour la fenêtre. Le menu de la barre n'affiche pas d'icône.

**Ce qui a cassé** (XCO-66) : sur la fiche d'un build en échec, `RegressionGroup` compare avec le dernier build `SUCCEEDED` du même workflow, même branche d'abord (`RegressionReport.reference`). Les tests se rapprochent par action de même nom, classe et nom ; un test absent de la référence est « nouveau », pas « cassé ». Les problèmes se rapprochent par type, message et fichier, sans le numéro de ligne. Rien n'est demandé à Apple à l'ouverture : ce que `BuildDetails/` contient s'affiche (`BuildExtrasStore.loadCached`), le reste se charge au clic sur « Comparer », une action à la fois, et pas sous `SyncSchedule.criticalRemaining`. Les deux SHA ne s'affichent que si Apple les a donnés ; le lien de comparaison n'est construit que pour une adresse `github.com/<owner>/<repo>/commit/<sha>`.

**Journaux d'une action** (XCO-70, vérifié sur une vraie archive le 10/10/2026) : le bouton « Journaux » (onglet Actions, et action en échec de la frise) télécharge l'artefact `LOG_BUNDLE` de l'action avec les règles d'un artefact (`LogOpener` : adresse fraîche, `ArtifactAddress`, pas de jeton), le décompresse dans `Caches/Logs/<id de l'action>/` et ouvre le dossier dans le Finder, sans panneau d'enregistrement. Une vraie archive d'Xcode Cloud est un ZIP simple (entrées stockées ou « deflate », pas de ZIP64) : `ZipExtractor` le lit à la main avec `Compression`, sans `Process` ni dépendance. Il juge tous les chemins avant d'écrire le premier octet : une entrée absolue ou avec `..` refuse l'archive entière, un lien symbolique n'est jamais créé, une taille déclarée fausse ou au-delà du plafond aussi. Le cache est plafonné à 500 Mo, les dossiers ouverts le moins récemment partent d'abord. Les journaux d'un build `COMPLETE` déjà décompressés se rouvrent sans requête. Le bouton s'affiche pour toute action terminée tant qu'on ne sait pas qu'elle n'a pas d'archive : la liste des artefacts n'est pas demandée d'avance.

**Pourquoi un workflow coûte** (XCO-69) : dans la Vue d'ensemble, un clic sur une ligne de « Coût par workflow » déplie `WorkflowBreakdownView`. `WorkflowCostBreakdown` reprend build par build les minutes que compte `UsageCalculator` (facturées par l'export, ou estimées) et les répartit au prorata de `MachineModel.cost(of:)` : build, analyse, archive, tests par destination, préparation des machines, tests rejoués après un échec. Le total est donc celui de la Vue d'ensemble, au centième près (testé). Apple ne donne qu'un chiffre par build : la répartition est toujours modélisée, chaque poste porte un ~, et le texte dit si le total est exact ou estimé. Les constats (`Finding`) ne disent que ce que les chiffres portent, sans conseil ni promesse d'économie. Aucune requête : tout vient de l'instantané et du registre d'usage.

**Tests instables et tests lents** (XCO-67) : la fiche d'un workflow a une section Tests (`WorkflowTestsSection`). `TestHealthReport` (pur) lit les résultats de tests des builds terminés du workflow : un test est instable s'il est `MIXED` dans un build, ou s'il échoue et réussit sur **le même commit** ; échouer sur un commit puis réussir sur le suivant n'est pas de l'instabilité, toujours échouer non plus. Les plus lents sont classés par durée moyenne par appareil. C'est toujours un échantillon : la section dit combien de builds sont analysés sur combien. `TestHealthReader` lit `BuildDetails/` hors du fil principal, sans requête et sans garder les résultats entiers en mémoire ; « Analyser d'autres builds » charge les 10 plus récents qui manquent, un build après l'autre, s'arrête sur demande et sous `SyncSchedule.criticalRemaining`. Rien ne se charge en tâche de fond. Un clic sur un test instable ouvre le dernier build où il a échoué, onglet Tests (`NavigationModel.buildTab`).

**Notifications** (XCO-47) : locales, sans serveur ni entitlement. `BuildStore.onSync` donne l'instantané d'avant et d'après chaque synchro réussie ; un build « vient de finir » quand il était en cours avant et `COMPLETE` après (ou créé puis terminé entre deux synchros), depuis moins d'une heure. La première synchro d'une session ne notifie rien. L'autorisation n'est demandée qu'au moment d'envoyer la première bannière, ou par le bouton de l'onglet Notifications des Réglages : jamais au lancement. Un build bloqué (action `RUNNING` au-delà de N fois la médiane de la même action réussie du workflow, trois échantillons au moins) est signalé une fois, y compris après un redémarrage. Le clic ouvre l'adresse `cumulus://` portée par la bannière. `NotificationResponder` est `nonisolated` : le centre de notifications l'appelle hors du fil principal. Le délégué n'est posé que hors tests, et les tests passent par un `NotificationPosting` simulé. En Debug, `XCC_NOTIFY=1` poste une bannière d'essai après la première synchro.

**Alerte de forfait** (XCO-65) : `UsageAlertPlanner` lit le même `UsageSummary` que le menu, après chaque synchro : 75 % puis 90 % du forfait, et le rythme (`exhaustionDate`). Une alerte par seuil et par cycle, mémorisée dans les préférences (`UsageAlertState`) et remise à zéro quand le cycle change ; rien pendant la mesure du premier chargement ni sans forfait. Chaque message dit que le chiffre est une estimation tant qu'il reste des minutes estimées ou que l'export a plus de trois jours. Le clic ouvre `cumulus://overview`.

**Piège d'isolation** (vérifié le 10/10/2026) : dans ce module à isolation `MainActor` par défaut, une fermeture écrite dans une fonction `nonisolated` d'un type `MainActor` (une vue, par exemple) reste isolée au `MainActor` et **plante à l'exécution** hors du fil principal (`dispatch_assert_queue`). Mettre ce code dans un type `nonisolated`. Le lanceur de tests relance l'hôte et affiche quand même « passed » : après un doute, compter les rapports `Cumulus-*.ips` dans `~/Library/Logs/DiagnosticReports`.

**Source des minutes** (XCO-6, mesuré sur 55 builds réels le 09/10/2026) : Apple facture **par machine**. Chaque destination de test paie son temps d'exécution (`destinationTestResults[].duration`, sommé par appareil) plus ~4,5 min de préparation, et deux fois ses tests quand l'un d'eux échoue (rejoué) ; une archive réussie paie son calcul seul, pas l'envoi à TestFlight : on prend son passage réussi le plus court. Le tout dans `MachineModel`. Résultat : +2 % sur 30 jours, 4 min d'écart moyen par build, sauf certains échecs rejoués (jusqu'à −40 min). La durée murale d'un test ne dit **ni** le nombre de simulateurs **ni** leur attente : ne jamais l'additionner. L'export CSV d'Apple (XCO-14) reste la source exacte quand il est importé.

**Pièges de la barre des menus** (vérifiés sur le vrai bouton le 09/10/2026) :
- L'image du bouton vient des symboles du catalogue (`MenuBarIcon`) : `logo` seul en template, ou `logo.badge` en palette (pastille = niveau primaire, à la couleur de l'état ; nuage = niveau secondaire, à la couleur du texte résolue **au dessin**, sinon il prend l'apparence de l'app et non celle de la barre). Les deux se chargent par `NSImage(symbolName:bundle:)` : l'icône d'app s'appelle aussi « logo ». Aucune vue n'est posée sur le bouton.
- Une icône ajoutée alors que la barre est pleine est **masquée** (icône « « » de débordement) : pour voir sa propre instance, libérer de la place ou quitter une autre instance de l'app.
- En Debug, `XCC_BADGE=running|failed|succeeded|stopped|none` force la pastille de la barre.
- `NSMenuItem.badge` n'accepte ni couleur ni style : l'âge des builds et les minutes des apps y sont des textes courts ; les points d'état et le carré de couleur d'une app sont des caractères teintés (« • », « ◉ », « ■ ») en tête du titre attribué : le menu n'affiche **aucune** `NSMenuItem.image` (ni dessinée, ni symbole SF), vérifié le 09/10/2026.

**Écriture : lancer ou relancer un build** (XCO-43, seule requête qui modifie quelque chose chez Apple) : `POST /v1/ciBuildRuns`, **jamais rejouée par l'app**, même après un timeout ou un 5xx. Un échec ambigu relit d'abord `GET /v1/ciWorkflows/{id}/buildRuns?limit=1&sort=-number` (`BuildLauncher`), l'interface ne propose un nouvel essai qu'après. Le corps n'envoie `clean` que s'il vaut `true`, un lancement a une seule source (branche/tag ou PR), une relance aucune. Le réglage « Accès de la clé » (Réglages › Général, `KeyAccess`) est déclaré par l'utilisateur ; un 403 le repasse en lecture seule. Aucun lancement par URL ni par Raccourci. Le schéma `cumulus://build/<id>` et `cumulus://overview` (lecture seule, `CumulusURL`) est déclaré par `Config/URLScheme.plist`, fusionné à l'Info.plist généré (`INFOPLIST_FILE` + `GENERATE_INFOPLIST_FILE`) : `CFBundleURLTypes` ne se pose pas par `INFOPLIST_KEY_*`.

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
xcodebuild build -scheme Cumulus -project xcode-cloud-companion.xcodeproj \
  -destination 'platform=macOS'

# Tests
xcodebuild test -scheme Cumulus -project xcode-cloud-companion.xcodeproj \
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
- **Ajout de fichiers** : le projet utilise des groupes synchronisés, un fichier créé dans `xcode-cloud-companion/` est pris en compte sans éditer `project.pbxproj`. Un fichier créé dans `CLI/` entre dans l'app et dans la commande `cumulus`.
- **Secrets** : la clé `.p8`, l'Issuer ID et le Key ID vivent dans le trousseau. Ne jamais les écrire dans le code, les logs, les tests ni les tickets.
- **Tests** : Swift Testing. Le calcul de l'usage (cycles, quota, rythme) et le décodage des réponses de l'API se testent avec des fixtures JSON, sans appel réseau.
- **Commentaires** : aucun par défaut. Seulement pour un *why* non évident (contrainte de l'API, invariant caché).
- **Pas d'emoji dans les fichiers source**, sauf demande explicite.

---

## 4. Quand demander confirmation

- Modifier `project.pbxproj` à la main (préférer Xcode ou ses outils).
- Ajouter une dépendance externe (SPM) : l'app est volontairement sans dépendances.
- Changer les entitlements, le sandbox ou le bundle ID (accordé le 10/10/2026 pour `ENABLE_USER_SELECTED_FILES = readwrite`, qui sert à enregistrer les artefacts).
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
