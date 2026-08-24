# Meeting — Specification produit et technique

Statut : implementation MVP en cours
Date : 2026-08-21

## 1. Resume du projet

Meeting est une application macOS personnelle qui capture une reunion depuis le microphone et le son du Mac, notamment Teams, Webex et les reunions ouvertes dans un navigateur. Elle transforme les voix en transcription francaise locale, affiche le texte pendant la reunion et le sauvegarde progressivement.

Le MVP conserve uniquement un journal audio local temporaire tant que le bloc correspondant n'est pas durablement transcrit. Les futurs traitements de resume, decisions, taches et publication dans Obsidian seront livres sous forme de packages separes utilisant Codex en mode headless et des skills dedies.

## 2. Objectifs

- Demarrer et arreter une transcription en quelques secondes.
- Capturer simultanement la voix de l'utilisateur et les participants distants.
- Produire une transcription francaise ou anglaise lisible avec horodatage et distinction des intervenants.
- Ne jamais envoyer l'audio ou la transcription vers un service de transcription distant.
- Preserver progressivement tous les segments deja finalises.
- Fonctionner confortablement sur un Mac Apple Silicon M2 avec 32 Go de memoire.
- Garder le coeur d'enregistrement independant des futurs traitements Codex et Obsidian.

## 3. Utilisateur cible

Le premier utilisateur est le proprietaire de l'application. Il utilise principalement un Mac M2 32 Go ou un Mac M5 64 Go et participe a des reunions francophones sur Teams, Webex ou dans un navigateur.

La distribution commerciale, la synchronisation entre appareils et le fonctionnement multi-utilisateur sont hors du MVP.

## 4. Decisions confirmees

- Plateforme : macOS sur Apple Silicon.
- Usage : personnel.
- Langue prioritaire : francais.
- Traitement : entierement local sur le Mac apres installation des modeles.
- Affichage : transcription pendant la reunion.
- Persistance : sauvegarde incrementale de la transcription.
- Audio : journal temporaire local, supprime apres transaction du transcript et repris apres interruption.
- Intervenants : labels distincts et renommables.
- Interface : noir et blanc, minimaliste.
- Navigation : fenetre principale et controle rapide dans la barre de menus.
- Post-traitements : packages ulterieurs, independants du MVP.

## 5. Hypotheses retenues

- Le minimum cible est macOS 15 afin d'utiliser les sorties audio systeme et microphone de ScreenCaptureKit dans une architecture native uniforme.
- Le parc cible utilise uniquement des puces Apple Silicon ; Intel est hors scope.
- Les modeles peuvent etre telecharges durant l'installation initiale, puis toute reunion peut etre transcrite sans reseau.
- Les intervenants sont d'abord nommes `Moi`, `Intervenant 1`, `Intervenant 2`, etc. L'utilisateur peut les renommer pendant ou apres la reunion.
- La premiere version prend en charge jusqu'a dix intervenants, avec une precision variable en cas de voix similaires ou de paroles simultanees.
- Aucun compte utilisateur n'est necessaire.

## 6. Parcours utilisateur principal

### Premier lancement

1. L'application explique clairement que les donnees restent sur le Mac.
2. Elle demande les autorisations macOS de capture d'ecran/audio et de microphone.
3. Elle telecharge et valide les modeles locaux necessaires.
4. Elle propose un test de dix secondes pour verifier le microphone et le son systeme.
5. Elle indique que l'utilisation d'un casque reduit les doublons et l'echo acoustique.

### Demarrer une reunion

1. L'utilisateur ouvre Meeting depuis la fenetre ou la barre de menus.
2. Il choisit la source : application de reunion detectee ou tout le son du Mac.
3. Il clique sur `Demarrer la transcription`.
4. L'application confirme que le microphone et le son systeme sont actifs.
5. Le texte apparait progressivement dans un flux continu, sans heure ni nom repetes.

### Pendant la reunion

1. Un indicateur textuel permanent signale que la transcription est active.
2. La segmentation technique reste invisible ; un curseur discret matérialise l'ecriture en direct.
3. Chaque segment finalise est ecrit immediatement dans le stockage local.
4. L'utilisateur peut renommer un intervenant sans interrompre la capture.
5. Il peut mettre en pause ou arreter la transcription.

