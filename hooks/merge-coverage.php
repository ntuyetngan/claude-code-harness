<?php declare(strict_types=1);
// Merge the --coverage-php dumps of several pest shards and write the clover and crap4j reports.
// usage: php merge-coverage.php <repo root> <clover.xml> <crap4j.xml> <app-file>... -- <shard.cov>...
// Pest's own --parallel merge writes an empty clover in this setup, so verify.sh runs the shards
// itself (one TEST_TOKEN database each) and merges here. A dump (php-code-coverage serialization
// format 3) holds the processed data with paths relative to a basePath plus the test results; the
// merged data is put back under absolute paths and into a CodeCoverage over the changed app files,
// which is what the report writers read.

use SebastianBergmann\CodeCoverage\CodeCoverage;
use SebastianBergmann\CodeCoverage\Driver\Selector;
use SebastianBergmann\CodeCoverage\Filter;
use SebastianBergmann\CodeCoverage\Report\Clover;
use SebastianBergmann\CodeCoverage\Report\Crap4j;
use SebastianBergmann\CodeCoverage\Serialization\Merger;

[$root, $clover, $crap4j] = array_slice($argv, 1, 3);
$rest = array_slice($argv, 4);
$sep = array_search('--', $rest, true);
if ($sep === false) {
    fwrite(STDERR, "usage: merge-coverage.php <root> <clover> <crap4j> <app-file>... -- <shard.cov>...\n");
    exit(64);
}
$appFiles = array_slice($rest, 0, $sep);
$shards = array_slice($rest, $sep + 1);
require $root . '/vendor/autoload.php';
foreach ($shards as $shard) {
    if (!is_file($shard) || filesize($shard) === 0) {
        fwrite(STDERR, "merge-coverage: missing or empty shard $shard\n");
        exit(1);
    }
}
// php-code-coverage before 13 has no Merger: its --coverage-php dump is a serialized CodeCoverage with absolute paths.
if (!class_exists(Merger::class)) {
    $coverage = null;
    foreach ($shards as $shard) {
        $part = include $shard;
        $coverage === null ? $coverage = $part : $coverage->merge($part);
    }
    (new Clover())->process($coverage, $clover);
    (new Crap4j())->process($coverage, $crap4j);
    echo 'merged ' . count($shards) . ' shard(s): ' . count($coverage->getData()->coveredFiles()) . " covered file(s)\n";
    exit(0);
}
$merged = (new Merger())->merge($shards, false, true, true);
$data = $merged['codeCoverage'];
$basePath = $merged['basePath'];
if ($basePath !== '') {
    foreach ($data->coveredFiles() as $relative) {
        $data->renameFile($relative, $basePath . DIRECTORY_SEPARATOR . $relative);
    }
}
$filter = new Filter();
foreach ($appFiles as $f) {
    $filter->includeFile(str_starts_with($f, '/') ? $f : $root . '/' . $f);
}
$coverage = new CodeCoverage((new Selector())->forLineCoverage($filter), $filter);
$coverage->setData($data);
$coverage->setTests($merged['testResults']);
$report = $coverage->getReport();
(new Clover())->process($report, $clover);
(new Crap4j())->process($report, $crap4j);
echo 'merged ' . count($shards) . ' shard(s): ' . count($data->coveredFiles()) . " covered file(s)\n";
