# Meeting

Application macOS locale de transcription de reunions francophones.

## Lancer l'application

Depuis la racine du projet :

```bash
./start.sh
```

Cette commande construit, signe et installe le bundle au chemin stable
`/Applications/Meeting.app`, puis ouvre l'application.

La commande equivalente detaillee reste :

```bash
./scripts/run-app.sh
```

Le script construit l'application avec une identite Developer ID stable, puis
l'installe et la lance depuis `/Applications/Meeting.app`. Ce chemin et cette
signature stables permettent a macOS de conserver les autorisations Microphone
et Enregistrement de l'ecran entre deux compilations.
Le bundle signe inclut aussi l'entitlement
`com.apple.security.device.audio-input`, requis par le hardened runtime pour
demander l'acces au microphone.

Pour installer sans lancer :

```bash
./scripts/install-app.sh
```

Le premier lancement telecharge les modeles de transcription et de diarisation
dans le cache local et affiche leur progression. Les lancements suivants les
reutilisent. Un cache de diarisation interrompu est detecte et retélécharge
automatiquement.

Pour conserver physiquement les modeles dans ce projet sans les publier dans
Git, executer une fois :

```bash
./scripts/install-local-models.sh
```

Le script deplace un cache FluidAudio existant vers
`.models/FluidAudio/Models`, puis relie le chemin standard de FluidAudio a ce
dossier. `.models/` est ignore par Git. Sur un nouveau Mac ou un nouveau clone,
le script cree le dossier et les modeles sont telecharges au premier lancement.

Pendant une reunion, Nemotron multilingue affiche une previsualisation locale
francaise ou anglaise environ toutes les 2,24 secondes. Ce texte en cours est
egalement un vrai transcript exploitable : il est decoupe en segments d'environ
20 secondes, horodate et mis a jour dans SQLite avec la source `realtime`.
Cette segmentation reste invisible pendant la capture : l'interface presente
un seul texte continu avec un curseur discret, sans repeter le nom de la source
ni l'horodatage. La vue structuree reapparait apres la consolidation finale.
Les boutons IA peuvent donc le consommer avant la fin de la reunion. Les memes
echantillons sont d'abord synchronises dans le journal WAV durable. Pendant la
capture, Nemotron reste le seul moteur d'inference actif afin de conserver une latence reguliere.
A l'arret, Nemotron libere le Neural Engine, puis Parakeet et LS-EEND consolident
les blocs de 20 a 30 secondes en segments `canonical`. Si toute la consolidation
reussit, ils remplacent atomiquement les segments directs. En cas d'echec, les
segments Nemotron restent disponibles. Une erreur de
previsualisation ne peut donc ni ralentir l'enregistrement ni perdre le contenu,
qui reste recuperable depuis le journal local.

Pour verifier les modeles independamment de l'interface :

```bash
./scripts/check-models.sh
```

## Empreintes vocales locales

Les profils sont crees automatiquement pendant les reunions a partir des
segments de parole exploitables. Seul leur centroide numerique CAM++ est
sauvegarde dans SQLite ; aucun audio d'enrolement n'est ecrit sur disque.

Pendant chaque reunion, les segments propres de tous les intervenants alimentent
automatiquement des profils `Voix 1`, `Voix 2`, etc. Ces centroïdes numeriques
sont compares aux profils des reunions precedentes. La fenetre `Voix connues`
permet de les renommer ou de les oublier ; un renommage actualise aussi le nom
affiche dans les anciens transcripts lies au meme profil.

Dans le transcript, le nom d'un interlocuteur est modifiable directement avec
l'icone crayon. Une signature connue est renommee dans toutes les reunions ; une
etiquette temporaire est renommee seulement dans la reunion courante.

Chaque reunion peut etre renommee, recevoir un contexte libre local ou etre
supprimee avec confirmation. Pendant la capture, deux journaux WAV temporaires
et separes enregistrent le microphone et le son du Mac. Ils sont fermes par
blocs de 20 a 30 secondes, transcrits en batch puis supprimes uniquement apres
la transaction SQLite. Un bloc interrompu est repris au lancement suivant.

Parakeet est utilise sans filtre de rejet anglais : les dialogues francais et
anglais passent par le meme chemin local. Le controle reel correspondant est :

```bash
./scripts/check-batch.sh
```

Le controle du chemin temps reel verifie qu'un texte partiel francais continue
d'arriver au-dela de 60 secondes, et qu'un texte anglais arrive aussi avant la
fermeture des flux :

```bash
./scripts/check-realtime.sh
```

## Intelligence artificielle avec Codex

La roue crantee ouvre les reglages IA : modele Codex, effort de raisonnement,
chemin de l'executable, raccourci global personnalisable et automatisations de
fin de reunion. Le raccourci par defaut est `Option + Commande + I`.

Deux traitements sont inscrits dans une file SQLite durable a la fin d'une
reunion : proposer un titre si le titre par defaut n'a jamais ete modifie, puis
generer un resume. Un chat integre a droite permet ensuite de discuter librement
avec le transcript selectionne. Ses raccourcis produisent un resume, des
prochaines etapes, des questions a poser ou les problemes restant a resoudre.

Chaque traitement transmet uniquement l'export JSON versionne du transcript a
`codex exec`, dans un dossier temporaire et une sandbox en lecture seule. La
sortie est contrainte par un schema JSON, validee, puis conservee localement
avec la reunion. L'historique du chat est lui aussi stocke dans SQLite. Aucun
audio n'est transmis.

Controle reel du runner sur un transcript synthetique :

```bash
./scripts/check-ai.sh
```

## Spike de diagnostic

Le premier spike prouve la capture separee du microphone et du son systeme sans enregistrer d'audio sur disque.

```bash
./scripts/run-spike.sh
```

Voir :

- [SPEC.md](SPEC.md) pour la specification du produit ;
- [SPIKE.md](SPIKE.md) pour le protocole de test M5 et M2.
