## `Writer`: writing a zip archive to a file or any stream.

import compress;
import io;
import os;
import text;
import "entry";

# A `Writer` that passes everything to another and counts the bytes, so the
# zip writer knows each record's offset without seeking.
struct _CountingWriter {
    var _sink: io.Writer;
    var count: ulong;

    construct(sink: io.Writer) {
        _sink = sink;
    }

    write(data: u8[]): io.IoResult<ulong> {
        var written = _sink.write(data);
        if (written.is_ok()) {
            count += written.value();
        }
        return written;
    }

    write_all(data: u8[]): io.IoResult<void> {
        var written = _sink.write_all(data);
        if (written.is_ok()) {
            count += data.count;
        }
        return written;
    }
}

extend _CountingWriter with io.Writer;

## Writes a zip archive: each `add` writes one entry's local header and
## contents, and `finish()` writes the central directory that lists them.
##
## Each entry is stored or compressed with DEFLATE, as its method says; an
## entry from memory that DEFLATE would not make smaller is stored instead.
## Names are written in UTF-8, with the flag that says so when they are not
## ASCII, and each entry carries its modification time to the second (the
## Unix extended timestamp) besides the format's two-second local time.
## ZIP64 records are added where an entry, an offset or the entry count
## needs them, so archives and entries may pass 4 GiB and 65,535 entries.
##
## Entries from a stream (`add_file`, `add_stream`) are written as they
## are read, with their sizes and CRC-32 in a data descriptor after the
## contents, so the sink need not seek and the file need not fit in
## memory. Nothing is written in the background: errors come back from the
## call that hit them, and an archive whose `finish()` was not reached is
## incomplete.
##
## @example
##     import zip;
##
##     main(): int {
##         var writer = zip.Writer.create("bundle.zip").value();
##         writer.add_file("docs/readme.md", "readme.md").value();
##         writer.add("version.txt", "1.0.0".bytes()).value();
##         writer.finish().value();
##         return 0;
##     }
export struct Writer {
    ## The archive's comment, written by `finish()`.
    var comment: String;
    ## The DEFLATE level for compressed entries, from 1 (fastest) through 9
    ## (smallest); 6 by default, as zlib's.
    var level: int;
    ## The archive's name in messages.
    var name: String;
    var _out: _CountingWriter;
    # The file `create` opened, which `finish()` closes.
    var _file: io.File?;
    # The central directory headers written so far, and how many.
    var _central: u8[];
    var _count: ulong;
    var _names: Set<String>;
    var _finished: bool;

    ## Makes a writer of a new archive into `sink`. `finish()` does not
    ## close it.
    ##
    ## @param sink the stream the archive is written to
    ## @param name the archive's name in messages
    construct(sink: io.Writer, name: String = "archive.zip") {
        _out = _CountingWriter(sink);
        _file = Optional<io.File>.Empty;
        _central = Array<u8>();
        _names = Set<String>();
        comment = "";
        level = 6;
        this.name = name;
    }

    ## Creates (or truncates) the file at `path` and makes a writer of a new
    ## archive into it. `finish()` closes the file.
    ##
    ## @param path the archive's path
    ## @returns the writer; the error creating the file
    static create(path: io.Path): io.IoResult<Writer> {
        var created = io.File.create(path);
        if (created.is_err()) {
            var error = created.error();
            return io.IoResult<Writer>.err(io.IoError(error.code, $"{path.to_string()}: {error.message}"));
        }
        var writer = Writer(created.value(), path.to_string());
        writer._file = Optional<io.File>.Value(created.value());
        return io.IoResult<Writer>.ok(writer);
    }

    ## Adds a file entry holding `data`, modified now.
    ##
    ## @param name the entry's path in the archive, with `/` between
    ##   components
    ## @param data the contents
    ## @param method how to store the contents
    ## @returns an Ok result; an error when writing fails, or an
    ##   `is_invalid_input()` error when `name` is empty or already added
    ## @panics if `finish()` was called ("zip.Writer used after finish()")
    add(name: String, data: u8[], method: Method = Method.Deflate): io.IoResult<void> {
        return add_entry(Entry(name, method), data);
    }

