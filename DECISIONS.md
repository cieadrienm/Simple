# DECISIONS

Journal des choix structurants. Chaque entrée : le choix, pourquoi, et ce qu'on a écarté.
D1–D4 ont été validées par Adrien (1ᵉʳ octobre 2026) ; les suivantes ont été prises en autonomie et sont réversibles.

## Cadrage (validé)

- **D1 — Dépôt privé `cieadrienm/Simple`, miroir Gitea `amcb/simple`** (deux URLs de push sur `origin`, comme OSCScore). L'ancien `origin` (Syphon/Simple) est devenu `upstream`.
- **D2 — Modernisation complète avec passage à Metal** (étape 1), plutôt qu'une simple réparation du build en gardant OpenGL.
- **D3 — L'enregistreur vit dans Simple Client** ; Simple Server reste la source de test. Écarté : une troisième app.
- **D4 — Vidéo seule.** L'audio de Syphon Recorder n'est pas repris.

## Étape 1 — Metal

- **D5 — macOS 13 minimum, binaires universels, plus d'OpenGL ni d'en-têtes précompilés.** Le projet ne compilait plus (cible 10.9, `VALID_ARCHS` sans arm64).
- **D6 — Framework Syphon suivi sur la tête de `Syphon/Syphon-Framework`**, qui apporte `SyphonMetalClient` / `SyphonMetalServer`.
- **D7 — Une image Syphon a sa première ligne en bas** (convention OpenGL, vérifiée avec `Tools/gl-server`). Simple Server publie donc avec `flipped:YES`, et tout ce qui affiche ou enregistre une image Syphon la retourne.
- **D8 — Simple Server rend depuis un `CVDisplayLink`**, pas depuis sa vue : il continue à publier fenêtre masquée. Sa mire a une barre qui balaie l'image et un repère en haut à gauche, pour voir les images perdues et le sens.
- **D9 — Vérifier sans l'écran.** Adrien a refusé l'accès à l'écran : `Tools/` contient de quoi lire une image Syphon, rendre la vue hors écran, piloter le popover de réglages, relire un film. Ce qui ne peut pas se vérifier ainsi (aspect de la barre d'outils, ouverture du popover, quitter par le menu) est à regarder à la main.

## Étape 2 — Enregistreur

