## `Archive` and `EntryReader`: reading a zip archive from a file or from
## memory, listing its entries, reading them, and extracting it safely.

import archive;
import compress;
import io;
import os;
import "entry";

# The bytes of an archive: an open file, read at any offset, or an array.
struct _Source {
    var _file: io.File?;
    var _data: u8[];
    var size: ulong;

    construct() {
        _file = Optional<io.File>.Empty;
        _data = Array<u8>();
    }

    # Appends up to `count` bytes from `offset` to `out`; fewer only at the
    # end of the archive.
    read_at(offset: ulong, count: ulong, out: u8[]): io.IoResult<ulong> {
        if (offset >= size) {
            return io.IoResult<ulong>.ok(0);
        }
        var want = count;
        if (want > size - offset) {
            want = size - offset;
        }
        if (_file.is_empty()) {
            out.append_all(_zip_slice(_data, offset, want));
            return io.IoResult<ulong>.ok(want);
        }
        var file = _file.value();
        var moved = file.seek_start(offset as io.Offset);
        if (moved.is_err()) {
            return io.IoResult<ulong>.err(moved.error());
        }
        ulong taken = 0;
        while (taken < want) {
            var chunk = want - taken;
            if (chunk > 65536) {
                chunk = 65536;
            }
            var read = file.read(out, chunk);
            if (read.is_err()) {
                return read;
            }
            if (read.value() == 0) {
                break;
            }
            taken += read.value();
        }
        return io.IoResult<ulong>.ok(taken);
    }

    # Exactly `count` bytes from `offset`, or `short` when the archive ends
    # first.
    read_exactly(offset: ulong, count: ulong, short: io.IoError): io.IoResult<u8[]> {
        var out = Array<u8>(count);
        var read = read_at(offset, count, out);
        if (read.is_err()) {
            return io.IoResult<u8[]>.err(read.error());
        }
        if (read.value() != count) {
            return io.IoResult<u8[]>.err(short);
        }
        return io.IoResult<u8[]>.ok(out);
    }
}

# A `Reader` of the bytes `[position, end)` of a source: one entry's stored
# contents.
struct _RangeReader {
    var _source: _Source;
    var _position: ulong;
    var _end: ulong;
    # The error when the source ends early.
    var _short: io.IoError;

    construct(source: _Source, start: ulong, count: ulong, short: io.IoError) {
        _source = source;
        _position = start;
        _end = start + count;
        _short = short;
    }

    read(buffer: u8[], max: ulong): io.IoResult<ulong> {
        var count = _end - _position;
        if (count > max) {
            count = max;
        }
        if (count > 65536) {
            count = 65536;
        }
        if (count == 0) {
            return io.IoResult<ulong>.ok(0);
        }
        var read = _source.read_at(_position, count, buffer);
        if (read.is_err()) {
            return read;
        }
        if (read.value() == 0) {
            return io.IoResult<ulong>.err(_short);
        }
        _position += read.value();
        return read;
    }
}

extend _RangeReader with io.Reader;

## Reads one entry's contents as a stream, decompressing them as they are
## read, so a large entry need not be in memory. It is an `io.Reader`.
##
## At the end of the contents it checks their length and CRC-32 against
## the central directory: a mismatch is an `is_invalid_input()` error
## naming the archive and the entry
## (`release.zip: entry 'lib/a.pep': CRC mismatch`).
##
## @example
##     import io;
##     import zip;
##
##     var archive = zip.Archive.open("logs.zip").value();
##     var reader = archive.open_entry(archive.find("today.log").value()).value();
##     for (var line in reader.lines()) {
##         print(line.value());
##     }
export struct EntryReader {
    # The decompressed contents.
    var _inner: io.Reader;
    var _crc: compress.Crc32;
    var _taken: ulong;
    var _entry: Entry;
    var _archive: String;
    var _done: bool;

    ## Makes a reader that passes on the bytes of `inner` and checks them
    ## against `entry`. `Archive.open_entry` makes one; this is for reading
    ## contents found some other way.
    ##
    ## @param inner the entry's uncompressed contents
    ## @param entry the entry, whose `size` and `crc32` the contents must
    ##   match
    ## @param archive the archive's name in messages
    construct(inner: io.Reader, entry: Entry, archive: String) {
        _inner = inner;
        _crc = compress.Crc32();
        _entry = entry;
        _archive = archive;
    }

    ## The entry being read.
    var entry: Entry {
        get {
            return _entry;
        }
    }

