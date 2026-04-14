<?php

$file = '/opt/alerting/variables.data';

$defaults = [
    'HOST' => 'unknown',
    'TIMESTAMP' => 'N/A',
    'OVERALL_STATUS' => 'UNKNOWN',
    'IP_ADDRESS' => 'N/A',
    'DISK_USAGE' => 'N/A',
    'DISK_THRESHOLD' => 'N/A',
    'LOAD_AVG' => 'N/A',
    'LOAD_THRESHOLD' => 'N/A',
    'UPTIME_READABLE' => 'N/A',
    'USERS_CONNECTED' => 'N/A',
    'SERVICES_STATUS' => '',
];

$data = $defaults;
$warnings = [];

if (is_readable($file)) {
    $lines = @file($file, FILE_IGNORE_NEW_LINES);

    if ($lines === false) {
        $warnings[] = 'Runtime data not readable.';
    } else {
        foreach ($lines as $rawLine) {
            $line = trim($rawLine);

            if ($line === '' || (isset($line[0]) && $line[0] === '#')) {
                continue;
            }

            if (strpos($line, '=') === false) {
                continue;
            }

            [$key, $value] = explode('=', $line, 2);
            $key = trim($key);

            if ($key === '') {
                continue;
            }

            $data[$key] = trim($value);
        }
    }
} else {
    $warnings[] = 'Runtime data file not available yet.';
}

