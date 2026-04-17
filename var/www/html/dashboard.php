<?php

/*
 * ==========================================
 * FILE: dashboard.php
 * RUOLO: renderizza la dashboard leggendo solo i file runtime prodotti dal sistema Bash.
 *
 * FLOW:
 * 1. legge variables.data con fallback sicuri
 * 2. legge le ultime righe di alerts.log (non tutto il file)
 * 3. parsea servizi e log strutturato
 * 4. esegue escaping HTML di ogni valore mostrato
 * 5. renderizza overview, servizi e ultimi alert
 *
 * INPUT:
 * - /opt/alerting/variables.data
 * - /var/log/alerts.log
 *
 * OUTPUT:
 * - HTML server-side robusto a file mancanti o righe malformate
 *
 * DIPENDENZE:
 * - PHP 8+
 * - comando tail disponibile nel container
 *
 * ATTENZIONE:
 * - il parser log assume 7 campi separati da pipe
 * - il log viene letto solo nelle ultime N righe per evitare OOM
 * - non disabilitare escaping, i dati arrivano da file runtime
 * ==========================================
 */

declare(strict_types=1);

// --- FILE PATHS / DEFAULTS ---
$variablesFile = '/opt/alerting/variables.data';
$alertsFile = '/var/log/alerts.log';

$defaults = [
    'HOST' => 'unknown',
    'TIMESTAMP' => 'N/A',
    'OVERALL_STATUS' => 'UNKNOWN',
    'IP_ADDRESS' => 'N/A',
    'DISK_USAGE' => '0',
    'DISK_THRESHOLD' => '0',
    'LOAD_AVG' => '0.00',
    'LOAD_THRESHOLD' => '0.00',
    'UPTIME_READABLE' => 'N/A',
    'USERS_CONNECTED' => '0',
    'SERVICES_STATUS' => '',
    'SERVICES_DOWN_COUNT' => '0',
];

$warnings = [];
$data = $defaults;

// esc
// input: stringa da mostrare in HTML
// output: stringa escaped per HTML
// side effects: nessuno
// failure: nessuno
function esc(string $value): string
{
    return htmlspecialchars($value, ENT_QUOTES, 'UTF-8');
}

// decodeLogField
// input: campo log codificato in formato URL-safe semplice
// output: campo decodificato per la view
// side effects: nessuno
// failure: nessuno; rawurldecode e tollerante
function decodeLogField(string $value): string
{
    return rawurldecode($value);
}

// parseKeyValueFile
// input: path file key=value, array default, collector warning per riferimento
// output: array dati completo con fallback
// side effects: aggiunge warning se file mancante/non leggibile
// failure: non lancia eccezioni; ritorna sempre una struttura coerente
function parseKeyValueFile(string $file, array $defaults, array &$warnings): array
{
    $data = $defaults;

    if (!is_readable($file)) {
        $warnings[] = 'variables.data non disponibile';
        return $data;
    }

    $lines = @file($file, FILE_IGNORE_NEW_LINES);
    if ($lines === false) {
        $warnings[] = 'variables.data non leggibile';
        return $data;
    }

    foreach ($lines as $lineRaw) {
        $line = trim((string) $lineRaw);
        if ($line === '' || str_starts_with($line, '#')) {
            continue;
        }

        if (!str_contains($line, '=')) {
            continue;
        }

        [$key, $value] = explode('=', $line, 2);
        $key = trim($key);
        if ($key === '') {
            continue;
        }

        $data[$key] = trim($value);
    }

    return $data;
}

// parseServices
// input: stringa SERVICES_STATUS serializzata come name:status,name:status
// output: lista normalizzata di servizi per il rendering UI
// side effects: nessuno
// failure: entry malformate vengono ignorate o marcate UNKNOWN
function parseServices(string $serialized): array
{
    $out = [];
    if (trim($serialized) === '') {
        return $out;
    }

    $parts = explode(',', $serialized);
    foreach ($parts as $part) {
        $part = trim($part);
        if ($part === '') {
            continue;
        }

        if (!str_contains($part, ':')) {
            $out[] = ['name' => $part, 'status' => 'UNKNOWN'];
            continue;
        }

        [$name, $status] = explode(':', $part, 2);
        $name = trim($name);
        $status = strtoupper(trim($status));

        if ($name === '') {
            continue;
        }

        if ($status === '') {
            $status = 'UNKNOWN';
        }

        $out[] = ['name' => $name, 'status' => $status];
    }

    return $out;
}

