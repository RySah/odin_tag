# odin_tag

An Odin package that scans source files for `@(tag = "...")` attributes and collects them.

For each tagged declaration (values, constants, procedures, structs, unions, enums, foreign blocks and foreign imports) it records:

- the tag value
- the declaration name and kind
- the location of the tag
- the start and end location of the declaration (`target_loc` / `target_end_loc`), the end covering the full body

## Usage

```odin
scanner := tag.make_scanner()
defer tag.delete_scanner(&scanner)

// File or directory; directories are scanned recursively.
// The optional third argument is the file suffix (default ".odin").
err := tag.scan_file_or_dir("src", &scanner)

for t in scanner.results {
    fmt.println(t.value, t.decl, t.target_loc.line, t.target_end_loc.line)
}
```

## Notes

- A file passed explicitly is scanned regardless of suffix; the suffix only filters files found in directories.
- Strings in the results are allocated with `context.temp_allocator`. Use or copy them before calling `free_all(context.temp_allocator)`.