    ## Adds a directory entry, modified now.
    ##
    ## @param name the directory's path in the archive; a final `/` is
    ##   added when missing
    ## @returns an Ok result; an error as for `add`
    ## @panics if `finish()` was called ("zip.Writer used after finish()")
    add_directory(name: String): io.IoResult<void> {
        var path = name;
        if (!path.ends_with("/")) {
            path += "/";
        }
        return add_entry(Entry(path, Method.Stored), Array<u8>());
    }

    ## Adds an entry with the header fields of `entry` (name, method,
    ## modification time, mode, comment) and the contents `data`. The size
    ## and CRC-32 written are those of `data`, whatever `entry` holds, and
    ## a directory (a name ending with `/`) is written with no contents.
    ##
    ## @param entry the entry's header fields
    ## @param data the contents
    ## @returns an Ok result; an error as for `add`
    ## @panics if `finish()` was called ("zip.Writer used after finish()")
    add_entry(entry: Entry, data: u8[]): io.IoResult<void> {
        var checked = _check_name(entry.name);
        if (checked.is_err()) {
            return checked;
        }
        var contents = data;
        if (entry.name.ends_with("/")) {
            contents = Array<u8>();
        }
        var method = entry.method;
        if (method == Method.Other) {
            method = Method.Deflate;
        }
        var stored = contents;
        if (method == Method.Deflate && !contents.is_empty) {
            var packed = compress.Deflate.compress(contents, level);
            if (packed.count < contents.count) {
                stored = packed;
            } else {
                method = Method.Stored;
            }
        }
        if (contents.is_empty) {
            method = Method.Stored;
        }
        var header = _Header(entry, method, _out.count);
        header.crc32 = compress.Crc32.of(contents);
        header.size = contents.count;
        header.compressed_size = stored.count;
        header.zip64 = header.size >= _ZIP_MAX32 || header.compressed_size >= _ZIP_MAX32;
        var written = _out.write_all(header.local());
        if (written.is_err()) {
            return written;
        }
        written = _out.write_all(stored);
        if (written.is_err()) {
            return written;
        }
        _record(header);
        return io.IoResult<void>.ok();
    }

    ## Adds the file at `path` as the entry `name`, reading it in chunks so
    ## it need not fit in memory. The entry takes the file's modification
    ## time and, on Unix, its permission bits.
    ##
    ## @param name the entry's path in the archive
    ## @param path the file to add
    ## @param method how to store the contents
    ## @returns an Ok result; the error reading the file, or an error as for
    ##   `add`
    ## @panics if `finish()` was called ("zip.Writer used after finish()")
    add_file(name: String, path: io.Path, method: Method = Method.Deflate): io.IoResult<void> {
        var opened = io.File.open(path);
        if (opened.is_err()) {
            var error = opened.error();
            return io.IoResult<void>.err(io.IoError(error.code, $"{path.to_string()}: {error.message}"));
        }
        var file = opened.value();
        var entry = Entry(name, method);
        var metadata = file.metadata();
        if (metadata.is_ok()) {
            var info = metadata.value();
            entry.size = info.size;
            entry.modified = os.SystemTime.from_unix_nanoseconds(info.modified);
            _set_mode(entry, info.permissions);
        }
        var added = add_stream(entry, file);
        var closed = file.close();
        if (added.is_err()) {
            return added;
        }
        return closed;
    }