### Apres la reunion

1. La reunion apparait dans l'historique.
2. L'utilisateur peut modifier son titre et les noms des intervenants.
3. Il peut corriger, copier, rechercher ou exporter le transcript.
4. Aucun fichier audio n'est expose ; les blocs temporaires deja transcrits sont supprimes automatiquement.

## 7. Ecrans

### Onboarding

- Explication de la confidentialite locale.
- Etat des autorisations.
- Etat et taille des modeles.
- Test microphone et son systeme.
- Message explicite lorsque l'application est prete hors ligne.

### Historique

- Liste chronologique des reunions.
- Titre, date, duree et nombre d'intervenants.
- Recherche plein texte.
- Bouton principal de nouvelle transcription.
- Etats vides et erreurs actionnables.

### Reunion en direct

- Duree et etat de capture.
- Etat distinct du microphone et du son systeme.
- Transcript continu defilant automatiquement, sans repetition des noms et horodatages.
- Indicateur textuel et curseur discrets pour matérialiser l'ecriture en direct.
- Segments, horodatages et intervenants conserves dans les donnees, mais affiches seulement apres consolidation.
- Commandes pause, reprise et arret.
- Alerte non bloquante en cas de retard de transcription.

### Detail d'une reunion

- Titre editable.
- Transcript complet.
- Edition et renommage des intervenants.
- Recherche interne.
- Copie et export en Markdown, texte et JSON.
- Suppression avec confirmation explicite.

### Reglages

- Source microphone par defaut.
- Source audio systeme par defaut.
- Choix du moteur et du modele lorsqu'une alternative est disponible.
- Emplacement des modeles et du stockage.
- Diagnostic local sans contenu de transcript dans les journaux.

### Barre de menus

- Demarrer une transcription.
- Mettre en pause, reprendre ou arreter.
- Afficher la duree courante.
- Ouvrir la reunion en direct.
- Indiquer clairement l'etat actif sans reposer uniquement sur une couleur.

## 8. Direction visuelle

- Palette : noir, blanc et nuances de gris.
- Typographie : police systeme San Francisco.
- Surfaces planes, bordures fines, peu d'ombres, aucun degrade decoratif.
- Densite moderee avec priorite au texte et aux controles essentiels.
- Icones SF Symbols simples.
- L'etat d'enregistrement utilise un libelle et une animation discrete ; la couleur seule ne porte jamais l'information.
- Mode clair prioritaire. Un mode sombre monochrome pourra suivre les reglages systeme.
- Navigation et commandes utilisables au clavier avec focus visible.

## 9. Architecture technique

### Stack

- Swift 6.
- SwiftUI pour l'interface et AppKit uniquement lorsque macOS l'exige.
- ScreenCaptureKit pour le son systeme et la sortie microphone.
- Core Audio / AVFoundation pour la normalisation des buffers audio.
- Core ML via un adaptateur de moteur local.
- SQLite comme source de verite des reunions et segments.
- Swift Package Manager pour les dependances et les modules internes.

### Modules

```text
MeetingApp
├── AppShell                 Fenetres, barre de menus, navigation
├── MeetingDomain            Entites et regles metier sans framework UI
├── CaptureCore              Protocoles des sources audio
├── ScreenCaptureAdapter     ScreenCaptureKit, permissions et selection
├── AudioJournal             WAV temporaires, reprise et acquittement
├── TranscriptionCore        Contrat interchangeable de transcription
├── FluidAudioAdapter        Implementation Core ML initiale
├── DiarizationCore          Attribution et renommage des intervenants
├── TranscriptStore          SQLite, migrations et transactions
├── TranscriptExport         Markdown, texte et JSON
├── Diagnostics              Metriques techniques sans contenu sensible
└── PackageContracts         Contrats des futurs packages, sans execution MVP
```

Les modules de domaine et les contrats ne dependent ni de SwiftUI, ni de ScreenCaptureKit, ni d'un moteur IA particulier.

### Capture audio