    ## Reads up to `max` more bytes of the contents and appends them to
    ## `buffer`.
    ##
    ## @param buffer the array the bytes are appended to
    ## @param max the most bytes to read
    ## @returns the number of bytes appended, 0 at the end of the contents;
    ##   an `is_invalid_input()` error when the contents are damaged, their
    ##   length or CRC-32 does not match the central directory, or the
    ##   archive is truncated, or the error reading the file
    read(buffer: u8[], max: ulong): io.IoResult<ulong> {
        if (_done || max == 0) {
            return io.IoResult<ulong>.ok(0);
        }
        var chunk = Array<u8>();
        var read = _inner.read(chunk, max);
        if (read.is_err()) {
            var error = read.error();
            if (error.is_invalid_input() && !error.message.starts_with(_archive)) {
                return io.IoResult<ulong>.err(_zip_entry_error(_archive, _entry.name, error.message));
            }
            return read;
        }
        if (read.value() == 0) {
            _done = true;
            if (_taken != _entry.size) {
                return io.IoResult<ulong>.err(
                    _zip_entry_error(_archive, _entry.name, $"size mismatch: {_taken} bytes, not {_entry.size}")
                );
            }
            if (_crc.value != _entry.crc32) {
                return io.IoResult<ulong>.err(_zip_entry_error(_archive, _entry.name, "CRC mismatch"));
            }
            return read;
        }
        _taken += read.value();
        if (_taken > _entry.size) {
            _done = true;
            return io.IoResult<ulong>.err(
                _zip_entry_error(_archive, _entry.name, $"size mismatch: more than {_entry.size} bytes")
            );
        }
        _crc.update(chunk);
        buffer.append_all(chunk);
        return read;
    }

    ## Reads the rest of the contents.
    ##
    ## @returns the bytes not read yet; an error as for `read`
    read_all(): io.IoResult<u8[]> {
        var result = Array<u8>();
        while (true) {
            var read = read(result, 65536);
            if (read.is_err()) {
                return io.IoResult<u8[]>.err(read.error());
            }
            if (read.value() == 0) {
                return io.IoResult<u8[]>.ok(result);
            }
        }
        return io.IoResult<u8[]>.ok(result);
    }
}

extend EntryReader with io.Reader;

## A zip archive opened for reading: its entries, listed from the central
## directory when it is opened, and their contents, read on demand.
##
## It reads stored and DEFLATE entries, ZIP64 archives (over 4 GiB, or
## over 65,535 entries), names in UTF-8 or code page 437, and archives with
## data before them, such as self-extracting programs. Entries compressed
## another way (bzip2, LZMA, zstd) or encrypted are listed, and reading one
## is an error naming it and the method, rather than the whole archive
## failing. Archives split across several files are not supported.
##
## Every error names the archive, and the entry when there is one
## (`release.zip: entry 'lib/a.pep': CRC mismatch`); a damaged archive is
## an `is_invalid_input()` error.
##
## @example
##     import zip;
##
##     main(): int {
##         var opened = zip.Archive.open("release.zip");
##         if (opened.is_err()) {
##             print(opened.error().message);
##             return 1;
##         }
##         var archive = opened.value();
##         for (var entry in archive.entries()) {
##             print($"{entry.name}: {entry.size} bytes");
##         }
##         archive.extract_all("out").value();
##         return 0;
##     }
export struct Archive {
    ## The archive's name in messages: the path it was opened from, or the
    ## name given to `from_bytes`.
    var name: String;
    ## The archive's comment; usually empty.
    var comment: String;
    var _entries: Entry[];
    var _source: _Source;

    ## Makes an empty archive in memory, with no entries. `open` and
    ## `from_bytes` read real ones.
    construct() {
        name = "archive.zip";
        comment = "";
        _entries = Array<Entry>();
        _source = _Source();
    }

    # An archive named `name` over `source`, its directory not read yet.
    static _over(name: String, source: _Source): Archive {
        var archive = Archive();
        archive.name = name;
        archive._source = source;
        return archive;
    }

