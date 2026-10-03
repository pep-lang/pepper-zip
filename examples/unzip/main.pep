# Lists a zip archive, or extracts it into a directory, checking every
# entry's name and CRC-32 on the way.
#
# Usage: unzip archive.zip            (list the entries)
#        unzip archive.zip out-dir    (extract them into out-dir)
#   With no arguments, it writes a sample archive and lists that.

import io;
import zip;

main(args: String[]): int {
    var path = "sample.zip";
    if (args.count > 1) {
        path = args[1];
    } else {
        var writer = zip.Writer.create(path).value();
        writer.add("readme.txt", "A sample archive.\n".repeat(10).bytes()).value();
        writer.add_directory("src").value();
        writer.add("src/main.pep", "main(): int {\n    return 0;\n}\n".bytes()).value();
        writer.finish().value();
    }
    var opened = zip.Archive.open(path);
    if (opened.is_err()) {
        print(opened.error().message);
        return 1;
    }
    var archive = opened.value();
    if (args.count > 2) {
        var extracted = archive.extract_all(args[2]);
        if (extracted.is_err()) {
            print(extracted.error().message);
            return 1;
        }
        print($"extracted {archive.count} entries into {args[2]}");
        return 0;
    }
    for (var entry in archive.entries()) {
        var method = "stored";
        if (entry.method == zip.Method.Deflate) {
            method = "deflate";
        } else if (entry.method == zip.Method.Other) {
            method = $"method {entry.method_code}";
        }
        print($"{entry.size:10} {entry.compressed_size:10}  {method:10} {entry.name}");
    }
    if (args.count <= 1) {
        io.File.remove(io.Path(path));
    }
    return 0;
}