    ## Adds an entry with the header fields of `entry` whose contents are
    ## read from `source` to its end, compressing them as they are read.
    ##
    ## The sizes and CRC-32 go in a data descriptor after the contents. Set
    ## `entry.size` to the expected size when it may reach 4 GiB, so the
    ## local header carries ZIP64 sizes as the format asks; the central
    ## directory is right either way.
    ##
    ## @param entry the entry's header fields
    ## @param source the stream holding the contents
    ## @returns an Ok result; the error reading `source`, or an error as for
    ##   `add`
    ## @panics if `finish()` was called ("zip.Writer used after finish()")
    add_stream(entry: Entry, source: io.Reader): io.IoResult<void> {
        var checked = _check_name(entry.name);
        if (checked.is_err()) {
            return checked;
        }
        var method = entry.method;
        if (method == Method.Other) {
            method = Method.Deflate;
        }
        var header = _Header(entry, method, _out.count);
        header.flags = header.flags | 8;
        # Room for DEFLATE's few bytes of growth on data that does not
        # compress.
        header.zip64 = entry.size >= _ZIP_MAX32 - (entry.size / 64) - 65536;
        var written = _out.write_all(header.local());
        if (written.is_err()) {
            return written;
        }
        var start = _out.count;
        var crc = compress.Crc32();
        ulong size = 0;
        var deflater = Optional<compress.CompressWriter>.Empty;
        if (method == Method.Deflate) {
            deflater = Optional<compress.CompressWriter>.Value(
                compress.CompressWriter(_out, compress.Format.Raw, level)
            );
        }
        while (true) {
            var chunk = Array<u8>();
            var read = source.read(chunk, 65536);
            if (read.is_err()) {
                return io.IoResult<void>.err(read.error());
            }
            if (read.value() == 0) {
                break;
            }
            crc.update(chunk);
            size += read.value();
            if (deflater.is_value()) {
                written = deflater.value().write_all(chunk);
            } else {
                written = _out.write_all(chunk);
            }
            if (written.is_err()) {
                return written;
            }
        }
        if (deflater.is_value()) {
            written = deflater.value().finish();
            if (written.is_err()) {
                return written;
            }
        }
        header.crc32 = crc.value;
        header.size = size;
        header.compressed_size = _out.count - start;
        var descriptor = Array<u8>();
        _zip_put(descriptor, _ZIP_DATA_DESCRIPTOR, 4);
        _zip_put(descriptor, header.crc32 as ulong, 4);
        if (header.zip64 || size >= _ZIP_MAX32 || header.compressed_size >= _ZIP_MAX32) {
            _zip_put(descriptor, header.compressed_size, 8);
            _zip_put(descriptor, size, 8);
        } else {
            _zip_put(descriptor, header.compressed_size, 4);
            _zip_put(descriptor, size, 4);
        }
        written = _out.write_all(descriptor);
        if (written.is_err()) {
            return written;
        }
        _record(header);
        return io.IoResult<void>.ok();
    }

    ## Writes the central directory and the end records, then closes the file
    ## when `create` opened it. Later calls do nothing.
    ##
    ## @returns an Ok result; an error when writing or closing fails
    finish(): io.IoResult<void> {
        if (_finished) {
            return io.IoResult<void>.ok();
        }
        _finished = true;
        var offset = _out.count;
        var size = _central.count as ulong;
        var written = _out.write_all(_central);
        if (written.is_err()) {
            return written;
        }
        var end = Array<u8>();
        if (_count >= _ZIP_MAX16 || offset >= _ZIP_MAX32 || size >= _ZIP_MAX32) {
            var record_offset = _out.count;
            _zip_put(end, _ZIP64_END, 4);
            _zip_put(end, 44, 8);
            _zip_put(end, _HEADER_MADE_BY, 2);
            _zip_put(end, 45, 2);
            _zip_put(end, 0, 4);
            _zip_put(end, 0, 4);
            _zip_put(end, _count, 8);
            _zip_put(end, _count, 8);
            _zip_put(end, size, 8);
            _zip_put(end, offset, 8);
            _zip_put(end, _ZIP64_LOCATOR, 4);
            _zip_put(end, 0, 4);
            _zip_put(end, record_offset, 8);
            _zip_put(end, 1, 4);
        }
        var comment_bytes = text.Utf8.encode(comment);
        if (comment_bytes.count > _ZIP_MAX16) {
            comment_bytes = _zip_slice(comment_bytes, 0, _ZIP_MAX16);
        }
        _zip_put(end, _ZIP_END, 4);
        _zip_put(end, 0, 2);
        _zip_put(end, 0, 2);
        _zip_put(end, _zip_min(_count, _ZIP_MAX16), 2);
        _zip_put(end, _zip_min(_count, _ZIP_MAX16), 2);
        _zip_put(end, _zip_min(size, _ZIP_MAX32), 4);
        _zip_put(end, _zip_min(offset, _ZIP_MAX32), 4);
        _zip_put(end, comment_bytes.count, 2);
        end.append_all(comment_bytes);
        written = _out.write_all(end);
        if (written.is_err()) {
            return written;
        }
        if (_file.is_value()) {
            return _file.value().close();
        }
        return io.IoResult<void>.ok();
    }