    ## Opens the archive at `path` and reads its central directory. The file
    ## stays open, for reading entries, until `close()`.
    ##
    ## @param path the archive's path
    ## @returns the archive; the error opening the file, or an
    ##   `is_invalid_input()` error when it is not a zip archive or its
    ##   central directory is damaged
    static open(path: io.Path): io.IoResult<Archive> {
        var opened = io.File.open(path);
        if (opened.is_err()) {
            var error = opened.error();
            return io.IoResult<Archive>.err(io.IoError(error.code, $"{path.to_string()}: {error.message}"));
        }
        var file = opened.value();
        var length = file.seek_end(0);
        if (length.is_err()) {
            file.close();
            return io.IoResult<Archive>.err(length.error());
        }
        var source = _Source();
        source._file = Optional<io.File>.Value(file);
        source.size = length.value() as ulong;
        var archive = Archive._over(path.to_string(), source);
        var read = archive._read_directory();
        if (read.is_err()) {
            file.close();
            return io.IoResult<Archive>.err(read.error());
        }
        return io.IoResult<Archive>.ok(archive);
    }

    ## Reads an archive held in memory, such as a download.
    ##
    ## @param data the bytes of the archive
    ## @param name the archive's name in messages
    ## @returns the archive; an `is_invalid_input()` error when `data` is
    ##   not a zip archive or its central directory is damaged
    ## @example
    ##     var archive = zip.Archive.from_bytes(response.body, "download.zip").value();
    static from_bytes(data: u8[], name: String = "archive.zip"): io.IoResult<Archive> {
        var source = _Source();
        source._data = data;
        source.size = data.count;
        var archive = Archive._over(name, source);
        var read = archive._read_directory();
        if (read.is_err()) {
            return io.IoResult<Archive>.err(read.error());
        }
        return io.IoResult<Archive>.ok(archive);
    }

    ## The entries, in the order of the central directory.
    ##
    ## @returns the entries
    entries(): Entry[] {
        return _entries;
    }

    ## The number of entries.
    var count: ulong {
        get {
            return _entries.count;
        }
    }

    ## Finds the entry named `name`, the first one when several have it.
    ##
    ## @param name the entry's path in the archive
    ## @returns the entry, or none
    find(name: String): Entry? {
        for (var entry in _entries) {
            if (entry.name == name) {
                return Optional<Entry>.Value(entry);
            }
        }
        return Optional<Entry>.Empty;
    }

    ## Opens `entry` for reading its contents as a stream.
    ##
    ## @param entry an entry of this archive
    ## @returns a reader of the contents; an `is_invalid_input()` error
    ##   when the entry is encrypted, uses a method other than stored or
    ##   DEFLATE, or its local header is damaged
    open_entry(entry: Entry): io.IoResult<EntryReader> {
        if (entry.is_encrypted) {
            var kind = "ZipCrypto";
            if (entry.method_code == 99) {
                kind = "AES";
            } else if ((entry._flags & 64) != 0) {
                kind = "strong encryption";
            }
            return io.IoResult<EntryReader>.err(
                _zip_entry_error(name, entry.name, $"is encrypted ({kind}); encrypted entries are not supported")
            );
        }
        if (entry.method == Method.Other) {
            var method = _zip_method_name(entry.method_code);
            return io.IoResult<EntryReader>.err(
                _zip_entry_error(
                    name, entry.name, $"compression method {method} ({entry.method_code}) is not supported"
                )
            );
        }
        var short = _zip_entry_error(name, entry.name, "the archive is truncated");
        var header = _source.read_exactly(entry._offset, 30, short);
        if (header.is_err()) {
            return io.IoResult<EntryReader>.err(header.error());
        }
        var bytes = header.value();
        if (_zip_number(bytes, 0, 4) != _ZIP_LOCAL_HEADER) {
            return io.IoResult<EntryReader>.err(_zip_entry_error(name, entry.name, "local header not found"));
        }
        var start = entry._offset + 30 + _zip_number(bytes, 26, 2) + _zip_number(bytes, 28, 2);
        if (start > _source.size || entry.compressed_size > _source.size - start) {
            return io.IoResult<EntryReader>.err(short);
        }
        var range = _RangeReader(_source, start, entry.compressed_size, short);
        if (entry.method == Method.Deflate) {
            var inflated = compress.DecompressReader(range, compress.Format.Raw);
            return io.IoResult<EntryReader>.ok(EntryReader(inflated, entry, name));
        }
        return io.IoResult<EntryReader>.ok(EntryReader(range, entry, name));
    }

    ## Reads all of `entry`'s contents into memory, checking their length
    ## and CRC-32.
    ##
    ## @param entry an entry of this archive
    ## @returns the contents; an error as for `open_entry` and
    ##   `EntryReader.read`
    read(entry: Entry): io.IoResult<u8[]> {
        var opened = open_entry(entry);
        if (opened.is_err()) {
            return io.IoResult<u8[]>.err(opened.error());
        }
        return opened.value().read_all();
    }