- Une sortie `system` recoit l'audio de Teams, Webex, du navigateur ou du Mac.
- Une sortie `microphone` recoit la voix locale.
- Les deux flux gardent une horloge monotone commune mais ne sont pas fusionnes avant l'attribution des intervenants.
- L'application elle-meme est exclue de la capture audio pour eviter les boucles.
- Les buffers sont convertis en mono Float32 16 kHz pour l'inference.
- Deux files independantes et sans perte silencieuse alimentent le journal microphone et systeme.
- Chaque fichier WAV est mis a jour et synchronise progressivement, puis ferme sur une pause apres 20 secondes ou force a 30 secondes.
- Un fichier n'est supprime qu'apres acquittement transactionnel du transcript correspondant.
- Un fichier partiel laisse par une fermeture forcee est repare et repris au prochain lancement.

La piste microphone est attribuee a `Moi`. La piste systeme reste melangee par Teams/Webex et necessite donc une diarisation locale pour distinguer les participants distants.

### Transcription et diarisation

Le moteur respecte deux interfaces :

```swift
protocol TranscriptionEngine {
    func prepare() async throws
    func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptToken]
}

protocol SpeakerDiarizationEngine {
    func prepare() async throws
    func process(_ chunk: AudioChunk) async throws -> SpeakerTimelineUpdate
}
```

Choix initial pour le prototype : FluidAudio, avec Nemotron multilingue Latin en streaming pour la previsualisation francaise/anglaise, Parakeet TDT v3 multilingue pour le transcript canonique et LS-EEND pour la diarisation. Ce choix n'est valide pour la production qu'apres benchmark sur le Mac M2 32 Go.

Un adaptateur WhisperKit `large-v3-turbo` doit rester possible si le benchmark francais montre une qualite nettement superieure. Le stockage et l'interface ne doivent connaitre aucun type propre a FluidAudio ou WhisperKit.

### Strategie incrementale robuste

- L'audio est journalise sur disque en continu, independamment de la vitesse des moteurs d'inference.
- Pendant la capture, Nemotron est le seul moteur d'inference actif et produit du texte toutes les 2,24 secondes environ, sans remise a zero aux frontieres des blocs WAV.
- Le texte cumulatif Nemotron est decoupe en segments `realtime` d'environ 20 secondes. Chaque segment possede un identifiant stable, un canal et un horodatage, puis est mis a jour sans doublon dans SQLite.
- Les segments `realtime` font partie du contrat de transcript et peuvent alimenter Codex avant la fin de la reunion ; ils ne sont pas de simples elements visuels.
- Les blocs WAV finalises attendent dans une file de metadonnees dedoublonnee ; leur contenu est deja durable et recuperable apres un crash.
- A l'arret, Nemotron est draine puis libere avant que Parakeet et LS-EEND consolident les blocs en segments canoniques. Les deux familles de modeles ne se disputent ainsi pas le Neural Engine.
- Le transcript direct reste visible pendant la consolidation. Il est supprime seulement apres la reussite de tous les blocs canoniques ; en cas d'echec, il reste la version exploitable de secours.
- Une pause peut fermer un bloc apres 20 secondes ; la duree maximale est 30 secondes.
- Le microphone et le son systeme ont des files et des fichiers distincts.
- LS-EEND diarise le bloc systeme complet ; les mots sont ensuite attribues par horodatage.
- Le moteur ne force pas le francais et ne rejette pas les passages anglais.
- L'identifiant du bloc rend la reprise idempotente et empeche les doublons apres un crash.

### Persistance

SQLite est la source de verite. Les ecritures sont transactionnelles et incrementales. `segments.source_kind` distingue explicitement `realtime` de `canonical`.

Entites minimales :

- `meetings` : identifiant, titre, dates, duree, etat, moteur et version du modele.
- `speakers` : identifiant stable dans la reunion, libelle automatique, nom utilisateur.
- `segments` : debut, fin, texte, intervenant, confiance, canal et identifiant du bloc audio.
- `processed_audio_blocks` : acquittement idempotent du bloc dans la meme transaction que ses segments.
- `events` : demarrage, pause, reprise, arret, erreurs non sensibles.
- `exports` : format, date et chemin du dernier export.

Tous les segments et profils issus d'un bloc sont inseres avec son acquittement dans une seule transaction. Le fichier est supprime seulement apres le commit.

### Reprise apres interruption