    # Checks that a new entry may be named `name`.
    _check_name(name: String): io.IoResult<void> {
        assert(!_finished, "zip.Writer used after finish()");
        if (name.is_empty || name == "/") {
            return io.IoResult<void>.err(_zip_error(this.name, "an entry needs a name"));
        }
        if (name.size > _ZIP_MAX16) {
            return io.IoResult<void>.err(_zip_entry_error(this.name, name, "the name is longer than 65,535 bytes"));
        }
        if (!_names.insert(name)) {
            return io.IoResult<void>.err(_zip_entry_error(this.name, name, "is already in the archive"));
        }
        return io.IoResult<void>.ok();
    }

    # Adds `header`'s central directory header to those `finish()` writes.
    _record(header: _Header) {
        _central.append_all(header.central());
        _count += 1;
    }
}

# Version 4.5 of the format (ZIP64), made on Unix.
const _HEADER_MADE_BY: ulong = 0x032D;

# The smaller of two numbers.
_zip_min(a: ulong, b: ulong): ulong {
    if (a < b) {
        return a;
    }
    return b;
}

# Sets `entry.mode` from a file's permission bits on Unix; Windows
# attributes are not Unix modes, so the default stays.
[Target(!OS(Windows))]
_set_mode(entry: Entry, permissions: io.Mode) {
    entry.mode = permissions & 4095;
}

[Target(OS(Windows))]
_set_mode(entry: Entry, permissions: io.Mode) {}

# The fields of one entry's local and central headers.
struct _Header {
    var name: u8[];
    var comment: u8[];
    var flags: ulong;
    var method: Method;
    var date: ulong;
    var time: ulong;
    var seconds: long;
    var crc32: uint;
    var size: ulong;
    var compressed_size: ulong;
    var offset: ulong;
    var zip64: bool;
    var is_directory: bool;
    var mode: ulong;

    construct(entry: Entry, method: Method, offset: ulong) {
        name = text.Utf8.encode(entry.name);
        comment = text.Utf8.encode(entry.comment);
        if (comment.count > _ZIP_MAX16) {
            comment = _zip_slice(comment, 0, _ZIP_MAX16);
        }
        if (!text.Ascii.is_ascii(entry.name) || !text.Ascii.is_ascii(entry.comment)) {
            flags = 2048;
        }
        this.method = method;
        var (dos_date, dos_time) = _zip_to_dos(entry.modified);
        date = dos_date;
        time = dos_time;
        seconds = entry.modified.unix_seconds();
        if (seconds < -2147483648) {
            seconds = -2147483648;
        }
        if (seconds > 2147483647) {
            seconds = 2147483647;
        }
        this.offset = offset;
        is_directory = entry.name.ends_with("/");
        mode = entry.mode as ulong;
    }

    # The version needed to extract: 4.5 for ZIP64, 2.0 for DEFLATE and
    # directories.
    _needed(): ulong {
        if (zip64 || size >= _ZIP_MAX32 || compressed_size >= _ZIP_MAX32 || offset >= _ZIP_MAX32) {
            return 45;
        }
        return 20;
    }