    ## Extracts every entry into the directory `target`, creating it and the
    ## directories the entries need, and checking each entry's CRC-32.
    ##
    ## Every entry's name is checked with `archive.safe_components` before
    ## anything is written, so that no archive can write outside `target`
    ## ("zip slip"): an absolute path, a `..` component, a `\` or a `:` (a
    ## Windows drive) is an `is_invalid_input()` error. Files are written, replacing a file
    ## already there; symbolic links are skipped, as are permission bits and
    ## modification times.
    ##
    ## @param target the directory to extract into
    ## @param strip_components how many leading path components to drop from
    ##   each entry, as tar's `--strip-components` does; an entry with no
    ##   components left is skipped
    ## @returns an Ok result once every entry is extracted; an
    ##   `is_invalid_input()` error for an unsafe name or a damaged entry,
    ##   or the error of a file that could not be written
    extract_all(target: io.Path, strip_components: ulong = 0): io.IoResult<void> {
        var created = io.Directory.create_all(target);
        if (created.is_err()) {
            return created;
        }
        # Every name is checked before anything is written.
        for (var entry in _entries) {
            if (!entry.is_symlink && archive.safe_components(entry.name).is_empty()) {
                return io.IoResult<void>.err(
                    _zip_entry_error(name, entry.name, "unsafe path, which could write outside the target directory")
                );
            }
        }
        for (var entry in _entries) {
            if (entry.is_symlink) {
                continue;
            }
            var components = archive.safe_components(entry.name);
            var destination = target;
            var index = strip_components;
            while (index < components.value().count) {
                destination = destination.join(components.value()[index]);
                index += 1;
            }
            if (strip_components >= components.value().count) {
                continue;
            }
            if (entry.is_directory) {
                var made = io.Directory.create_all(destination);
                if (made.is_err()) {
                    return made;
                }
                continue;
            }
            var parent = destination.parent();
            if (parent.is_value()) {
                var made = io.Directory.create_all(parent.value());
                if (made.is_err()) {
                    return made;
                }
            }
            var written = _extract_entry(entry, destination);
            if (written.is_err()) {
                return written;
            }
        }
        return io.IoResult<void>.ok();
    }

    # Writes `entry`'s contents to a new file at `destination`.
    _extract_entry(entry: Entry, destination: io.Path): io.IoResult<void> {
        var opened = open_entry(entry);
        if (opened.is_err()) {
            return io.IoResult<void>.err(opened.error());
        }
        var reader = opened.value();
        var created = io.File.create(destination);
        if (created.is_err()) {
            return io.IoResult<void>.err(created.error());
        }
        var file = created.value();
        while (true) {
            var chunk = Array<u8>();
            var read = reader.read(chunk, 65536);
            if (read.is_err()) {
                file.close();
                return io.IoResult<void>.err(read.error());
            }
            if (read.value() == 0) {
                break;
            }
            var written = file.write_all(chunk);
            if (written.is_err()) {
                file.close();
                return written;
            }
        }
        return file.close();
    }

    ## Closes the archive's file. Reading entries afterwards fails; an
    ## archive read from memory has nothing to close.
    ##
    ## @returns an Ok result; the error closing the file
    close(): io.IoResult<void> {
        if (_source._file.is_empty()) {
            return io.IoResult<void>.ok();
        }
        return _source._file.value().close();
    }

