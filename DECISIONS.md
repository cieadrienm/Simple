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
- **D32 — Qu'on enregistre doit sauter aux yeux, quel que soit ce qui a lancé l'enregistrement.** Le bouton reste enfoncé et devient un carré blanc sur disque rouge (avant : un anneau rouge qui devenait un disque rouge, presque pareil), et le titre de la fenêtre devient « ● 00:13:45 — Simple Client ». Le chrono de la zone d'état ne suffisait pas : elle est masquée en fenêtre étroite. Constaté le 2 octobre : Adrien a lancé un enregistrement en OSC, n'a rien vu changer, et l'a laissé tourner 14 minutes en croyant que l'OSC ne marchait pas.
- **D33 — Un message OSC vers une adresse inconnue, ou en lecture seule, est signalé** (`/status/error`, zone d'état, titre de la fenêtre), au lieu d'être ignoré. Une adresse pas tout à fait juste est la cause habituelle d'un « il ne se passe rien ». Constaté le 2 octobre : dans OSCScore, un drapeau vide sur une piste dont l'adresse est écrite `/record <0>` envoie l'adresse littérale `/record <0>` sans argument (les arguments entre chevrons ne sont lus que dans le texte du drapeau), et l'enregistrement ne s'arrêtait pas, sans rien dire.
- **D34 — Les erreurs s'affichent aussi dans le titre de la fenêtre** (« ⚠ … ») : 6 s pour un message refusé, jusqu'à l'enregistrement suivant pour un enregistrement qui a échoué. La zone d'état est masquée en fenêtre étroite.

## Simple Recorder, partie 1 (3 octobre 2026)

Design : `docs/superpowers/specs/2026-10-03-simple-recorder-design.md`. Validé par Adrien : sortie au choix à chaque prise, dispositions prêtes, son du NDI, renommage. Le reste ci-dessous a été tranché en autonomie.

- **D35 — La fenêtre est en SwiftUI, l'app est construite par SwiftPM** (`App/`), comme OSCScore ; le cœur reste en Objective-C. Syphon arrive à SwiftPM en xcframework (`Scripts/syphon.sh`). Revient sur D10. Simple Client et son projet Xcode sont supprimés ; Simple Server garde le sien.
- **D36 — macOS 14 minimum, identifiant `net.am-cb.simple-recorder`.** Les réglages de Simple Client sont recopiés une fois, depuis le domaine enregistré (pas via `object(forKey:)`, qui répond aussi les valeurs par défaut enregistrées par le contrôleur).
- **D37 — Des places** : `/source/1` à `/source/8`, `/source` étant la première. Une source est connue par son titre ; seules les sources cochées sont connectées. Pour cocher une source il faut qu'elle soit là ; seules les places restaurées au lancement peuvent attendre la leur.
- **D38 — Les places sont verrouillées pendant un enregistrement.** Écarté : modifier une prise en cours.
- **D39 — Une prise, une horloge.** Tous les films partent du même instant zéro ; chacun commence par un vide jusqu'à sa première image. Une source qui n'envoie rien n'a pas de film, et ce n'est pas un échec ; une prise sans aucune image en est un.
- **D40 — Noms** : `<nom>.mov` pour une source, `<nom> — <source>.mov` pour plusieurs ; sans nom, « Simple Recorder » et la date ; le même numéro pour tous les films d'une prise si l'un des noms existe.
- **D41 — Un film qui échoue n'arrête pas les autres** ; `/status/failure` dit lequel. La prise ne s'arrête d'elle-même que si tous ont échoué.
- **D42 — Une source dont l'application a été tuée est retrouvée quand elle revient.** Quand une application est tuée, Syphon garde l'entrée de son serveur pour toujours et en ajoute une seconde quand elle est relancée ; le client déjà connecté reste « valide » et muet. Mais un client **neuf** créé pour une entrée morte est invalide d'emblée (vérifié par expérience ; un serveur suspendu, lui, reste valide). Donc : une source muette depuis 2 s est interrogée (`FrameSource.alive`, qui crée un client d'essai) ; morte, on la lâche et on prend la première entrée vivante du même titre ; vivante, on la garde — une scène immobile ne publie rien, et une autre entrée du même titre serait une autre image. Interroger crée un client dans l'application source : une source qui reste muette est donc interrogée de moins en moins souvent (2 s, puis 4, 8… jusqu'à 30 s). Écarté après relecture : faire le tour des entrées de même titre au bout de 2 s de silence, qui pouvait basculer d'une vue d'eMotion à l'autre dans le même film.
- **D43 — Le contrôleur annonce ses changements par une notification** (aussi quatre fois par seconde), que le modèle SwiftUI relit en entier. Écarté : du KVO sur chaque propriété de chaque place.
- **D44 — Les vues se vérifient par rendu hors écran** (`build/views/*.png`, par `swift test`). Les tuiles Metal y sont noires : leur contenu se vérifie par les films.
- **D45 — Le MCP vérifie les titres avant de changer les sources** : un titre inconnu ne doit pas laisser les places vides. Il ne propose plus `width`/`height` tant que le film assemblé n'existe pas.
- **D46 — Ce qui a fait échouer un film reste affiché pendant que la prise continue** (à côté du chrono et dans la barre d'état), pas seulement après. Un film qui échoue au moment d'être finalisé est signalé lui aussi (`/status/failure`).
- **D47 — Une place qui attend sa source peut être renommée par le même titre** : un preset OSC renvoyé avant que l'application source soit lancée n'est pas une erreur.

## Constaté

- ProRes 4444 échoue (« encode failed », -12912) sur du bruit dont l'alpha est aléatoire aussi ; le bruit opaque et une couleur unie à alpha aléatoire passent. Aucune image réelle n'est ainsi ; l'échec est signalé.
- Huit sources 960 × 680 à 120 i/s enregistrées à 60 i/s en H.264 pendant 20 s : 1197 images par film, aucune perdue, 39 % d'un cœur.
- Le zéro d'une prise précède d'environ 0,1 s la première image possible : le temps de créer les encodeurs. Les films restent alignés entre eux.
- L'annonce Bonjour de l'app **signée** n'a pas été confirmée (le build Debug signé ad hoc l'est en 0,7 s) : sans doute l'autorisation « Réseau local », qu'Adrien doit accorder.