// parseAlerts
// input: path file log e numero massimo di righe finali da leggere
// output: array di eventi pronti per la tabella dashboard
// side effects: esegue tail esterno per limitare memoria e latenza su log grandi
// failure: se il file manca o tail non e disponibile, ritorna array vuoto
// nota: righe malformate o con meno di 7 campi vengono scartate silenziosamente
function parseAlerts(string $file, int $max = 20): array
{
    if (!is_readable($file)) {
        return [];
    }

    $command = 'tail -n ' . (int) $max . ' ' . escapeshellarg($file);
    $handle = @popen($command, 'r');
    if ($handle === false) {
        return [];
    }

    $events = [];

    while (($lineRaw = fgets($handle)) !== false) {
        $line = trim((string) $lineRaw);
        if ($line === '') {
            continue;
        }

        $parts = explode('|', $line);
        if (count($parts) < 7) {
            continue;
        }

        $events[] = [
            'timestamp' => decodeLogField(trim($parts[0])),
            'event_type' => decodeLogField(trim($parts[1])),
            'severity' => decodeLogField(trim($parts[2])),
            'title' => decodeLogField(trim($parts[3])),
            'channel' => decodeLogField(trim($parts[4])),
            'outcome' => decodeLogField(trim($parts[5])),
            'details' => decodeLogField(trim(implode('|', array_slice($parts, 6)))),
        ];
    }

    pclose($handle);

    return array_reverse($events);
}

// toneForStatus
// input: stato o outcome testuale
// output: token colore UI (critical, warning, ok, neutral)
// side effects: nessuno
// failure: valori sconosciuti ricadono su neutral
function toneForStatus(string $status): string
{
    $s = strtoupper(trim($status));
    if ($s === 'CRITICAL' || $s === 'DOWN' || $s === 'FAILED') {
        return 'critical';
    }
    if ($s === 'WARNING') {
        return 'warning';
    }
    if ($s === 'OK' || $s === 'ACTIVE' || $s === 'SENT') {
        return 'ok';
    }
    return 'neutral';
}

// --- DATA LOADING / FALLBACKS ---
$data = parseKeyValueFile($variablesFile, $defaults, $warnings);
$services = parseServices((string) ($data['SERVICES_STATUS'] ?? ''));
$alerts = parseAlerts($alertsFile, 50);

$overallStatus = (string) ($data['OVERALL_STATUS'] ?? 'UNKNOWN');
$overallTone = toneForStatus($overallStatus);

?>
<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Alerting Dashboard</title>
    <style>
        :root {
            --bg: #f4f6f8;
            --card: #ffffff;
            --text: #1f2933;
            --muted: #52606d;
            --ok: #137333;
            --warning: #b06a00;
            --critical: #b42318;
            --neutral: #52606d;
            --line: #d9e2ec;
        }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            font-family: Arial, sans-serif;
            background: var(--bg);
            color: var(--text);
        }
        .wrap {
            width: min(1100px, calc(100% - 24px));
            margin: 16px auto;
            display: grid;
            gap: 12px;
        }
        .card {
            background: var(--card);
            border: 1px solid var(--line);
            border-radius: 10px;
            padding: 12px;
        }
        .header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            gap: 10px;
            flex-wrap: wrap;
        }
        .grid {
            display: grid;
            gap: 10px;
            grid-template-columns: repeat(4, 1fr);
        }
        .grid2 {
            display: grid;
            gap: 10px;
            grid-template-columns: repeat(2, 1fr);
        }
        .pill {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 999px;
            font-size: 12px;
            font-weight: bold;
            color: #fff;
        }
        .tone-ok { background: var(--ok); }
        .tone-warning { background: var(--warning); }
        .tone-critical { background: var(--critical); }
        .tone-neutral { background: var(--neutral); }
        .muted { color: var(--muted); font-size: 13px; }
        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 13px;
        }
        th, td {
            text-align: left;
            padding: 8px;
            border-bottom: 1px solid var(--line);
            vertical-align: top;
        }
        .mono { font-family: Consolas, monospace; }
        ul { margin: 0; padding-left: 18px; }
        @media (max-width: 900px) {
            .grid, .grid2 { grid-template-columns: 1fr; }
            th:nth-child(7), td:nth-child(7) { display: none; }
        }
    </style>
