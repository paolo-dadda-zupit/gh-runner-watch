# gh-runner-watch.sh

Script per controllare lo stato di un GitHub Actions self-hosted runner (servizio `svc.sh`) e applicare contromisure:

- se **running** → OK
- se **failed (`Result: oom-kill`)** → notifica + tenta **stop/start** + ricontrollo
- se **non running** (altro motivo) → notifica

> Nota: lo script esegue `svc.sh` **dentro la directory del runner** (fa `cd` nel runner root), perché `svc.sh` richiede di essere lanciato da lì.

---

## Comportamento

Lo script supporta due modalità:

- `--manual`
- `--scheduled`

### Modalità manual

- se il runner è attivo, stampa `running`
- se il runner è in `oom-kill`, prova comunque il restart
- le notifiche vengono stampate su stdout
- `sudo` può chiedere la password se necessario

### Modalità scheduled

- pensata per cron
- usa `sudo -n` (quindi **non deve chiedere password**)
- se configurato, invia notifiche su Slack
- evita overlap con un lock file dedicato al runner

---

## Requisiti

Base:

- bash
- `sudo`
- accesso al runner root (es. `/opt/github-runner/...`)
- `svc.sh` presente ed eseguibile nella directory del runner

Opzionali:

- `curl` per notifiche Slack
- `python3` oppure `jq` per costruire/parsing del payload Slack
- `flock` per lock anti-overlap non bloccante

---

## Installazione veloce

1. Copia lo script dove preferisci, ad esempio:

    ```bash
    sudo cp gh-runner-watch.sh /usr/local/bin/gh-runner-watch.sh
    sudo chmod 700 /usr/local/bin/gh-runner-watch.sh
    ```

2. Crea un file di configurazione opzionale in `/etc/gh-runner-watch.conf`:

   ### Opzione A: Slack via bot token + channel ID (preferita)

    ```bash
    sudo tee /etc/gh-runner-watch.conf >/dev/null <<'EOC'
    SLACK_BOT_TOKEN="xoxb-..."
    SLACK_CHANNEL_ID="C12345678"
    EOC
    sudo chmod 600 /etc/gh-runner-watch.conf
    ```

   ### Opzione B: Slack via webhook

    ```bash
    sudo tee /etc/gh-runner-watch.conf >/dev/null <<'EOC'
    SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
    EOC
    sudo chmod 600 /etc/gh-runner-watch.conf
    ```

> Se sono presenti sia `SLACK_BOT_TOKEN` + `SLACK_CHANNEL_ID` sia `SLACK_WEBHOOK_URL`, lo script prova prima `chat.postMessage` via Slack Web API e usa il webhook solo come fallback configurativo.

---

## Uso manuale

### Esecuzione base (runner di default)

```bash
/usr/local/bin/gh-runner-watch.sh --manual
```

Se il runner è attivo, stampa:

```text
running
```

Se il runner non è attivo:

- in caso di `oom-kill` prova `stop/start` e stampa l’esito
- negli altri casi stampa un messaggio con i dettagli dello stato

### Personalizzare il path del runner

```bash
/usr/local/bin/gh-runner-watch.sh --manual --runner-dir "/opt/github-runner/NOME_RUNNER"
```

Esempio:

```bash
/usr/local/bin/gh-runner-watch.sh --manual --runner-dir "/opt/github-runner/pipeline-agents2-container-1"
```

### Usare un file di config diverso

```bash
/usr/local/bin/gh-runner-watch.sh --manual --config "/percorso/mio.conf"
```

### Override Slack da CLI

Webhook:

```bash
/usr/local/bin/gh-runner-watch.sh --manual --slack-webhook "https://hooks.slack.com/services/XXX/YYY/ZZZ"
```

Bot token + channel ID:

```bash
/usr/local/bin/gh-runner-watch.sh --manual \
  --slack-bot-token "xoxb-..." \
  --slack-channel-id "C12345678"
```

### Help

```bash
/usr/local/bin/gh-runner-watch.sh --help
```

---

## Modalità scheduled (cron ogni 3 minuti)

### Opzione A (consigliata): cron come root

```bash
sudo crontab -e
```

Lo script è pensato anche per essere eseguito via cron in modalità `--scheduled`.

#### Esempio: due runner diversi, sfalsati di 1 minuto

Nel nostro caso vengono controllati due runner diversi, entrambi ogni 3 minuti, ma con scheduling sfalsato per non farli partire nello stesso istante:

