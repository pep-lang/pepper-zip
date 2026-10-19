# pepper-zip

Zip archives for [Pepper](https://github.com/justinboswell/pepper): list
the entries of a `.zip` file, read them, extract them safely, and write new
archives.

One module, **`zip`**:

- **`zip.Archive.open(path)`** (or `from_bytes(data)`) reads the central
  directory. `entries()` lists each `Entry`: `name`, `size`,
  `compressed_size`, `crc32`, `method`, `modified` (an `os.SystemTime`),
  `mode`, `comment`, `is_directory`, `is_encrypted`. `find(name)` looks
  one up.
- **`archive.read(entry)`** gives the contents in memory, and
  **`archive.open_entry(entry)`** an `EntryReader`, an `io.Reader` that
  decompresses as it is read. Both check the length and CRC-32.
- **`archive.extract_all(target)`** writes every entry under `target`,
  after checking every name, so no archive can write outside it ("zip
  slip"). `strip_components` drops leading directories, as tar's does.
- **`zip.Writer.create(path)`** (or `Writer(sink)` over any `io.Writer`)
  writes an archive: `add(name, data)`, `add_directory(name)`,
  `add_file(name, path)` and `add_stream(entry, reader)`, then
  `finish()`.

```pepper
import zip;

main(): int {
    var writer = zip.Writer.create("bundle.zip").value();
    writer.add_file("docs/readme.md", "readme.md").value();
    writer.add("version.txt", "1.0.0".bytes()).value();
    writer.finish().value();

    var opened = zip.Archive.open("bundle.zip");
    if (opened.is_err()) {
        print(opened.error().message);
        return 1;
    }
    var archive = opened.value();
    for (var entry in archive.entries()) {
        print($"{entry.name}: {entry.size} bytes");
    }
    archive.extract_all("out").value();
    return 0;
}
```

`examples/unzip` lists an archive or extracts it.

## What it reads and writes

- **Methods**: stored and DEFLATE, with the runtime's `compress` module.
  Entries compressed another way (bzip2, LZMA, zstd, ...) are listed, and
  reading one is an error naming it and the method, rather than the whole
  archive failing. An entry from memory that DEFLATE would not shrink is
  stored.
- **ZIP64** for entries and archives over 4 GiB and more than 65,535
  entries, read and written.
- **Names**: UTF-8 (with the language-encoding flag when not ASCII);
  older archives' names are code page 437 (`text.CodePage437`), and
  Info-ZIP's Unicode path field is read.
- **Times**: the Unix extended timestamp (to the second) is read and
  written besides the DOS time (local time to two seconds, taken as UTC
  when it is all there is).
- **Streaming writes**: `add_file` and `add_stream` read their source in
  chunks and put the sizes and CRC-32 in a data descriptor after the
  contents, so a large file need not fit in memory and the sink need not
  seek.
- **Errors** are `io.IoError`s naming the archive and entry
  (`release.zip: entry 'lib/a.pep': CRC mismatch`); damaged data is
  `is_invalid_input()`.
- Archives with data in front of them (self-extracting programs) are read.
  Archives split across several files are not.

## Using it

This repository is a package: `pep.toml` marks its root, and its root
`module.pep` is the `zip` module. Add it to a project under the name `zip`:

```sh
pepper package add justinboswell/pepper-zip --name zip
```

which writes

```toml
[dependencies]
zip = { github = "justinboswell/pepper-zip" }
```

Without a project, put a folder named `zip` that holds (or links to) this
repository on the import path: `pepper build -I packages main.pep`.

## Tests

```sh
tests/run.sh path/to/pepper
```

runs `tests/zip_test.pep` (archives written and read back, files on
disk, 70,000 entries, and the archives other tools made in `tests/data`)
and the unzip example, then, when Python and Info-ZIP's `unzip` are
installed, checks that both read an archive `tests/interop.pep` writes.
`tests/make_fixtures.py` remakes `tests/data`.

## Design

- **Its own repository**, like pepper-yaml and pepper-llvm,
  fetched by the package manager; `.tar.gz` stays in the runtime because
  the package manager needs it to fetch packages.
- **Encrypted entries are unsupported**: ZipCrypto and AES entries are
  listed with `is_encrypted`, and reading one is an error naming the
  entry and the kind. Support can come later without changing the API.
- **Writing goes to any `io.Writer`**, with no seeking: entries from
  memory carry their sizes in the local header, and streamed entries in a
  data descriptor. A dedicated non-seekable streaming mode was deferred;
  this design needs none.
- **The writer's name check** rejects empty and duplicate names; it does
  not rewrite names, so a writer can still make an archive with `..` in
  it, and readers (this one included) refuse to extract it.

## Releasing

CI (`.github/workflows/ci.yml`) runs the tests on Linux, macOS and
Windows for every push to `main` and every pull request. To release, set
`version` in `pep.toml`, merge, then push the matching tag
(`git tag v1.0.0 && git push origin v1.0.0`): CI tests the tag and
publishes a GitHub release for it. `pepper package add` and `pepper
package update` find versions by their tags.

## License

Apache-2.0; see [LICENSE](LICENSE).
