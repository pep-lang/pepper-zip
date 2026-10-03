## Zip archives: list, read and extract the entries of a `.zip` file, or
## write one.
##
## Bring it in with `import zip`. Entries are stored or compressed with
## DEFLATE (from the runtime's `compress` module); archives and entries
## past 4 GiB use ZIP64. Entries compressed another way, or encrypted, are
## listed but reading one is an error naming the entry and the method.
## Extracting checks every name, so an archive cannot write outside the
## target directory. Errors name the archive and the entry
## (`release.zip: entry 'lib/a.pep': CRC mismatch`), and a damaged
## archive is an `io.IoError` whose `is_invalid_input()` holds.
##
## - `Archive` and `EntryReader`: reading
## - `Writer`: writing
## - `Entry` and `Method`: what an entry is
##
## @example
##     import zip;
##
##     main(): int {
##         var writer = zip.Writer.create("bundle.zip").value();
##         writer.add("version.txt", "1.0.0".bytes()).value();
##         writer.add_directory("docs").value();
##         writer.finish().value();
##
##         var archive = zip.Archive.open("bundle.zip").value();
##         for (var entry in archive.entries()) {
##             print($"{entry.name}: {entry.size} bytes");
##         }
##         var version = archive.read(archive.find("version.txt").value()).value();
##         assert(version == "1.0.0".bytes(), "the contents");
##         archive.extract_all("out").value();
##         archive.close();
##         return 0;
##     }

# This file only gathers the module's public API from its other files.

import "entry";
import "reader";
import "writer";

export Archive;
export Entry;
export EntryReader;
export Method;
export Writer;