    # Finds the end of central directory record and reads the central
    # directory into `_entries`.
    _read_directory(): io.IoResult<void> {
        var size = _source.size;
        var not_zip = _zip_error(name, "not a zip archive (no end of central directory record)");
        if (size < 22) {
            return io.IoResult<void>.err(not_zip);
        }
        # The record is 22 bytes and a comment of up to 65,535 bytes.
        ulong tail_start = 0;
        if (size > 22 + 65535) {
            tail_start = size - 22 - 65535;
        }
        var short = _zip_error(name, "the archive is truncated");
        var read = _source.read_exactly(tail_start, size - tail_start, short);
        if (read.is_err()) {
            return io.IoResult<void>.err(read.error());
        }
        var tail = read.value();
        var at = tail.count - 22;
        var found = false;
        while (true) {
            if (_zip_number(tail, at, 4) == _ZIP_END && at + 22 + _zip_number(tail, at + 20, 2) <= tail.count) {
                found = true;
                break;
            }
            if (at == 0) {
                break;
            }
            at -= 1;
        }
        if (!found) {
            return io.IoResult<void>.err(not_zip);
        }
        var end = tail_start + at;
        var disk = _zip_number(tail, at + 4, 2);
        var directory_disk = _zip_number(tail, at + 6, 2);
        var disk_entries = _zip_number(tail, at + 8, 2);
        var entries = _zip_number(tail, at + 10, 2);
        var directory_size = _zip_number(tail, at + 12, 4);
        var directory_offset = _zip_number(tail, at + 16, 4);
        comment = _zip_decode_text(_zip_slice(tail, at + 22, _zip_number(tail, at + 20, 2)), false);
        # Where the central directory must end: at the ZIP64 end record when
        # there is one, else at this record.
        var directory_end = end;
        if (end >= 20) {
            var locator = _source.read_exactly(end - 20, 20, short);
            if (locator.is_err()) {
                return io.IoResult<void>.err(locator.error());
            }
            if (_zip_number(locator.value(), 0, 4) == _ZIP64_LOCATOR) {
                var record_offset = _zip_number(locator.value(), 8, 8);
                if (record_offset > end - 20 || end - 20 - record_offset < 56) {
                    return io.IoResult<void>.err(
                        _zip_error(name, "the ZIP64 end of central directory locator is invalid")
                    );
                }
                # Data before the archive moves the record by as much as it
                # moves everything else; the record is just before the locator.
                var record_at = end - 20 - 56;
                var record = _source.read_exactly(record_at, 56, short);
                if (record.is_err()) {
                    return io.IoResult<void>.err(record.error());
                }
                var fields = record.value();
                if (_zip_number(fields, 0, 4) != _ZIP64_END) {
                    record_at = record_offset;
                    record = _source.read_exactly(record_at, 56, short);
                    if (record.is_err()) {
                        return io.IoResult<void>.err(record.error());
                    }
                    fields = record.value();
                    if (_zip_number(fields, 0, 4) != _ZIP64_END) {
                        return io.IoResult<void>.err(
                            _zip_error(name, "the ZIP64 end of central directory record is missing")
                        );
                    }
                }
                disk = _zip_number(fields, 16, 4);
                directory_disk = _zip_number(fields, 20, 4);
                disk_entries = _zip_number(fields, 24, 8);
                entries = _zip_number(fields, 32, 8);
                directory_size = _zip_number(fields, 40, 8);
                directory_offset = _zip_number(fields, 48, 8);
                directory_end = record_at;
            }
        }
        if (disk != 0 || directory_disk != 0 || disk_entries != entries) {
            return io.IoResult<void>.err(_zip_error(name, "archives split across several files are not supported"));
        }
        if (directory_size > directory_end || directory_offset > directory_end - directory_size) {
            return io.IoResult<void>.err(_zip_error(name, "the central directory is outside the archive"));
        }
        # Data before the archive (a self-extracting program) shifts every
        # offset by its length.
        var base = directory_end - directory_size - directory_offset;
        if (entries > directory_size / 46) {
            return io.IoResult<void>.err(_zip_error(name, "the central directory is too small for its entry count"));
        }
        var directory = _source.read_exactly(base + directory_offset, directory_size, short);
        if (directory.is_err()) {
            return io.IoResult<void>.err(directory.error());
        }
        return _parse_directory(directory.value(), entries, base);
    }

