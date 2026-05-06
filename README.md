# gh-runner-watch

Repository con due script coordinati per monitorare un GitHub Actions self-hosted runner (servizio `svc.sh`):

- `gh-runner-watch.sh` → controlla lo stato del runner e tenta il restart in caso di `oom-kill`
- `gh-runner-watch-heartbeat.sh` → invia un heartbeat Uptime Kuma one-shot, segnando il runner come `up` oppure `down`

Lo script principale `gh-runner-watch.sh` controlla lo stato del runner e applica contromisure:

- se **running** → OK
- se **failed (`Result: oom-kill`)** → notifica + tenta **stop/start** + ricontrollo
- se **non running** (altro motivo) → notifica

> Nota: lo script esegue `svc.sh` **dentro la directory del runner** (fa `cd` nel runner root), perché `svc.sh` richiede di essere lanciato da lì.

## Script inclusi

### `gh-runner-watch.sh`

- verifica se il runner è `active (running)`
- se trova `Result: oom-kill`, notifica e tenta `stop/start`
- se il runner non è running per altri motivi, notifica il problema

### `gh-runner-watch-heartbeat.sh`

- usa lo stesso file di config (`/etc/gh-runner-watch.conf`, salvo override)
- controlla `svc.sh status`
- invia a Uptime Kuma `status=up` se il runner è attivo
- invia a Uptime Kuma `status=down` se il runner non è attivo
- esegue **un solo controllo e un solo push** per invocazione
- il timing è demandato a `cron` (o a un altro scheduler esterno)

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
- `curl` per inviare heartbeat a Uptime Kuma
- `sudo`
- accesso al runner root (es. `/opt/github-runner/...`)
- `svc.sh` presente ed eseguibile nella directory del runner

Opzionali:

- `curl` anche per notifiche Slack/webhook
- `python3` oppure `jq` per costruire/parsing del payload Slack
- `flock` per lock anti-overlap non bloccante

---

## Installazione veloce

1. Copia gli script dove preferisci, ad esempio:

    ```bash
    sudo cp gh-runner-watch.sh /usr/local/bin/gh-runner-watch.sh
    sudo chmod 700 /usr/local/bin/gh-runner-watch.sh
    sudo cp gh-runner-watch-heartbeat.sh /usr/local/bin/gh-runner-watch-heartbeat.sh
    sudo chmod 700 /usr/local/bin/gh-runner-watch-heartbeat.sh
    ```

2. Crea un file di configurazione opzionale in `/etc/gh-runner-watch.conf`.

   Puoi mettere nello stesso file sia la config Slack di `gh-runner-watch.sh` sia la config Uptime Kuma di `gh-runner-watch-heartbeat.sh`.

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

   ### Opzione C: Uptime Kuma heartbeat per runner specifici

    ```bash
    sudo tee /etc/gh-runner-watch.conf >/dev/null <<'EOC'
    KUMA_PUSH_URL_PIPELINE_AGENTS2_CONTAINER_1="http://142.132.161.191:3001/api/push/YndWDu70ol?status=up&msg=OK&ping="
    KUMA_PUSH_URL_PIPELINE_AGENTS2_CONTAINER_2="http://142.132.161.191:3001/api/push/F0bF2q8sxV?status=up&msg=OK&ping="
    EOC
    sudo chmod 600 /etc/gh-runner-watch.conf
    ```

   Se preferisci un solo endpoint di default per tutti i runner, puoi usare anche:

    ```bash
    sudo tee /etc/gh-runner-watch.conf >/dev/null <<'EOC'
    KUMA_PUSH_URL="http://142.132.161.191:3001/api/push/TOKEN"
    EOC
    sudo chmod 600 /etc/gh-runner-watch.conf
    ```

> Se sono presenti sia `SLACK_BOT_TOKEN` + `SLACK_CHANNEL_ID` sia `SLACK_WEBHOOK_URL`, lo script prova prima `chat.postMessage` via Slack Web API e usa il webhook solo come fallback configurativo.

> Per `gh-runner-watch-heartbeat.sh`, se esiste una variabile runner-specifica del tipo `KUMA_PUSH_URL_<RUNNER_KEY>`, quella ha precedenza su `KUMA_PUSH_URL` generale.

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

## Heartbeat Uptime Kuma (`gh-runner-watch-heartbeat.sh`)

Questo script è **parallelo** a `gh-runner-watch.sh` e non modifica il comportamento del file di restart.

Serve per aggiornare Uptime Kuma con lo stato reale del runner a ogni invocazione:

- `up` se `svc.sh status` contiene `active (running)`
- `down` negli altri casi, compreso `oom-kill`

### Config condivisa

Di default usa lo stesso file di config:

```text
/etc/gh-runner-watch.conf
```

Variabili supportate:

- `KUMA_PUSH_URL="http://.../api/push/TOKEN"`
- `KUMA_PUSH_URL_<RUNNER_KEY>="http://.../api/push/TOKEN"`

Il `RUNNER_KEY` viene derivato dal nome logico del runner:

- se usi `--runner-dir /opt/github-runner/pipeline-agents2-container-1`, la variabile cercata è `KUMA_PUSH_URL_PIPELINE_AGENTS2_CONTAINER_1`
- se usi `--runner-dir /opt/github-runner/pipeline-agents2-container-2`, la variabile cercata è `KUMA_PUSH_URL_PIPELINE_AGENTS2_CONTAINER_2`
- se passi `--runner-key nome-logico`, la variabile cercata diventa `KUMA_PUSH_URL_NOME_LOGICO`
- se non passi `--runner-key`, viene usato il basename di `--runner-dir`

### Esecuzione manuale