```cron
*/3 * * * * /home/zpa-admin-cnpuh/gh-runner-watch.sh --scheduled --config /etc/gh-runner-watch.conf --runner-dir /opt/github-runner/argon-pentana-pipeline-agents2-container-1 >> /var/log/gh-runner-watch-cron.log 2>&1
1-59/3 * * * * /home/zpa-admin-cnpuh/gh-runner-watch.sh --scheduled --config /etc/gh-runner-watch.conf --runner-dir /opt/github-runner/argon-pentana-pipeline-agents2-container-2 >> /var/log/gh-runner-watch-cron.log 2>&1
```

### Opzione B: cron come utente (con sudoers mirato)

Apri sudoers con:

```bash
sudo visudo
```

Aggiungi una regola simile, sostituendo `NOME_UTENTE` e il path del runner:

```sudoers
NOME_UTENTE ALL=(root) NOPASSWD: /opt/github-runner/pipeline-agents2-container-1/svc.sh status, \
  /opt/github-runner/pipeline-agents2-container-1/svc.sh stop, \
  /opt/github-runner/pipeline-agents2-container-1/svc.sh start
```

Poi nel crontab dell’utente:

```bash
crontab -e
```

Aggiungi:

```cron
*/3 * * * * /usr/local/bin/gh-runner-watch.sh --scheduled >> $HOME/gh-runner-watch.cron.log 2>&1
```

> In modalità `--scheduled` lo script usa `sudo -n`, quindi senza sudoers adeguato fallirà se servono privilegi elevati.

---

## Configurazione

### File di config

Default:

```text
/etc/gh-runner-watch.conf
```

Puoi passare un file diverso:

```bash
/usr/local/bin/gh-runner-watch.sh --scheduled --config "/percorso/mio.conf"
```

Variabili supportate:

- `SLACK_WEBHOOK_URL="..."`
- `SLACK_BOT_TOKEN="xoxb-..."`
- `SLACK_CHANNEL_ID="C12345678"`

### Precedenza configurazione

L’ordine di precedenza è:

1. default interni allo script
2. file di config
3. argomenti CLI

Lo script fa un primo pass su `--config`, carica il file corretto e poi rilegge tutti gli argomenti, quindi gli override da CLI vincono sempre sul file.

---

## Log e lock

### Log

File principale, se scrivibile:

```text
/var/log/gh-runner-watch.log
```

Fallback:

```text
$HOME/gh-runner-watch.log
```

Lo script salva log sintetici di stato e output restart.

### Lock anti-overlap

Il lock è **specifico per il runner** monitorato.

Path principale:

```text
/var/lock/gh-runner-watch.<RUNNER_SANITIZED>.lock
```

Fallback:

```text
/tmp/gh-runner-watch.<RUNNER_SANITIZED>.lock
```

Questo permette di eseguire in parallelo controlli su runner diversi senza bloccarli tra loro.

> Se `flock` è disponibile, viene usato un lock non bloccante. In caso di processo già attivo, lo script esce senza errore.

---

## Exit code

Utile per monitoring o wrapper esterni:

- `0`  → runner running
- `10` → OOM-kill rilevato, restart riuscito
- `11` → OOM-kill rilevato, restart fallito
- `20` → non running (motivo diverso da OOM-kill)
- `30` → errore script (path runner/svc.sh non valido, argomento errato, ecc.)

---

## Slack

Le notifiche Slack vengono inviate solo in modalità `--scheduled`.

Ordine di invio:

1. `SLACK_BOT_TOKEN` + `SLACK_CHANNEL_ID`
2. `SLACK_WEBHOOK_URL`

Se non è presente alcuna configurazione Slack, lo script continua comunque a funzionare e scrive il problema nel log.

---

## Runner di default

Se non specifichi `--runner-dir`, il runner di default è:

```text
/opt/github-runner/pipeline-agents2-container-1
```

Puoi sempre fare override da CLI con `--runner-dir`.

---

## Troubleshooting

### Verifica a mano il runner root

```bash
cd /opt/github-runner/pipeline-agents2-container-1
sudo ./svc.sh status
```

### Debug verbose dello script

```bash
bash -x /usr/local/bin/gh-runner-watch.sh --manual --runner-dir "/opt/github-runner/..."
```

### Verifica file di config

```bash
sudo cat /etc/gh-runner-watch.conf
```

### Verifica lock file

```bash
ls -l /var/lock/gh-runner-watch.* /tmp/gh-runner-watch.* 2>/dev/null
```

### Verifica log

```bash
tail -f /var/log/gh-runner-watch.log
```

oppure, se è in fallback:

```bash
tail -f "$HOME/gh-runner-watch.log"
```