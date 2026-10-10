<?php
// Cyclomatic complexity per method of the PHP source on stdin, as JSON {"methodName": cc}, computed
// with sebastian/complexity, the same calculator php-code-coverage uses for Clover's `complexity`.
// Run from the repo root (it loads vendor/autoload.php). Used by crap-report.py for the merge-base copy
// of a changed file. Prints {} when the source does not parse.
//   git show <base>:<file> | php base-complexity.php

require getcwd().'/vendor/autoload.php';

$out = [];
try {
    foreach ((new SebastianBergmann\Complexity\Calculator)->calculateForSourceString((string) stream_get_contents(STDIN)) as $c) {
        if ($c->isMethod()) {
            $out[substr($c->name(), strrpos($c->name(), '::') + 2)] = $c->cyclomaticComplexity();
        }
    }
} catch (Throwable) {
    $out = null;
}
echo json_encode($out, JSON_FORCE_OBJECT);