En cas de fermeture forcee, les WAV finalises et les fichiers partiels synchronises restent dans le journal local. Ils sont repares si necessaire, retranscrits au lancement suivant puis supprimes apres acquittement SQLite. La fenetre de perte visee est bornee par l'intervalle de synchronisation du fichier, actuellement une seconde.

## 10. Performance cible

La machine de reference est un Mac M2 avec 32 Go de memoire. Le Mac M5 64 Go sert de machine rapide secondaire et ne doit pas masquer une regression sur M2.

Cibles MVP :

- Retard median du texte final inferieur a 25 secondes.
- Retard au 95e percentile inferieur a 35 secondes.
- Memoire residente de l'application inferieure a 5 Go pendant une reunion longue.
- Aucun accroissement non borne de la memoire sur une reunion de deux heures.
- Interface fluide pendant l'inference.
- Mode degrade explicite si la file audio prend du retard.

## 11. Confidentialite et securite

- Aucune telemetrie contenant du texte, de l'audio ou des noms d'intervenants.
- Aucun appel reseau requis pendant une reunion une fois les modeles installes.
- Audio temporaire limite au journal local et jamais transmis ; suppression apres transcript durable.
- Journaux limites aux erreurs techniques, durees et identifiants non parlants.
- Base SQLite et exports stockes dans le repertoire utilisateur de l'application.
- Suppression d'une reunion uniquement apres confirmation.
- L'application rappelle que l'utilisateur doit informer les participants et respecter les regles applicables a l'enregistrement et a la transcription.

## 12. Exports MVP

- Texte brut UTF-8.
- Markdown avec titre, date, duree, intervenants et horodatages.
- JSON versionne pour les futurs packages.

Le schema JSON est stable, documente et porte un champ `schema_version`. La version 2 expose la source de chaque segment (`realtime` ou `canonical`) et ne contient jamais de references a un fichier audio.

## 13. Packages Codex et Obsidian — phase ulterieure

Les packages ne font pas partie du MVP d'enregistrement. Ils consomment uniquement un export de transcript versionne.

Packages envisages :

- `summary` : resume structure.
- `decisions` : decisions avec auteur et contexte quand ils sont identifiables.
- `tasks` : actions, responsables, echeances et niveau de confiance.
- `obsidian-publish` : proposition de note Markdown et de proprietes pour le vault.

Chaque package possede :

- un manifeste avec nom, version et capacites ;
- un schema d'entree ;
- un schema JSON de sortie ;
- un ou plusieurs skills versionnes ;
- un repertoire de travail isole ;
- un journal d'execution sans transcript complet ;
- une politique de permissions explicite.

Codex est invoque en mode non interactif avec `codex exec`. Il ecrit uniquement dans un espace de travail isole avec le niveau de sandbox minimal. La sortie finale est contrainte par un JSON Schema et validee avant import.

Le package Obsidian ne doit pas laisser Codex modifier librement tout le vault. Il produit d'abord une proposition structuree. Un adaptateur controle applique ensuite la creation ou la mise a jour par l'interface Obsidian, avec validation humaine pour les changements importants.

Obsidian reste un ensemble de notes Markdown structurees. Une vue Obsidian Bases pourra indexer les transcripts a partir de proprietes comme la date, les participants, le projet et le statut de traitement.

### Socle Codex implemente le 2026-08-21

- Runner `codex exec` ephemere dans un dossier temporaire avec sandbox en lecture seule.
- Export d'entree JSON versionne et sorties contraintes par un schema distinct pour titre, resume, questions et prochaines etapes.
- File SQLite durable pour reprendre les traitements automatiques apres une fermeture de l'application.
- Origine du titre conservee (`automatic`, `user`, `ai`) afin que Codex ne remplace jamais un titre saisi manuellement.
- Titre et resume lances en sequence a la fin d'une reunion ; questions et prochaines etapes disponibles a la demande.
- Resultats JSON conserves localement et rattaches a la reunion ; aucun audio n'est transmis.
- Reglages SwiftUI pour le chemin Codex, les automatismes et un raccourci global personnalisable.

## 14. Hors scope MVP

- Resume, decisions et taches automatiques.
- Ecriture automatique dans Obsidian.
- Synchronisation cloud.
- Application Windows, Linux, iPhone ou iPad.
- Support des Mac Intel.
- Bot rejoignant directement une reunion Teams ou Webex.
- Identification automatique du nom civil d'une voix.
- Conservation ou lecture de l'audio.
- Comptes, abonnement et distribution commerciale.

