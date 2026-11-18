# Plug-in Soulseek : architecture et mesures (`SLSK-15`)

## 1. Architecture réseau portable (`CSockets` + `CZlib`)

- **Transport TCP asynchrone (`Sources/CSockets/`)** : réacteur unique à un thread (`poll()` sur macOS/Linux, `WSAPoll()` sur Windows) réveillé par self-pipe (POSIX) ou paire loopback (Windows), couplé à un worker de résolution DNS. Aucun timer ni boucle d'attente active au repos.
- **Compression zlib (`Sources/CZlib/`)** : `miniz 3.0.2` vendored (SHA256 `ada38db0b703a56d3dd6d57bf84a9c5d664921d870d8fea4db153979fb5332c5`), compilé à l'identique sur macOS, Windows et Linux static musl.
- **Protocole (`Plug-ins/Soulseek/Sources/SoulseekPlugin/`)** : codecs binaires Soulseek (obfuscation, sérialisation d'écriture séquentielle par connexion via `StreamWriteSerializer`), recherche à sortie anticipée dès qu'un FLAC avec créneau libre ou `>= 5` candidats acceptés arrivent, et téléchargements/envois par blocs séquentiels de 256 Kio avec reprise `.part`.

---

## 2. Mesure de `searchWindowSeconds` (`SLSK-15`)

Script reproductible : [`Tools/SoulseekBench/run.sh`](../../Tools/SoulseekBench/run.sh) ([`bench.py`](../../Tools/SoulseekBench/bench.py)).

- **Échantillon** : 50 morceaux réels (genres variés : pop, hip-hop, rock, électronique, soul, jazz, francophone, classique/BO).
- **Protocole de mesure** : exécution hors app via JSON-RPC (`resolver/search`), 2 requêtes concurrentes espacées de `2,5 s` (`--pace 2.5`) pour éviter le rate-limit serveur (`server.slsknet.org:2242`), identité automatique éphémère par fenêtre.
- **Moment de mesure 1** : `2026-11-16` de `06:52` à `07:13 UTC` (`01:52–02:13 EST`).

| Fenêtre (`searchWindowSeconds`) | Morceaux trouvés | Taux trouvé | FLAC libre-créneau | Médiane 1er candidat accepté | P90 1er candidat accepté | Temps total moyen (`avg_wall_ms`) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `4 s` | 50 / 50 | `100,0 %` | 50 / 50 | `5 934 ms` | `13 789 ms` | `8 006 ms` |
| `6 s` | 50 / 50 | `100,0 %` | 50 / 50 | `5 359 ms` | `14 032 ms` | `8 628 ms` |
| `8 s` | 50 / 50 | `100,0 %` | 50 / 50 | `4 933 ms` | `15 680 ms` | `9 276 ms` |
| `12 s` | 50 / 50 | `100,0 %` | 50 / 50 | `4 614 ms` | `17 857 ms` | `9 692 ms` |

### Analyse et réglage retenu

- Grâce à la sortie anticipée (dès qu'un candidat sans file ou un quorum suffisant arrive), augmenter `searchWindowSeconds` de `8 s` à `12 s` n'alourdit le temps moyen que de `+416 ms` (`9 276 ms` → `9 692 ms`), mais étend l'attente en P90 sur les recherches lentes sans améliorer le taux de succès déjà à `100 %`.
- **`8 s`** est conservé comme valeur par défaut dans [`Plug-ins/Soulseek/plugin.json`](../../Plug-ins/Soulseek/plugin.json) : il offre un bon compromis entre latence bornée et collecte des pairs à réponse tardive.
- *Note* : conformément à la spec, une seconde passe à une autre tranche horaire (heure de pointe Europe / Amérique du Nord) reste recommandée avec `./Tools/SoulseekBench/run.sh --pace 2.5`.