</head>
<body>
    <main class="wrap">
        <section class="card header">
            <div>
                <h1 style="margin:0 0 6px 0; font-size:22px;">Sistema Alerting Multi-Canale</h1>
                <div class="muted">Host <?= esc((string) $data['HOST']) ?> - Ultimo update <?= esc((string) $data['TIMESTAMP']) ?></div>
            </div>
            <span class="pill tone-<?= esc($overallTone) ?>">STATUS <?= esc($overallStatus) ?></span>
        </section>

        <?php if ($warnings): ?>
            <section class="card">
                <strong>Warning runtime</strong>
                <ul>
                    <?php foreach ($warnings as $w): ?>
                        <li><?= esc((string) $w) ?></li>
                    <?php endforeach; ?>
                </ul>
            </section>
        <?php endif; ?>

        <section class="card grid">
            <div>
                <div class="muted">IP</div>
                <div><?= esc((string) $data['IP_ADDRESS']) ?></div>
            </div>
            <div>
                <div class="muted">Disk</div>
                <div><?= esc((string) $data['DISK_USAGE']) ?>% / <?= esc((string) $data['DISK_THRESHOLD']) ?>%</div>
            </div>
            <div>
                <div class="muted">Load</div>
                <div><?= esc((string) $data['LOAD_AVG']) ?> / <?= esc((string) $data['LOAD_THRESHOLD']) ?></div>
            </div>
            <div>
                <div class="muted">Utenti connessi</div>
                <div><?= esc((string) $data['USERS_CONNECTED']) ?></div>
            </div>
        </section>

        <section class="card grid2">
            <div>
                <h2 style="margin-top:0;">Servizi monitorati</h2>
                <?php if (!$services): ?>
                    <div class="muted">Nessun servizio disponibile</div>
                <?php else: ?>
                    <ul>
                        <?php foreach ($services as $service): ?>
                            <li>
                                <?= esc($service['name']) ?>
                                <span class="pill tone-<?= esc(toneForStatus($service['status'])) ?>"><?= esc($service['status']) ?></span>
                            </li>
                        <?php endforeach; ?>
                    </ul>
                <?php endif; ?>
            </div>
            <div>
                <h2 style="margin-top:0;">Uptime</h2>
                <div><?= esc((string) $data['UPTIME_READABLE']) ?></div>
                <p class="muted">Servizi down: <?= esc((string) $data['SERVICES_DOWN_COUNT']) ?></p>
            </div>
        </section>

        <section class="card">
            <h2 style="margin-top:0;">Ultimi alert</h2>
            <?php if (!$alerts): ?>
                <div class="muted">alerts.log vuoto o non disponibile</div>
            <?php else: ?>
                <table>
                    <thead>
                        <tr>
                            <th>Timestamp</th>
                            <th>Event</th>
                            <th>Severity</th>
                            <th>Title</th>
                            <th>Channel</th>
                            <th>Outcome</th>
                            <th>Details</th>
                        </tr>
                    </thead>
                    <tbody>
                        <?php foreach ($alerts as $a): ?>
                            <tr>
                                <td class="mono"><?= esc($a['timestamp']) ?></td>
                                <td><?= esc($a['event_type']) ?></td>
                                <td><span class="pill tone-<?= esc(toneForStatus($a['severity'])) ?>"><?= esc($a['severity']) ?></span></td>
                                <td><?= esc($a['title']) ?></td>
                                <td><?= esc($a['channel']) ?></td>
                                <td><span class="pill tone-<?= esc(toneForStatus($a['outcome'])) ?>"><?= esc($a['outcome']) ?></span></td>
                                <td class="mono"><?= esc($a['details']) ?></td>
                            </tr>
                        <?php endforeach; ?>
                    </tbody>
                </table>
            <?php endif; ?>
        </section>
    </main>
</body>
</html>
