<?php
// Prepended to the main pest process by mutation.sh (php -d auto_prepend_file=...). When
// MUTATE_LINES_FILE names a JSON map {"app/Foo.php": [12, 13]}, Pest's mutation generator is replaced
// by one that only mutates those lines, intersected with the covered lines --covered-only passes in.
// Pest has the line filter internally (MutationGenerator::generate's $linesToMutate) but no CLI option
// for it. A file with no listed lines gets no mutants. Nothing in vendor/ or the source is edited.

$harnessLinesFile = getenv('MUTATE_LINES_FILE');
if (is_string($harnessLinesFile) && is_file($harnessLinesFile) && is_file(getcwd().'/vendor/autoload.php')) {
    require_once getcwd().'/vendor/autoload.php';
    if (class_exists(\Pest\Mutate\Support\MutationGenerator::class) && class_exists(\Pest\Support\Container::class)) {
        $harnessLines = [];
        foreach ((array) json_decode((string) file_get_contents($harnessLinesFile), true) as $rel => $lines) {
            $harnessLines[getcwd().'/'.$rel] = array_map('intval', (array) $lines);
        }

        $harnessGenerator = new class($harnessLines) extends \Pest\Mutate\Support\MutationGenerator
        {
            public function __construct(private readonly array $harnessLines) {}

            public function generate(\Symfony\Component\Finder\SplFileInfo $file, array $mutators, array $linesToMutate = [], array $classesToMutate = []): array
            {
                $added = $this->harnessLines[$file->getRealPath()] ?? $this->harnessLines[$file->getPathname()] ?? [];
                $lines = $linesToMutate === [] ? $added : array_values(array_intersect($linesToMutate, $added));
                if ($lines === []) {
                    return [];
                }

                return parent::generate($file, $mutators, $lines, $classesToMutate);
            }
        };

        \Pest\Support\Container::getInstance()->add(\Pest\Mutate\Support\MutationGenerator::class, $harnessGenerator);
        fwrite(STDERR, "[harness] mutation scoped to added lines (".count($harnessLines)." file(s))\n");
    }
}
