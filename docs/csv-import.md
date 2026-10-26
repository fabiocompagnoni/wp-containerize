# Formato del CSV di import

`wp-containerize site import-csv <file.csv>` registra più siti in un colpo solo a partire
da un file CSV. Questo documento descrive il formato accettato.

## Formato del file
- Codifica UTF-8, con o senza BOM.
- Separatore `,` oppure `;`: viene riconosciuto in automatico analizzando le prime righe del
  file e scegliendo tra i due.
- La prima riga è l'intestazione con i nomi delle colonne.

## Colonne
| Colonna | Obbligatoria | Significato |
|---|---|---|
| `dominio` | sì | dominio del sito |
| `categoria` | no | `wordpress` oppure `statico` |
| `tipo` | no | `wordpress` oppure `static` |
| `cliente` | no | nome del cliente (etichetta libera) |
| `source_host` | no | host FTP/SFTP della sorgente |
| `php` | no | versione PHP di destinazione |
| `note` | no | note libere |

Le colonne non elencate vengono ignorate.

## Tipo e categoria
- Se è presente la colonna `tipo`, prevale su `categoria`.
- Valori ammessi di `tipo`: `wordpress`, `static`.
- Valori riconosciuti di `categoria`: `wordpress`, `statico`; `statico` corrisponde al tipo
  `static`. Le righe con altre categorie vengono saltate e segnalate.
- Il confronto di questi valori non distingue maiuscole e minuscole e ignora gli spazi
  (` WordPress ` equivale a `wordpress`).

## Opzioni
- `--map campo=colonna`: usa nomi di colonna diversi da quelli standard, anche per
  `dominio`. Si può ripetere, ad esempio `--map dominio=sito --map cliente=ragione_sociale`.
- `--categoria wordpress,statico`: filtra le righe per categoria. Il default è importare
  entrambe. `statico` corrisponde al tipo `static`.

## Esempio
```csv
dominio,categoria,cliente,source_host,php,note
esempio.it,wordpress,Cliente A,ftp.example.net,8.2,sito principale
example.com,statico,Cliente B,ftp.example.net,,pagina vetrina
```

Con il separatore `;` il file è equivalente:

```csv
dominio;categoria;cliente
esempio.it;wordpress;Cliente A
example.com;statico;Cliente B
```