    # Reads `count` central directory headers from `data` into `_entries`.
    _parse_directory(data: u8[], count: ulong, base: ulong): io.IoResult<void> {
        var damaged = io.IoResult<void>.err(_zip_error(name, "the central directory is damaged"));
        ulong at = 0;
        ulong index = 0;
        while (index < count) {
            if (at + 46 > data.count || _zip_number(data, at, 4) != _ZIP_CENTRAL_HEADER) {
                return damaged;
            }
            var made_by = _zip_number(data, at + 4, 2);
            var flags = _zip_number(data, at + 8, 2);
            var method_code = _zip_number(data, at + 10, 2);
            var time = _zip_number(data, at + 12, 2);
            var date = _zip_number(data, at + 14, 2);
            var name_size = _zip_number(data, at + 28, 2);
            var extra_size = _zip_number(data, at + 30, 2);
            var comment_size = _zip_number(data, at + 32, 2);
            var external = _zip_number(data, at + 38, 4);
            var next = at + 46 + name_size + extra_size + comment_size;
            if (next > data.count) {
                return damaged;
            }
            var raw_name = _zip_slice(data, at + 46, name_size);
            var utf8 = (flags & 2048) != 0;
            var entry = Entry(_zip_decode_text(raw_name, utf8), _zip_method(method_code as uint));
            entry.method_code = method_code as uint;
            entry.crc32 = _zip_number(data, at + 16, 4) as uint;
            entry.compressed_size = _zip_number(data, at + 20, 4);
            entry.size = _zip_number(data, at + 24, 4);
            entry._offset = _zip_number(data, at + 42, 4);
            entry._flags = flags as uint;
            entry.is_encrypted = (flags & 1) != 0;
            entry.comment = _zip_decode_text(_zip_slice(data, at + 46 + name_size + extra_size, comment_size), utf8);
            entry.modified = _zip_from_dos(date, time);
            entry.mode = 0;
            var disk = _zip_number(data, at + 34, 2);
            var extra = _zip_slice(data, at + 46 + name_size, extra_size);
            var parsed = _read_extra(entry, extra, raw_name);
            if (parsed.is_err()) {
                return parsed;
            }
            if (disk != 0 && disk != _ZIP_MAX16) {
                return io.IoResult<void>.err(_zip_error(name, "archives split across several files are not supported"));
            }
            entry._offset += base;
            # Unix hosts keep `st_mode` in the high half of the attributes.
            if ((made_by >> 8) == 3) {
                var unix = external >> 16;
                entry.mode = (unix & 4095) as uint;
                var kind = unix & 61440;
                entry.is_symlink = kind == 40960;
                if (kind == 16384) {
                    entry.is_directory = true;
                }
            }
            # The MS-DOS directory attribute.
            if ((external & 16) != 0 && entry.size == 0 && (made_by >> 8) != 3) {
                entry.is_directory = true;
            }
            _entries.append(entry);
            at = next;
            index += 1;
        }
        return io.IoResult<void>.ok();
    }

    # Applies the extra fields of an entry's central header: ZIP64 sizes and
    # offset, the Unix extended timestamp, and Info-ZIP's Unicode path.
    _read_extra(entry: Entry, extra: u8[], raw_name: u8[]): io.IoResult<void> {
        ulong at = 0;
        while (at + 4 <= extra.count) {
            var id = _zip_number(extra, at, 2);
            var size = _zip_number(extra, at + 2, 2);
            var start = at + 4;
            if (start + size > extra.count) {
                break;
            }
            if (id == 1) {
                # Only the fields whose 32-bit value is full are here, in
                # this order.
                var field = start;
                var field_end = start + size;
                if (entry.size == _ZIP_MAX32) {
                    if (field + 8 > field_end) {
                        return io.IoResult<void>.err(
                            _zip_entry_error(name, entry.name, "the ZIP64 extra field is too short")
                        );
                    }
                    entry.size = _zip_number(extra, field, 8);
                    field += 8;
                }
                if (entry.compressed_size == _ZIP_MAX32) {
                    if (field + 8 > field_end) {
                        return io.IoResult<void>.err(
                            _zip_entry_error(name, entry.name, "the ZIP64 extra field is too short")
                        );
                    }
                    entry.compressed_size = _zip_number(extra, field, 8);
                    field += 8;
                }
                if (entry._offset == _ZIP_MAX32) {
                    if (field + 8 > field_end) {
                        return io.IoResult<void>.err(
                            _zip_entry_error(name, entry.name, "the ZIP64 extra field is too short")
                        );
                    }
                    entry._offset = _zip_number(extra, field, 8);
                    field += 8;
                }
            } else if (id == 0x5455) {
                # The modification time, when its flag is set: a signed
                # 32-bit count of seconds since 1970.
                if (size >= 5 && (extra[start] & 1) != 0) {
                    var seconds = _zip_number(extra, start + 1, 4) as long;
                    if (seconds >= 2147483648) {
                        seconds -= 4294967296;
                    }
                    entry.modified = os.SystemTime.from_unix_seconds(seconds);
                }
            } else if (id == 0x7075) {
                # A UTF-8 name, used when it was made from the name stored.
                if (size >= 5
                    && extra[start] == 1
                    && _zip_number(extra, start + 1, 4) == compress.Crc32.of(raw_name) as ulong) {
                    entry.name = _zip_decode_text(_zip_slice(extra, start + 5, size - 5), true);
                    entry.is_directory = entry.name.ends_with("/");
                }
            }
            at = start + size;
        }
        return io.IoResult<void>.ok();
    }
}