function e($value): string
{
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

function normalize_status($value): string
{
    $status = strtoupper(trim((string) $value));

    if ($status === '') {
        return 'UNKNOWN';
    }

    if (in_array($status, ['OK', 'WARNING', 'CRITICAL', 'ACTIVE', 'DOWN', 'UNKNOWN'], true)) {
        return $status;
    }

    return 'UNKNOWN';
}

function tone_for_status($status): string
{
    return match (normalize_status($status)) {
        'OK', 'ACTIVE' => 'ok',
        'WARNING' => 'warning',
        'CRITICAL', 'DOWN' => 'critical',
        default => 'neutral',
    };
}

function parse_number($value): ?float
{
    $normalized = str_replace(',', '.', trim((string) $value));

    if ($normalized === '' || !is_numeric($normalized)) {
        return null;
    }

    return (float) $normalized;
}

function metric_tone(?float $value, ?float $threshold): string
{
    if ($value === null || $threshold === null || $threshold <= 0) {
        return 'neutral';
    }

    if ($value >= $threshold) {
        return 'critical';
    }

    if ($value >= ($threshold * 0.8)) {
        return 'warning';
    }

    return 'ok';
}

function metric_label(?float $value, ?float $threshold): string
{
    if ($value === null || $threshold === null || $threshold <= 0) {
        return 'No threshold data';
    }

    if ($value >= $threshold) {
        return 'Above threshold';
    }

    if ($value >= ($threshold * 0.8)) {
        return 'Near threshold';
    }

    return 'Within range';
}

function disk_fill(?float $value): int
{
    if ($value === null) {
        return 0;
    }

    return (int) max(0, min(100, round($value)));
}

function load_fill(?float $value, ?float $threshold): int
{
    if ($value === null) {
        return 0;
    }

    if ($threshold !== null && $threshold > 0) {
        return (int) max(0, min(100, round(($value / $threshold) * 100)));
    }

    return (int) max(0, min(100, round($value * 10)));
}

function services($serialized): array
{
    if (!is_string($serialized) || trim($serialized) === '') {
        return [];
    }

    $out = [];

    foreach (explode(',', $serialized) as $service) {
        $service = trim($service);

        if ($service === '') {
            continue;
        }

        if (strpos($service, ':') === false) {
            $out[] = [$service, 'UNKNOWN'];
            continue;
        }

        [$name, $status] = explode(':', $service, 2);
        $name = trim($name);
        $status = trim($status);

        if ($name === '') {
            continue;
        }

        $out[] = [$name, $status !== '' ? $status : 'UNKNOWN'];
    }

    return $out;
}

$overallStatus = normalize_status($data['OVERALL_STATUS']);
$overallTone = tone_for_status($overallStatus);
$diskValue = parse_number($data['DISK_USAGE']);
$diskThreshold = parse_number($data['DISK_THRESHOLD']);
$loadValue = parse_number($data['LOAD_AVG']);
$loadThreshold = parse_number($data['LOAD_THRESHOLD']);
$diskTone = metric_tone($diskValue, $diskThreshold);
$loadTone = metric_tone($loadValue, $loadThreshold);
$diskLabel = metric_label($diskValue, $diskThreshold);
$loadLabel = metric_label($loadValue, $loadThreshold);

$serviceList = [];
$serviceCounts = [
    'ACTIVE' => 0,
    'DOWN' => 0,
    'UNKNOWN' => 0,
];

foreach (services($data['SERVICES_STATUS']) as [$name, $status]) {
    $normalizedStatus = normalize_status($status);

    if (!isset($serviceCounts[$normalizedStatus])) {
        $normalizedStatus = 'UNKNOWN';
    }

    $serviceCounts[$normalizedStatus]++;
    $serviceList[] = [
        'name' => $name,
        'status' => $normalizedStatus,
        'tone' => tone_for_status($normalizedStatus),
    ];
}

$totalServices = count($serviceList);
$stats = [
    ['label' => 'Host', 'value' => $data['HOST'], 'tone' => 'neutral'],
    ['label' => 'IP Address', 'value' => $data['IP_ADDRESS'], 'tone' => 'neutral'],
    ['label' => 'Uptime', 'value' => $data['UPTIME_READABLE'], 'tone' => 'neutral'],
    ['label' => 'Users Connected', 'value' => $data['USERS_CONNECTED'], 'tone' => 'neutral'],
];

$runtimeSnapshot = [
    'HOST' => $data['HOST'],
    'TIMESTAMP' => $data['TIMESTAMP'],
    'OVERALL_STATUS' => $overallStatus,
    'IP_ADDRESS' => $data['IP_ADDRESS'],
    'DISK_USAGE' => $data['DISK_USAGE'],
    'DISK_THRESHOLD' => $data['DISK_THRESHOLD'],
    'LOAD_AVG' => $data['LOAD_AVG'],
    'LOAD_THRESHOLD' => $data['LOAD_THRESHOLD'],
    'UPTIME_READABLE' => $data['UPTIME_READABLE'],
    'USERS_CONNECTED' => $data['USERS_CONNECTED'],
    'SERVICES_STATUS' => $data['SERVICES_STATUS'],
];

?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Alerting Dashboard</title>
    <style>
        :root {
            --bg-top: #f6efe3;
            --bg-bottom: #e7eff5;
            --panel: rgba(255, 251, 244, 0.86);
            --panel-strong: #fffaf2;
            --line: rgba(16, 34, 47, 0.11);
            --text: #10222f;
            --muted: #5f7180;
            --shadow: 0 24px 60px rgba(34, 49, 63, 0.12);
            --ok: #1e8f6e;
            --ok-soft: rgba(30, 143, 110, 0.12);
            --warning: #d69712;
            --warning-soft: rgba(214, 151, 18, 0.14);
            --critical: #c94b3f;
            --critical-soft: rgba(201, 75, 63, 0.14);
            --neutral: #6d7d89;
            --neutral-soft: rgba(109, 125, 137, 0.12);
        }

        * {
            box-sizing: border-box;
        }

        html {
            color-scheme: light;
        }

        body {
            margin: 0;
            min-height: 100vh;
            font-family: "Trebuchet MS", "Gill Sans", sans-serif;
            color: var(--text);
            background:
                radial-gradient(circle at top left, rgba(201, 75, 63, 0.14), transparent 30%),
                radial-gradient(circle at top right, rgba(30, 143, 110, 0.12), transparent 35%),
                linear-gradient(135deg, var(--bg-top) 0%, var(--bg-bottom) 100%);
        }

        body::before {
            content: "";
            position: fixed;
            inset: 0;
            pointer-events: none;
            opacity: 0.25;
            background-image:
                linear-gradient(rgba(16, 34, 47, 0.06) 1px, transparent 1px),
                linear-gradient(90deg, rgba(16, 34, 47, 0.06) 1px, transparent 1px);
            background-size: 32px 32px;
            mask-image: linear-gradient(to bottom, rgba(0, 0, 0, 0.6), transparent 80%);
        }

        .shell {
            width: min(1180px, calc(100% - 32px));
            margin: 0 auto;
            padding: 28px 0 52px;
            position: relative;
        }

        .hero,
        .panel,
        .metric-card,
        .stat-card,
        .service-card,
        .snapshot-row {
            animation: rise-in 0.65s ease both;
            animation-delay: calc(var(--delay, 0) * 80ms);
        }

        .hero {
            position: relative;
            overflow: hidden;
            display: grid;
            grid-template-columns: 1.35fr 0.85fr;
            gap: 22px;
            padding: 28px;
            border-radius: 28px;
            border: 1px solid rgba(255, 255, 255, 0.75);
            background:
                linear-gradient(160deg, rgba(255, 250, 242, 0.95), rgba(247, 242, 233, 0.82)),
                linear-gradient(180deg, rgba(255, 255, 255, 0.35), transparent);
            box-shadow: var(--shadow);
            backdrop-filter: blur(16px);
        }

        .hero::after {
            content: "";
            position: absolute;
            width: 280px;
            height: 280px;
            right: -80px;
            top: -60px;
            border-radius: 50%;
            background: radial-gradient(circle, rgba(201, 75, 63, 0.18), transparent 72%);
        }

        .eyebrow {
            margin: 0 0 10px;
            font-size: 0.78rem;
            letter-spacing: 0.24em;
            text-transform: uppercase;
            color: var(--muted);
        }

        h1,
        h2,
        h3,
        p {
            margin-top: 0;
        }

        h1 {
            margin-bottom: 12px;
            font-size: clamp(2.3rem, 5vw, 4.2rem);
            line-height: 0.95;
            letter-spacing: -0.04em;
            max-width: 9ch;
        }

        .hero-copy p:last-child {
            margin-bottom: 0;
        }

        .lead {
            max-width: 62ch;
            font-size: 1.02rem;
            line-height: 1.6;
            color: var(--muted);
        }

        .hero-meta,
        .summary-row,
        .service-summary {
            display: flex;
            flex-wrap: wrap;
            gap: 12px;
        }

        .chip {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            padding: 10px 14px;
            border-radius: 999px;
            font-size: 0.84rem;
            font-weight: 700;
            letter-spacing: 0.02em;
            background: rgba(255, 255, 255, 0.8);
            border: 1px solid rgba(16, 34, 47, 0.08);
            box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.7);
        }

        .chip strong,
        .metric-number strong {
            font-family: Consolas, "Courier New", monospace;
        }

        .tone-ok {
            color: var(--ok);
            background: var(--ok-soft);
            border-color: rgba(30, 143, 110, 0.2);
        }

        .tone-warning {
            color: var(--warning);
            background: var(--warning-soft);
            border-color: rgba(214, 151, 18, 0.22);
        }

        .tone-critical {
            color: var(--critical);
            background: var(--critical-soft);
            border-color: rgba(201, 75, 63, 0.22);
        }

        .tone-neutral {
            color: var(--neutral);
            background: var(--neutral-soft);
            border-color: rgba(109, 125, 137, 0.18);
        }

        .hero-side {
            display: grid;
            gap: 14px;
            align-content: start;
        }

        .pulse-card {
            position: relative;
            padding: 20px;
            border-radius: 24px;
            background: linear-gradient(180deg, rgba(255, 255, 255, 0.78), rgba(250, 245, 236, 0.96));
            border: 1px solid rgba(16, 34, 47, 0.08);
        }

        .pulse-card h2 {
            margin-bottom: 18px;
            font-size: 0.88rem;
            letter-spacing: 0.12em;
            text-transform: uppercase;
            color: var(--muted);
        }

        .pulse-number {
            font-size: clamp(2.2rem, 5vw, 3.6rem);
            line-height: 1;
            letter-spacing: -0.05em;
            margin-bottom: 6px;
        }

        .pulse-caption {
            color: var(--muted);
            line-height: 1.5;
        }

        .warning-banner {
            margin-top: 18px;
            padding: 14px 18px;
            border-radius: 18px;
            background: rgba(201, 75, 63, 0.09);
            border: 1px solid rgba(201, 75, 63, 0.18);
            color: #7d3029;
            box-shadow: var(--shadow);
        }

        .section-grid {
            display: grid;
            grid-template-columns: repeat(12, 1fr);
            gap: 18px;
            margin-top: 18px;
        }

        .panel {
            grid-column: span 12;
            padding: 22px;
            border-radius: 24px;
            background: var(--panel);
            border: 1px solid rgba(255, 255, 255, 0.7);
            box-shadow: var(--shadow);
            backdrop-filter: blur(14px);
        }

        .panel-header {
            display: flex;
            justify-content: space-between;
            align-items: start;
            gap: 14px;
            margin-bottom: 18px;
        }

        .panel-header h2 {
            margin-bottom: 8px;
            font-size: 1.45rem;
            letter-spacing: -0.03em;
        }

        .panel-header p {
            margin-bottom: 0;
            color: var(--muted);
            line-height: 1.55;
        }

        .stats-grid,
        .metrics-grid,
        .services-grid {
            display: grid;
            gap: 16px;
        }

        .stats-grid {
            grid-template-columns: repeat(4, minmax(0, 1fr));
        }

        .metrics-grid {
            grid-template-columns: repeat(2, minmax(0, 1fr));
        }

        .services-grid {
            grid-template-columns: repeat(3, minmax(0, 1fr));
        }

        .stat-card,
        .metric-card,
        .service-card {
            padding: 18px;
            border-radius: 20px;
            background: var(--panel-strong);
            border: 1px solid var(--line);
            min-width: 0;
        }

        .stat-card-label,
        .metric-label,
        .service-name,
        .snapshot-key {
            font-size: 0.82rem;
            letter-spacing: 0.1em;
            text-transform: uppercase;
            color: var(--muted);
        }

        .stat-card-value,
        .metric-number {
            margin-top: 8px;
            font-size: 1.5rem;
            letter-spacing: -0.04em;
            word-break: break-word;
        }

        .metric-top {
            display: flex;
            justify-content: space-between;
            gap: 12px;
            align-items: start;
            margin-bottom: 14px;
        }

        .metric-note,
        .metric-threshold,
        .service-meta {
            color: var(--muted);
            line-height: 1.5;
        }

        .meter {
            margin-top: 14px;
        }

        .meter-track {
            height: 12px;
            border-radius: 999px;
            background: rgba(16, 34, 47, 0.08);
            overflow: hidden;
        }

        .meter-fill {
            height: 100%;
            width: var(--fill, 0%);
            border-radius: 999px;
            transition: width 0.4s ease;
            background: linear-gradient(90deg, currentColor, rgba(255, 255, 255, 0.95));
        }

        .service-card {
            display: grid;
            gap: 12px;
        }

        .service-top {
            display: flex;
            justify-content: space-between;
            gap: 12px;
            align-items: center;
        }

        .service-name {
            font-size: 1rem;
            letter-spacing: -0.02em;
            text-transform: none;
            color: var(--text);
            font-weight: 700;
        }

        .service-meta {
            font-size: 0.92rem;
        }

        .snapshot {
            display: grid;
            gap: 12px;
        }

        .snapshot-row {
            display: grid;
            grid-template-columns: 190px 1fr;
            gap: 12px;
            align-items: start;
            padding: 14px 16px;
            border-radius: 16px;
            background: rgba(255, 255, 255, 0.6);
            border: 1px solid rgba(16, 34, 47, 0.08);
        }

        .snapshot-value {
            font-family: Consolas, "Courier New", monospace;
            color: var(--text);
            word-break: break-word;
        }

        .empty-state {
            padding: 26px;
            border-radius: 20px;
            text-align: center;
            color: var(--muted);
            background: rgba(255, 255, 255, 0.56);
            border: 1px dashed rgba(16, 34, 47, 0.18);
        }

        .muted {
            color: var(--muted);
        }

        @keyframes rise-in {
            from {
                opacity: 0;
                transform: translateY(16px);
            }

            to {
                opacity: 1;
                transform: translateY(0);
            }
        }

        @media (max-width: 980px) {
            .hero,
            .stats-grid,
            .metrics-grid,
            .services-grid {
                grid-template-columns: 1fr;
            }

            .snapshot-row {
                grid-template-columns: 1fr;
            }
        }

        @media (max-width: 640px) {
            .shell {
                width: min(100% - 20px, 1180px);
                padding-top: 20px;
            }

            .hero,
            .panel {
                padding: 18px;
                border-radius: 22px;
            }

            h1 {
                max-width: none;
            }

            .panel-header {
                flex-direction: column;
            }
        }
    </style>
