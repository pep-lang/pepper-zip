# The example in the Pepper book's chapter (pep-lang/pepper,
# docs/src/language/compression.md, section "Zip archives"): keep the two
# the same.

import zip;

main(): int {
    var writer = zip.Writer.create("bundle.zip").value();
    writer.add("version.txt", "1.0.0".bytes()).value();
    writer.finish().value();

    var archive = zip.Archive.open("bundle.zip").value();
    for (var entry in archive.entries()) {
        print($"{entry.name}: {entry.size} bytes");
    }
    archive.extract_all("out").value();
    return 0;
}