    # The extended timestamp extra field: the modification time.
    _timestamp(out: u8[]) {
        _zip_put(out, 0x5455, 2);
        _zip_put(out, 5, 2);
        out.append(1);
        _zip_put(out, (seconds as ulong) & _ZIP_MAX32, 4);
    }

    # The local file header, with the name and extra fields.
    local(): u8[] {
        var out = Array<u8>();
        var extra = Array<u8>();
        var descriptor = (flags & 8) != 0;
        _zip_put(out, _ZIP_LOCAL_HEADER, 4);
        _zip_put(out, _needed(), 2);
        _zip_put(out, flags, 2);
        _zip_put(out, _zip_method_code(method) as ulong, 2);
        _zip_put(out, time, 2);
        _zip_put(out, date, 2);
        if (descriptor) {
            _zip_put(out, 0, 4);
        } else {
            _zip_put(out, crc32 as ulong, 4);
        }
        if (zip64) {
            _zip_put(out, _ZIP_MAX32, 4);
            _zip_put(out, _ZIP_MAX32, 4);
            _zip_put(extra, 1, 2);
            _zip_put(extra, 16, 2);
            if (descriptor) {
                _zip_put(extra, 0, 8);
                _zip_put(extra, 0, 8);
            } else {
                _zip_put(extra, size, 8);
                _zip_put(extra, compressed_size, 8);
            }
        } else if (descriptor) {
            _zip_put(out, 0, 4);
            _zip_put(out, 0, 4);
        } else {
            _zip_put(out, compressed_size, 4);
            _zip_put(out, size, 4);
        }
        _timestamp(extra);
        _zip_put(out, name.count, 2);
        _zip_put(out, extra.count, 2);
        out.append_all(name);
        out.append_all(extra);
        return out;
    }

    # The central directory header, with the name, extra fields and comment.
    central(): u8[] {
        var out = Array<u8>();
        var extra = Array<u8>();
        var zip64_fields = Array<u8>();
        if (size >= _ZIP_MAX32) {
            _zip_put(zip64_fields, size, 8);
        }
        if (compressed_size >= _ZIP_MAX32) {
            _zip_put(zip64_fields, compressed_size, 8);
        }
        if (offset >= _ZIP_MAX32) {
            _zip_put(zip64_fields, offset, 8);
        }
        if (!zip64_fields.is_empty) {
            _zip_put(extra, 1, 2);
            _zip_put(extra, zip64_fields.count, 2);
            extra.append_all(zip64_fields);
        }
        _timestamp(extra);
        # A Unix `st_mode` in the high half, the MS-DOS directory bit low.
        ulong external = 0;
        if (is_directory) {
            external = ((16384 | mode) << 16) | 16;
        } else {
            external = (32768 | mode) << 16;
        }
        _zip_put(out, _ZIP_CENTRAL_HEADER, 4);
        _zip_put(out, _HEADER_MADE_BY, 2);
        _zip_put(out, _needed(), 2);
        _zip_put(out, flags, 2);
        _zip_put(out, _zip_method_code(method) as ulong, 2);
        _zip_put(out, time, 2);
        _zip_put(out, date, 2);
        _zip_put(out, crc32 as ulong, 4);
        _zip_put(out, _zip_min(compressed_size, _ZIP_MAX32), 4);
        _zip_put(out, _zip_min(size, _ZIP_MAX32), 4);
        _zip_put(out, name.count, 2);
        _zip_put(out, extra.count, 2);
        _zip_put(out, comment.count, 2);
        _zip_put(out, 0, 2);
        _zip_put(out, 0, 2);
        _zip_put(out, external, 4);
        _zip_put(out, _zip_min(offset, _ZIP_MAX32), 4);
        out.append_all(name);
        out.append_all(extra);
        out.append_all(comment);
        return out;
    }
}