</head>
<body>
    <main class="shell">
        <section class="hero" style="--delay: 0;">
            <div class="hero-copy">
                <p class="eyebrow">System Monitoring Dashboard</p>
                <h1>Operations cockpit for live infrastructure health.</h1>
                <p class="lead">
                    A single visual layer for current host status, runtime metrics and service availability,
                    rendered from <strong>variables.data</strong> without adding business logic to PHP.
                </p>
                <div class="hero-meta">
                    <span class="chip tone-<?= e($overallTone) ?>">
                        Overall
                        <strong><?= e($overallStatus) ?></strong>
                    </span>
                    <span class="chip tone-neutral">
                        Host
                        <strong><?= e($data['HOST']) ?></strong>
                    </span>
                    <span class="chip tone-neutral">
                        Updated
                        <strong><?= e($data['TIMESTAMP']) ?></strong>
                    </span>
                </div>
            </div>

            <div class="hero-side">
                <div class="pulse-card">
                    <h2>System Pulse</h2>
                    <div class="pulse-number"><?= e((string) $totalServices) ?></div>
                    <p class="pulse-caption">
                        monitored services, with
                        <strong><?= e((string) $serviceCounts['ACTIVE']) ?> active</strong>
                        and
                        <strong><?= e((string) $serviceCounts['DOWN']) ?> down</strong>.
                    </p>
                </div>
                <div class="summary-row">
                    <span class="chip tone-ok">Active <?= e((string) $serviceCounts['ACTIVE']) ?></span>
                    <span class="chip tone-critical">Down <?= e((string) $serviceCounts['DOWN']) ?></span>
                    <span class="chip tone-neutral">Unknown <?= e((string) $serviceCounts['UNKNOWN']) ?></span>
                </div>
            </div>
        </section>

        <?php if ($warnings): ?>
            <section class="warning-banner" style="--delay: 1;">
                <strong>Runtime warning:</strong> <?= e(implode(' ', $warnings)) ?>
            </section>
        <?php endif; ?>

        <section class="section-grid">
            <section class="panel" style="--delay: 2;">
                <div class="panel-header">
                    <div>
                        <h2>Overview</h2>
                        <p>Key environment details surfaced first so the dashboard is readable in a few seconds.</p>
                    </div>
                    <span class="chip tone-<?= e($overallTone) ?>"><?= e($overallStatus) ?></span>
                </div>

                <div class="stats-grid">
                    <?php foreach ($stats as $index => $stat): ?>
                        <article class="stat-card tone-<?= e($stat['tone']) ?>" style="--delay: <?= e((string) ($index + 3)) ?>;">
                            <div class="stat-card-label"><?= e($stat['label']) ?></div>
                            <div class="stat-card-value"><?= e($stat['value']) ?></div>
                        </article>
                    <?php endforeach; ?>
                </div>
            </section>

            <section class="panel" style="--delay: 4;">
                <div class="panel-header">
                    <div>
                        <h2>Resource Pressure</h2>
                        <p>Disk and load are visualized against their thresholds to make risky conditions stand out immediately.</p>
                    </div>
                </div>

                <div class="metrics-grid">
                    <article class="metric-card tone-<?= e($diskTone) ?>" style="--fill: <?= e((string) disk_fill($diskValue)) ?>%; --delay: 5;">
                        <div class="metric-top">
                            <div>
                                <div class="metric-label">Disk Usage</div>
                                <div class="metric-number">
                                    <strong><?= e($data['DISK_USAGE']) ?>%</strong>
                                </div>
                            </div>
                            <span class="chip tone-<?= e($diskTone) ?>"><?= e($diskLabel) ?></span>
                        </div>
                        <div class="metric-threshold">Threshold: <?= e($data['DISK_THRESHOLD']) ?>%</div>
                        <div class="meter">
                            <div class="meter-track">
                                <div class="meter-fill"></div>
                            </div>
                        </div>
                    </article>

                    <article class="metric-card tone-<?= e($loadTone) ?>" style="--fill: <?= e((string) load_fill($loadValue, $loadThreshold)) ?>%; --delay: 6;">
                        <div class="metric-top">
                            <div>
                                <div class="metric-label">Load Average</div>
                                <div class="metric-number">
                                    <strong><?= e($data['LOAD_AVG']) ?></strong>
                                </div>
                            </div>
                            <span class="chip tone-<?= e($loadTone) ?>"><?= e($loadLabel) ?></span>
                        </div>
                        <div class="metric-threshold">Threshold: <?= e($data['LOAD_THRESHOLD']) ?></div>
                        <div class="meter">
                            <div class="meter-track">
                                <div class="meter-fill"></div>
                            </div>
                        </div>
                    </article>
                </div>
            </section>

            <section class="panel" style="--delay: 7;">
                <div class="panel-header">
                    <div>
                        <h2>Service Health</h2>
                        <p>Each monitored service has a dedicated state tile with strong color feedback.</p>
                    </div>
                    <div class="service-summary">
                        <span class="chip tone-ok">ACTIVE <?= e((string) $serviceCounts['ACTIVE']) ?></span>
                        <span class="chip tone-critical">DOWN <?= e((string) $serviceCounts['DOWN']) ?></span>
                        <span class="chip tone-neutral">UNKNOWN <?= e((string) $serviceCounts['UNKNOWN']) ?></span>
                    </div>
                </div>

                <?php if (!$serviceList): ?>
                    <div class="empty-state">
                        No services data available. The dashboard is ready and waiting for a valid <strong>SERVICES_STATUS</strong> payload.
                    </div>
                <?php else: ?>
                    <div class="services-grid">
                        <?php foreach ($serviceList as $index => $service): ?>
                            <article class="service-card tone-<?= e($service['tone']) ?>" style="--delay: <?= e((string) ($index + 8)) ?>;">
                                <div class="service-top">
                                    <div class="service-name"><?= e($service['name']) ?></div>
                                    <span class="chip tone-<?= e($service['tone']) ?>"><?= e($service['status']) ?></span>
                                </div>
                                <div class="service-meta">
                                    Current state for monitored process <strong><?= e($service['name']) ?></strong>.
                                </div>
                            </article>
                        <?php endforeach; ?>
                    </div>
                <?php endif; ?>
            </section>

            <section class="panel" style="--delay: 8;">
                <div class="panel-header">
                    <div>
                        <h2>Runtime Snanapshot</h2>
                        <p>A direct, readable mirror of the current contract so debugging stays fast.</p>
                    </div>
                    <span class="chip tone-neutral">variables.data</span>
                </div>

                <div class="snapshot">
                    <?php $rowDelay = 9; ?>
                    <?php foreach ($runtimeSnapshot as $key => $value): ?>
                        <div class="snapshot-row" style="--delay: <?= e((string) $rowDelay) ?>;">
                            <div class="snapshot-key"><?= e($key) ?></div>
                            <div class="snapshot-value"><?= e($value) ?></div>
                        </div>
                        <?php $rowDelay++; ?>
                    <?php endforeach; ?>
                </div>
            </section>
        </section>
    </main>
</body>

</html>

