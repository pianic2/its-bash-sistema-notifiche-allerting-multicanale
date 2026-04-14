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

$serviceList = services($data['SERVICES_STATUS']);

?>

<h1>Dashboard</h1>

<?php if ($warnings): ?>
<p><?= e(implode(' ', $warnings)) ?></p>
<?php endif; ?>

<p>Host: <?= e($data['HOST']) ?></p>
<p>IP: <?= e($data['IP_ADDRESS']) ?></p>
<p>Status: <b><?= e($data['OVERALL_STATUS']) ?></b></p>
<p>Time: <?= e($data['TIMESTAMP']) ?></p>

<h2>Resources</h2>
<p>Disk: <?= e($data['DISK_USAGE']) ?>% / threshold <?= e($data['DISK_THRESHOLD']) ?>%</p>
<p>Load: <?= e($data['LOAD_AVG']) ?> / threshold <?= e($data['LOAD_THRESHOLD']) ?></p>
<p>Uptime: <?= e($data['UPTIME_READABLE']) ?></p>
<p>Users connected: <?= e($data['USERS_CONNECTED']) ?></p>

<h2>Services</h2>
<?php if (!$serviceList): ?>
<p>No services data available.</p>
<?php else: ?>
<ul>
<?php foreach ($serviceList as [$name, $status]): ?>
  <li><?= e($name) ?> -> <?= e($status) ?></li>
<?php endforeach; ?>
</ul>
<?php endif; ?>