## Remis à plus tard (relecture du 1ᵉʳ octobre 2026)

- MCP : plante sur un nombre hors des bornes d'un entier ; lit un état vide si le thread principal de l'app est occupé plus d'une seconde ; subtilités de protocole (version, outil inconnu, ligne illisible).
- `/folder ""` accepté puis « dossier (null) » au démarrage ; `/record NaN` démarre ; pas de message si Metal est indisponible.
- Popover : réécrit tous les champs au moindre changement (une saisie en cours est perdue) ; « OSCQuery on port 0 » si seul OSCQuery n'a pas démarré.
- `MovieRecorder` : `dispatch_group_enter` après le verrou (au pire une image comptée perdue) ; un tampon de commandes nul bloquerait l'arrêt.
- (relecture du 3 octobre) Deux titres qui ne diffèrent que par `/`, `:` ou `-` donnent le même nom de fichier ; un démarrage qui échoue à mi-chemin efface l'état de la prise précédente ; le MCP vide toujours les places avant de les remplir, même identiques, et ne voit pas une erreur dont le texte est le même que la précédente ; l'espace disque est lu sur le thread principal (volume réseau lent) ; chaque tuile du moniteur compile son shader ; le champ bitrate ne valide qu'à Entrée ; ⌘W pendant une prise la termine et quitte ; `bundle.sh` ne vérifie la signature que de Simple Recorder.
- Récepteur OSC en IPv4 seulement ; un message à tableaux (`[` `]`) est ignoré.
- `Scripts/bundle.sh` : `INSTALL=1` remplace une app en cours d'exécution ; pas de `codesign --verify` ; pas de notarisation.
- Le minuteur de rafraîchissement (4 Hz) tourne en permanence ; l'aperçu de Simple Server a une image de retard.
