# Formato del CSV di import

`wp-containerize site import-csv <file.csv>` registra più siti in un colpo solo a partire
da un file CSV. Questo documento descrive il formato accettato e i casi limite.

## Formato del file
- Codifica UTF-8, con o senza BOM.
- La prima riga è l'intestazione con i nomi delle colonne.
- Separatore `,` oppure `;`: si analizzano i primi 4 KB del file con `csv.Sniffer`,
  limitato a questi due caratteri. Se lo sniffing fallisce o il file ha una sola colonna,
  si usa `,`.
- I nomi di colonna si confrontano ignorando maiuscole e spazi.

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

## Tipo della riga
Il tipo di ogni riga si risolve così:
1. Se `tipo` ha un valore, prevale su `categoria`. Valori ammessi: `wordpress`, `static`.
   Un valore non ammesso è un errore di riga (vedi sotto).
2. Se `tipo` è vuoto o assente, si guarda `categoria`. Valori riconosciuti: `wordpress`,
   `statico` (che dà il tipo `static`). Con un'altra categoria la riga viene saltata e
   segnalata come "categoria non gestita"; non è un errore.
3. Se la riga non ha né `tipo` né `categoria` (colonne assenti o vuote), il tipo è
   `wordpress`.

Il confronto dei valori non distingue maiuscole e minuscole e ignora gli spazi
(` WordPress ` equivale a `wordpress`).

## Errori di riga e codice di uscita
Qualunque errore di riga (dominio vuoto o non valido, `tipo` non ammesso) salta la riga, la
segnala con il suo numero e fa uscire il comando con codice 1; le righe valide vengono
comunque importate. Le righe saltate senza errore (categoria non gestita, dominio duplicato,
manifest già esistente) vengono segnalate ma non cambiano il codice di uscita.

## Dominio
- Prima della validazione il dominio viene normalizzato: spazi rimossi, minuscolo, punto
  finale tolto, IDN convertito.
- Un dominio vuoto o non valido è un errore di riga (vedi sopra).
- Se un dominio compare più volte nel file vale la prima occorrenza; le successive vengono
  segnalate e saltate.
- Un dominio che ha già un manifest viene saltato e segnalato; non è un errore.

## Opzioni
- `--map campo=colonna`: usa nomi di colonna diversi da quelli standard. `campo` è uno dei
  nomi standard (`dominio`, `categoria`, `tipo`, `cliente`, `source_host`, `php`, `note`);
  un campo sconosciuto è un errore d'uso (exit 2). Se la colonna mappata non esiste
  nell'intestazione, l'intero file viene rifiutato (exit 1). L'opzione si può ripetere, ad
  esempio `--map dominio=sito --map cliente=ragione_sociale`.
- `--categoria wordpress,statico`: filtra le righe sul tipo risolto. Accetta `wordpress`,
  `statico` e anche `static`, che sono sinonimi. Il default è importare entrambe.

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