## 15. Criteres d'acceptation MVP

### Capture

- Une reunion Teams, Webex et navigateur peut etre transcrite avec le microphone et le son systeme.
- Les deux sources affichent un etat et un niveau independants.
- La capture n'enregistre pas les sons emis par Meeting lui-meme.
- Une interruption d'autorisation produit une erreur claire et n'endommage pas le transcript.

### Transcription

- Le francais est force ou privilegie par le moteur.
- Le texte apparait pendant la reunion et les revisions provisoires ne creent pas de doublons.
- `Moi` est distingue des participants distants.
- Les participants distants obtiennent des labels distincts dans les conditions normales de test.
- Les labels peuvent etre renommes et le changement s'applique a toute la reunion.

### Durabilite

- Un arret force apres au moins cinq minutes conserve tous les segments finalises.
- Apres un crash, les blocs audio non acquittes sont repris sans dupliquer les segments deja valides.
- Une reunion de deux heures ne provoque pas une croissance memoire non bornee.
- Aucun fichier audio ne reste apres le traitement reussi de tous les blocs ; un bloc en echec reste local pour reprise.

### Localite

- Apres installation des modeles, une reunion peut etre transcrite avec le reseau coupe.
- Un test reseau confirme l'absence de connexion sortante pendant la capture et l'inference.
- Les exports ne contiennent que le texte et les metadonnees attendues.

### Performance M2 32 Go

- Les objectifs de retard et de memoire de la section Performance sont mesures sur cette machine.
- Le premier texte partiel doit apparaitre apres environ 2,24 secondes d'audio, avec un objectif visible inferieur a 3 secondes hors chargement initial.
- Le moteur temps reel doit traiter chaque fenetre plus vite que sa duree et cohabiter avec le batch sans accumulation continue de la file audio.
- Un corpus francais representatif valide la ponctuation, les nombres, les noms propres et les changements d'intervenants.
- Le moteur final est choisi apres comparaison documentee de la precision, de la latence, de la memoire et de la licence.

## 16. Plan de livraison

### Etape 0 — Spike technique

- Capturer simultanement le son systeme et le microphone.
- Tester Teams, Webex et un navigateur.
- Comparer FluidAudio Parakeet v3 et WhisperKit sur un corpus francais.
- Tester la diarisation LS-EEND sur deux, quatre et huit voix.
- Mesurer sur M2 32 Go avant toute finition UI.

### Etape 1 — Coeur MVP

- Modules de domaine, capture et pipeline audio.
- Journal audio durable et transcription batch incrementale.
- Persistance SQLite transactionnelle.
- Reprise apres fermeture forcee.

### Etape 2 — Application utilisable

- Onboarding et autorisations.
- Fenetre principale, historique et vue en direct.
- Barre de menus.
- Edition et exports.
- Tests de confidentialite et performance.

### Etape 3 — Packages

- Contrat versionne de package.
- Runner Codex headless isole.
- Skills resume, decisions et taches.
- Proposition puis validation des mises a jour Obsidian.
- Vue Obsidian Bases des reunions traitees.

## 17. Checklist avant implementation

- [ ] Confirmer que le Mac M2 cible utilise macOS 15 ou plus recent.
- [ ] Constituer un corpus francais de reunion autorise pour le benchmark.
- [ ] Verifier les licences des modeles avant toute distribution.
- [ ] Valider ScreenCaptureKit avec Teams, Webex et les navigateurs cibles.
- [ ] Mesurer echo et doublons avec casque puis haut-parleurs.
- [ ] Choisir le moteur a partir des mesures M2, pas des performances M5.
- [ ] Versionner le schema JSON d'export avant les packages Codex.

## 18. Sources techniques

- Apple ScreenCaptureKit : <https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos>
- FluidAudio : <https://github.com/FluidInference/FluidAudio>
- Argmax OSS, WhisperKit et SpeakerKit : <https://github.com/argmaxinc/argmax-oss-swift>
- Documentation OpenAI, mode non interactif de Codex : <https://learn.chatgpt.com/docs/non-interactive-mode>
