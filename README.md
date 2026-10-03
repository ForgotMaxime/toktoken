# toktoken

Script PowerShell qui installe et configure une stack de **réduction de tokens pour OpenCode**, pour usage personnel en vibe coding.

Cinq dépôts GitHub à plus de 1 000 étoiles ont été étudiés. Deux se font concurrence et deux autres se recouvrent : ce script en installe **trois**, après avoir tranché. Les raisons sont détaillées plus bas.

---

## Ce qui est installé

| Outil | Paquet | Stars | Surface OpenCode |
|---|---|---:|---|
| [code-review-graph](https://github.com/tirth8205/code-review-graph) | `code-review-graph` (PyPI) | 31 898 | MCP `serve --auto-watch` |
| [headroom](https://github.com/headroomlabs-ai/headroom) | `headroom-ai[mcp,proxy]` (PyPI) | 74 313 | MCP `headroom mcp serve` |
| [repomix](https://github.com/yamadashy/repomix) | `repomix` (npm) | 28 659 | MCP `repomix --mcp` |

Chaque outil Python part dans **son propre venv** sous `~/.config/opencode/token-stack/venvs/`, repomix dans un préfixe npm local. Rien ne touche au Python système.

---

## Les deux choix

### code-review-graph plutôt que graphify

Les deux font un graphe de code par tree-sitter. Ce n'est pas le nombre d'étoiles qui tranche (123k contre 32k), c'est la **fraîcheur** :

- `code-review-graph` met à jour **incrémentalement par hash SHA-256**. Le graphe ne peut pas périmer pendant que tu codes.
- `graphify` exige de relancer `graphify extract .` à la main. Un graphe qu'on oublie de regénérer est pire que pas de graphe.

Second argument, sur la qualité des chiffres annoncés :

- code-review-graph revendique **~65× de réduction médiane**, mesuré sur 6 repos réels avec SHA pinnés, graine fixe pour Leiden, embeddings déterministes, et une recette de reproduction documentée.
- graphify annonce **71,5×**, mais sur un corpus de démonstration de 52 fichiers (3 repos GPT + 5 attention papers + 4 diagrammes). Ce n'est pas un benchmark de code réel.

`code-review-graph` a aussi un support OpenCode natif (`install --platform opencode`) et des outils taillés pour la boucle vibe coding : `get_minimal_context` (~100 tokens), `get_impact_radius`, `detect_changes`.

### headroom plutôt que token-optimizer

Les deux promettent de compresser la sortie des outils. Problème : **les docs de token-optimizer listent ses fonctions de compression comme non portées sur OpenCode** — notamment *bash output compression*, qui exige un hook de mutation d'entrée d'outil qu'OpenCode n'expose pas. Non portés aussi : quality nudges, loop detection, Context Intel Promotion, Memory Health audit. Ses propres docs ajoutent « treat the not-ported list as the conservative position ».

Sur cette plateforme, token-optimizer est donc un **sous-ensemble strict** de headroom, précisément sur le terrain où il prétend le dépasser.

S'y ajoutent :

- **headroom est Apache-2.0**, token-optimizer est **PolyForm-Noncommercial-1.0.0**.
- Le *live-zone compression* de headroom ne compresse que les nouveaux octets et laisse le préfixe figé byte-identique, donc **le cache KV du provider survit**. C'est le bon design pour les longues sessions où le coût se compose.

Si un jour la compaction devient ton point de douleur, la levier natif d'opencode est `"compaction": { "tail_turns": 15 }`. token-optimizer reste installable seule via `-Include token-opt` si tu veux son dashboard et son scoring de qualité.

### Pourquoi repomix neconflictue pas

repomix est **à la demande**, pas toujours actif : tu le lances quand tu veux packer un repo. Il complète code-review-graph (qui sert le graphe du dossier courant) au lieu de le concurrencer. Utile pour un dépôt distant ou dans lequel tu ne travailles pas.

---

## Prérequis

- Windows PowerShell 5.1+
- Python **≥ 3.10** (le script cherche `python`, `python3` ou `py` et refuse une version trop ancienne)
- Node.js + npm

---

## Usage

```powershell
.\setup-opencode-token-stack.ps1                          # les 3 outils par défaut
.\setup-opencode-token-stack.ps1 -Include crg,headroom    # sous-ensemble
.\setup-opencode-token-stack.ps1 -DryRun                  # affiche, ne touche à rien
.\setup-opencode-token-stack.ps1 -SkipInstall             # écrit la config, n'installe rien
.\setup-opencode-token-stack.ps1 -Include graphify        # option écartée, mais disponible
```

Passe par `.\` ou `-Command`, **pas** par `powershell -File` : ce dernier ne découpe pas les valeurs séparées par des virgules pour un paramètre de type tableau.

Le script est **idempotent** : le relancer ne duplique ni les serveurs MCP ni les plugins.

---

## Après installation

```powershell
code-review-graph build     # une fois par projet où tu codes
```

Sans ça, le serveur MCP tourne à vide : l'entrée globale sert le graphe du dossier courant d'opencode.

Puis **redémarre opencode** — la config n'est pas rechargée à chaud — et vérifie avec `/mcp`.

---

## Ce qui est écrit où

```
~/.config/opencode/opencode.jsonc                        <- config globale, fusionnée
~/.config/opencode/opencode.jsonc.bak-<horodatage>       <- backup à chaque run
~/.config/opencode/token-stack/venvs/code-review-graph/  <- venv isolé
~/.config/opencode/token-stack/venvs/headroom/
~/.config/opencode/token-stack/node/                     <- repomix
```

La config est fusionnée en JSON strict, donc **les commentaires de ton `opencode.jsonc` sont retirés** au premier run (les clés et valeurs sont préservées). C'est pour ça que le backup existe.

---

## Désinstaller

```powershell
Remove-Item -Recurse -Force ~/.config/opencode/token-stack
```

Puis supprime le bloc `mcp` de `~/.config/opencode/opencode.jsonc`, ou restaure le backup le plus récent.

---

## Détails d'implémentation

Le script fait deux choses qu'un `npm install -g` ne ferait pas bien :

**Il n'appelle pas `code-review-graph install`.** Cet installeur écrit un `opencode.jsonc` **scope-projet dans le répertoire courant**, épingle un chemin python absolu, crée un `.gitignore`, et pose une question interactive. Le script écrit lui-même la config globale à la place.

**Il fusionne du vrai JSONC.** `opencode.jsonc` est parse avec un machine à états qui distingue `//` et `/* */` des occurrences à l'intérieur des chaînes — sans quoi une URL comme `https://opencode.ai/config.json` serait tronquée. Les virgules traînantes sont retirées en second recours. Si le fichier est irrécupérable, le script s'arrête avec un message au lieu d'écraser.

Vérifié de bout en bout : les 3 serveurs MCP répondent à un `initialize` JSON-RPC avec les tableaux `command` exacts générés par le script.

---

## Limites connues

- **Windows uniquement.** Chemins `Scripts\` codés en dur, `python -m venv`, détection via `$env:USERPROFILE`.
- **`--auto-watch` sur code-review-graph** garde un watcher de fichiers ouvert par session opencode. C'est délibéré : c'est précisément ce qui empêche le graphe de périmer. Enlève `, "--auto-watch"` du tableau `command` si tu préfères gérer la fraîcheur à la main.
- **Le F1 de détection d'impact de code-review-graph vaut 0,69** selon son propre benchmark — le recall est 1,0 mais c'est une borne circulaire, pas une réalité. Prévois ~31 % d'impact manqué sur `get_impact_radius`.
- Les chiffres ~65× et ~71,5× sont des benchmarks des projets eux-mêmes, pas des mesures indépendantes.

---

## Licence

Aucun fichier de licence pour l'instant. Le script est de toi ; les outils installés gardent leurs propres licences (Apache-2.0, MIT, PolyForm-Noncommercial pour token-optimizer si tu l'ajoutes).