Runner 1:

```bash
/usr/local/bin/gh-runner-watch-heartbeat.sh --manual \
  --config /etc/gh-runner-watch.conf \
  --runner-dir /opt/github-runner/pipeline-agents2-container-1
```

Runner 2:

```bash
/usr/local/bin/gh-runner-watch-heartbeat.sh --manual \
  --config /etc/gh-runner-watch.conf \
  --runner-dir /opt/github-runner/pipeline-agents2-container-2
```

### Esecuzione da cron (`--scheduled`)

Lo script è one-shot: ogni invocazione fa **un solo check** e **un solo push**.

Quindi il timing va definito nel cron e non dentro lo script.

#### Esempio: heartbeat ogni 30 secondi per 2 runner

Con cron classico puoi ottenere 30 secondi usando due entry per runner: una allo scatto del minuto e una dopo `sleep 30`.

```bash
sudo crontab -e
```

Inserisci:

```cron
* * * * * /usr/local/bin/gh-runner-watch-heartbeat.sh --scheduled --config /etc/gh-runner-watch.conf --runner-dir /opt/github-runner/pipeline-agents2-container-1 >> /var/log/gh-runner-watch-heartbeat-cron.log 2>&1
* * * * * sleep 30; /usr/local/bin/gh-runner-watch-heartbeat.sh --scheduled --config /etc/gh-runner-watch.conf --runner-dir /opt/github-runner/pipeline-agents2-container-1 >> /var/log/gh-runner-watch-heartbeat-cron.log 2>&1
* * * * * /usr/local/bin/gh-runner-watch-heartbeat.sh --scheduled --config /etc/gh-runner-watch.conf --runner-dir /opt/github-runner/pipeline-agents2-container-2 >> /var/log/gh-runner-watch-heartbeat-cron.log 2>&1
* * * * * sleep 30; /usr/local/bin/gh-runner-watch-heartbeat.sh --scheduled --config /etc/gh-runner-watch.conf --runner-dir /opt/github-runner/pipeline-agents2-container-2 >> /var/log/gh-runner-watch-heartbeat-cron.log 2>&1
```

> In modalità `--scheduled` lo script usa `sudo -n`, quindi senza sudoers adeguato fallirà se servono privilegi elevati.

### Emulare esattamente la chiamata del cron, una sola volta

Runner 1:

```bash
/usr/local/bin/gh-runner-watch-heartbeat.sh --scheduled \
  --config /etc/gh-runner-watch.conf \
  --runner-dir /opt/github-runner/pipeline-agents2-container-1
```

Runner 2:

```bash
/usr/local/bin/gh-runner-watch-heartbeat.sh --scheduled \
  --config /etc/gh-runner-watch.conf \
  --runner-dir /opt/github-runner/pipeline-agents2-container-2
```

### Note pratiche

- se la URL Kuma nel file di config contiene già `?status=up&msg=OK&ping=`, lo script la normalizza automaticamente e invia lui i parametri corretti (`status`, `msg`, `ping`)
- `gh-runner-watch-heartbeat.sh` non tenta restart: segnala solo `up/down` a Uptime Kuma
- `gh-runner-watch-heartbeat.sh` non resta in esecuzione: fa un solo giro e termina
- `gh-runner-watch.sh` rimane indipendente e continua a fare restart/notifiche come prima

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
- `KUMA_PUSH_URL="http://.../api/push/TOKEN"`
- `KUMA_PUSH_URL_<RUNNER_KEY>="http://.../api/push/TOKEN"`

### Precedenza configurazione

L’ordine di precedenza è:

1. default interni allo script
2. file di config
3. argomenti CLI

Entrambi gli script fanno un primo pass su `--config`, caricano il file corretto e poi rileggono tutti gli argomenti, quindi gli override da CLI vincono sempre sul file.

Per `gh-runner-watch-heartbeat.sh`, in più:

- `--kuma-push-url` vince sempre
- `KUMA_PUSH_URL_<RUNNER_KEY>` vince su `KUMA_PUSH_URL`
- il timing non è configurato nello script: è deciso da cron

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

Per l’heartbeat Kuma:

- log principale: `/var/log/gh-runner-watch-heartbeat.log`
- fallback log: `$HOME/gh-runner-watch-heartbeat.log`
- log cron di esempio: `/var/log/gh-runner-watch-heartbeat-cron.log`

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

Per `gh-runner-watch-heartbeat.sh` il lock è separato e usa questo pattern:

```text
/var/lock/gh-runner-watch-heartbeat.<RUNNER_SANITIZED>.lock
```

---

## Exit code

Utile per monitoring o wrapper esterni:

### `gh-runner-watch.sh`

- `0`  → runner running
- `10` → OOM-kill rilevato, restart riuscito
- `11` → OOM-kill rilevato, restart fallito
- `20` → non running (motivo diverso da OOM-kill)
- `30` → errore script (path runner/svc.sh non valido, argomento errato, ecc.)

### `gh-runner-watch-heartbeat.sh`

- `0`  → runner running, heartbeat `up` inviato con successo
- `20` → runner non running, heartbeat `down` inviato con successo
- `30` → errore script o invio heartbeat fallito

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

### Debug heartbeat Kuma

```bash
bash -x /usr/local/bin/gh-runner-watch-heartbeat.sh --manual --config /etc/gh-runner-watch.conf --runner-dir "/opt/github-runner/..."
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

Per l’heartbeat Kuma:

```bash
tail -f /var/log/gh-runner-watch-heartbeat.log
```

Per il cron heartbeat:

```bash
tail -f /var/log/gh-runner-watch-heartbeat-cron.log
```