- **D10 — Tout en Objective-C dans l'app.** Le cœur (`Recorder/`) ne dépend pas de Syphon : il est compilé dans l'app et, par `Package.swift`, dans une bibliothèque testée par `swift test`. Écarté : du Swift dans la cible Xcode (cible mixte), une cible de tests Xcode (à écrire à la main dans le `.pbxproj`).
- **D11 — `OSCQueryServer` vient d'eMotion, inchangé**, pour que les deux restent comparables. OSCScore n'a qu'un client OSCQuery.
- **D12 — Une seule table de paramètres** (`RecorderController`) alimente la fenêtre, l'OSC et OSCQuery. Le MCP lit par OSCQuery et écrit par OSC : il n'y a pas d'autre API.
- **D13 — Ports 9230 (OSC, UDP) et 9231 (OSCQuery, HTTP)**, le premier libre à partir de là ; `SIMPLE_OSC_PORT` et `SIMPLE_OSCQUERY_PORT` pour une seconde instance. Pas de `SO_REUSEPORT` : un port pris doit échouer, sinon une seule des deux instances reçoit.
- **D14 — Identifiant `net.am-cb.simple-client`**, signature par `Scripts/bundle.sh` avec l'identité Apple Development : l'ancien identifiant est celui de l'app installée dans `/Applications/Syphon Simple Apps`, et l'autorisation « Réseau local » en dépend.
- **D15 — Codecs H.264, HEVC, ProRes 422, ProRes 4444 (alpha), toujours en `.mov`.** Pas de HAP ni de Photo JPEG (dépendances externes).
- **D16 — L'image est retournée et mise à l'échelle sur le GPU** dans les tampons de l'encodeur (`CVMetalTextureCache`), hors du thread principal. Taille 0 = celle de la source ; sinon ajustement sans déformation, bandes noires (transparentes en ProRes 4444).
- **D17 — Fps maximum : des créneaux centrés sur leur instant.** La première image arrivée dans un créneau est gardée. Centrés et non alignés : une source à la cadence du maximum garde toutes ses images malgré la gigue. Conséquence : une seconde à 60 i/s plafonnée à 30 donne 31 images (les créneaux 0 à 30).
- **D18 — L'encodeur du film est créé au démarrage quand la taille est connue** (réglages, ou dernière image vue de la source), sinon à la première image. Le créer à la première image faisait perdre les ~8 suivantes à 120 i/s. Une taille impossible échoue au démarrage.
- **D19 — Encodeur en retard : une image acceptée attend jusqu'à 0,5 s, et au-delà de 3 en attente les nouvelles sont écartées à l'arrivée** (comptées dans `/status/dropped`). Jamais de mémoire qui gonfle, jamais d'attente côté source.
- **D20 — Accepté : sous cette contre-pression, une image en attente est copiée depuis la surface Syphon vivante, donc jusqu'à 0,5 s après son horodatage.** Cela n'arrive que quand des images sont déjà perdues. Copier à l'arrivée demanderait de toucher aux tampons de l'encodeur depuis le thread de Syphon ; à reprendre si un codec/taille ne tient pas le temps réel.
- **D21 — Un film qui a des images n'est jamais supprimé.** Une image dont le tampon ne peut pas être alloué est perdue, le film continue ; après un échec (disque plein) le fichier reste, lisible jusqu'à son dernier fragment (fragments de 10 s).
- **D22 — Deux erreurs distinctes.** `/status/error` : la dernière, quelle qu'elle soit (message refusé compris), affichée 6 s. `/status/failure` : pourquoi le dernier enregistrement s'est arrêté, affichée jusqu'au suivant. Sans cela un mauvais message OSC passait pour un enregistrement raté.
- **D23 — La source choisie est retrouvée.** Si son application quitte, la sélection retombe sur une autre ; quand elle revient, elle est resélectionnée. Écarté : continuer sur la source de repli.
- **D24 — `/source ""` est refusé.** Le menu garde toujours une sélection (c'est ce qui sélectionne le premier serveur qui apparaît), et rien n'a besoin d'« aucune source ».
- **D25 — Le nom du film ne peut pas sortir du dossier** (`/` et `:` remplacés), et un fichier existant n'est jamais écrasé (` 2`, ` 3`…).
- **D26 — `SIGTERM` quitte comme le menu** : le film est finalisé. C'est aussi le seul chemin de `applicationShouldTerminate:` testable sans écran.
- **D27 — Un enregistrement ne peut pas démarrer tant que le film précédent n'est pas fini.**
- **D28 — Le MCP répond par une erreur** à un démarrage alors qu'on enregistre, à un arrêt alors qu'on n'enregistre pas, et à un réglage que l'app n'a pas pris tel quel : un agent doit savoir que rien ne s'est passé.
- **D29 — OSC sans authentification, sur toutes les interfaces.** C'est ce qu'est l'OSC ; le README le dit.
- **D30 — Laissés tels quels** : alpha ProRes 4444 écrit comme reçu (sans marquage prémultiplié), couleurs marquées BT.709 sans conversion, pas d'alerte d'espace disque, pas de protection contre une mise en veille forcée.

- **D31 — Barre d'outils en fenêtre étroite.** La fenêtre garde la forme de l'image, donc peut être étroite (source carrée ou verticale). Le menu des sources rétrécit jusqu'à 80 points avant d'être masqué ; lui et le bouton d'enregistrement sont masqués en dernier, l'état en premier. Dans le menu de débordement, « Source » est un sous-menu et « Recording Settings… » ouvre le popover sous la barre. `minSize`/`maxSize` de l'élément (dépréciés) sont utilisés : la barre d'outils ne comprime pas une vue par ses contraintes.

## Constaté

- ProRes 4444 échoue (« encode failed », -12912) sur du bruit dont l'alpha est aléatoire aussi ; le bruit opaque et une couleur unie à alpha aléatoire passent. Aucune image réelle n'est ainsi ; l'échec est signalé.
- L'annonce Bonjour de l'app **signée** n'a pas été confirmée (le build Debug signé ad hoc l'est en 0,7 s) : sans doute l'autorisation « Réseau local », qu'Adrien doit accorder.

## Remis à plus tard (relecture du 1ᵉʳ octobre 2026)

- MCP : plante sur un nombre hors des bornes d'un entier ; lit un état vide si le thread principal de l'app est occupé plus d'une seconde ; subtilités de protocole (version, outil inconnu, ligne illisible).
- `/folder ""` accepté puis « dossier (null) » au démarrage ; `/record NaN` démarre ; pas de message si Metal est indisponible.
- Popover : réécrit tous les champs au moindre changement (une saisie en cours est perdue) ; « OSCQuery on port 0 » si seul OSCQuery n'a pas démarré.
- `MovieRecorder` : `dispatch_group_enter` après le verrou (au pire une image comptée perdue) ; un tampon de commandes nul bloquerait l'arrêt.
- Récepteur OSC en IPv4 seulement ; un message à tableaux (`[` `]`) est ignoré.
- `Scripts/bundle.sh` : `INSTALL=1` remplace une app en cours d'exécution ; pas de `codesign --verify` ; pas de notarisation.
- Le minuteur de rafraîchissement (4 Hz) tourne en permanence ; l'aperçu de Simple Server a une image de retard.
