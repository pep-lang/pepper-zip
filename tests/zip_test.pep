# Tests of the zip package: archives it writes, read back in memory and
# from files, and archives other tools wrote (tests/data, made by
# tests/make_fixtures.py).
#
# Usage: zip_test path/to/tests/data

import io;
import os;
import zip;

# Fails the test with `message` when `condition` does not hold.
check(condition: bool, message: String) {
    if (!condition) {
        print($"FAILED: {message}");
        assert(false, message);
    }
}

# Checks that `result` failed with an invalid-input error whose message
# ends with `suffix`.
check_error<T>(result: io.IoResult<T>, suffix: String, label: String) {
    check(result.is_err(), $"{label}: expected an error");
    var error = result.error();
    check(error.is_invalid_input(), $"{label}: '{error.message}' is not invalid input");
    check(error.message.ends_with(suffix), $"{label}: '{error.message}' does not end with '{suffix}'");
}

# An archive written in memory, read back.
round_trip() {
    var out = io.ByteWriter();
    var writer = zip.Writer(out, "memory.zip");
    var text = "to be or not to be, that is the question; ".repeat(20).bytes();
    writer.add("deflated.txt", text).value();
    writer.add("stored.txt", "kept as is".bytes(), zip.Method.Stored).value();
    # Two bytes cannot shrink, so they are stored whatever the method.
    writer.add("tiny.txt", "ab".bytes()).value();
    writer.add_directory("docs").value();
    var entry = zip.Entry("docs/ünïcode.md");
    entry.modified = os.SystemTime.from_unix_seconds(951827696);  # 2000-02-29 12:34:56 UTC
    entry.mode = 384;
    entry.comment = "an entry comment";
    writer.add_entry(entry, "# Title\n".bytes()).value();
    writer.add_stream(zip.Entry("streamed.txt"), io.ByteReader(text)).value();
    writer.add_stream(zip.Entry("streamed-stored.txt", zip.Method.Stored), io.ByteReader("plain".bytes())).value();
    writer.comment = "made by zip_test";
    check_error(writer.add("tiny.txt", Array<u8>()), "entry 'tiny.txt': is already in the archive", "duplicate");
    check_error(writer.add("", Array<u8>()), "an entry needs a name", "empty name");
    writer.finish().value();
    writer.finish().value();

    var archive = zip.Archive.from_bytes(out.bytes, "memory.zip").value();
    check(archive.count == 7, "seven entries");
    check(archive.comment == "made by zip_test", "the archive comment");
    var names = Array<String>();
    for (var listed in archive.entries()) {
        names.append(listed.name);
    }
    check(names[0] == "deflated.txt" && names[3] == "docs/" && names[4] == "docs/ünïcode.md", "the order written");

    var deflated = archive.find("deflated.txt").value();
    check(deflated.method == zip.Method.Deflate && deflated.method_code == 8, "DEFLATE");
    check(deflated.size == text.count && deflated.compressed_size < text.count / 4, "compressed");
    check(archive.read(deflated).value() == text, "deflated contents");
    var stored = archive.find("stored.txt").value();
    check(stored.method == zip.Method.Stored && stored.compressed_size == stored.size, "stored");
    check(archive.read(stored).value() == "kept as is".bytes(), "stored contents");
    check(archive.find("tiny.txt").value().method == zip.Method.Stored, "incompressible data is stored");
    var directory = archive.find("docs/").value();
    check(directory.is_directory && directory.size == 0 && directory.mode == 493, "a directory");
    var unicode = archive.find("docs/ünïcode.md").value();
    check(unicode.modified.unix_seconds() == 951827696, "the time to the second");
    check(unicode.mode == 384 && unicode.comment == "an entry comment", "mode and comment");
    check(!unicode.is_directory && !unicode.is_encrypted && !unicode.is_symlink, "a plain file");
    check(archive.read(archive.find("streamed.txt").value()).value() == text, "a streamed entry");
    check(
        archive.read(archive.find("streamed-stored.txt").value()).value() == "plain".bytes(), "a streamed stored entry"
    );
    check(archive.find("missing").is_empty(), "find gives none");

    # Reading in pieces through the stream.
    var reader = archive.open_entry(deflated).value();
    check(reader.entry.name == "deflated.txt", "the reader's entry");
    var pieces = Array<u8>();
    while (true) {
        var read = reader.read(pieces, 7).value();
        if (read == 0) {
            break;
        }
        check(read <= 7, "at most max bytes");
    }
    check(pieces == text, "read in pieces");
    check(reader.read(pieces, 7).value() == 0, "still at the end");
}

# Files on disk: add_file, Archive.open and extract_all.
files(scratch: io.Path) {
    var source = scratch.join("source.txt");
    io.File.write_text(source, "from a file\n").value();
    var path = scratch.join("files.zip");
    var writer = zip.Writer.create(path).value();
    writer.add_file("top/nested/source.txt", source).value();
    writer.add("top/other.txt", "other".bytes()).value();
    writer.add_directory("top/empty").value();
    writer.finish().value();

    var archive = zip.Archive.open(path).value();
    var entry = archive.find("top/nested/source.txt").value();
    var modified = source.metadata().value().modified / 1000000000;
    check(entry.modified.unix_seconds() == modified, "add_file keeps the modification time");
    check(archive.read(entry).value() == "from a file\n".bytes(), "add_file contents");

    var target = scratch.join("out");
    archive.extract_all(target).value();
    check(
        io.File.read_to_string(target.join("top").join("nested").join("source.txt")).value() == "from a file\n",
        "extracted"
    );
    check(target.join("top").join("empty").is_directory(), "an empty directory");
    var stripped = scratch.join("stripped");
    archive.extract_all(stripped, strip_components = 1).value();
    check(io.File.read_to_string(stripped.join("other.txt")).value() == "other", "strip_components");
    archive.close().value();

    check(zip.Archive.open(scratch.join("missing.zip")).error().is_not_found(), "a missing file");
    check_error(
        zip.Archive.open(source), "source.txt: not a zip archive (no end of central directory record)", "not a zip"
    );
    var bytes = io.File.read_bytes(path).value();
    var cut = Array<u8>();
    var index = 0;
    while (index < bytes.count - 30) {
        cut.append(bytes[index]);
        index += 1;
    }
    check(zip.Archive.from_bytes(cut, "cut.zip").is_err(), "a truncated archive");
}

# More than 65,535 entries need the ZIP64 end records.
many_entries() {
    var out = io.ByteWriter();
    var writer = zip.Writer(out);
    var index = 0;
    while (index < 70000) {
        writer.add($"{index}", Array<u8>()).value();
        index += 1;
    }
    writer.finish().value();
    var archive = zip.Archive.from_bytes(out.bytes).value();
    check(archive.count == 70000, "70000 entries");
    check(archive.entries()[69999].name == "69999", "the last entry");
}

# Archives other tools wrote.
fixtures(data: io.Path, scratch: io.Path) {
    var methods = zip.Archive.open(data.join("methods.zip")).value();
    check(methods.count == 3, "every entry is listed");
    var plain = methods.find("plain.txt").value();
    check(methods.read(plain).value() == "plain".bytes(), "the stored entry reads");
    # 2024-05-06 07:08:10, from the DOS time alone.
    check(plain.modified.unix_seconds() == 1714979290, "the DOS time");
    var packed = methods.find("packed.txt").value();
    check(packed.method == zip.Method.Other && packed.method_code == 12, "bzip2 is another method");
    check_error(methods.read(packed), "entry 'packed.txt': compression method bzip2 (12) is not supported", "bzip2");
    check_error(
        methods.read(methods.find("lzma.txt").value()), "compression method LZMA (14) is not supported", "LZMA"
    );

    var names = zip.Archive.open(data.join("cp437.zip")).value();
    check(names.entries()[0].name == "café.txt", "a code page 437 name");
    check(names.entries()[1].name == "日本.txt", "an Info-ZIP Unicode path");
    check(names.read(names.entries()[1]).value() == "old".bytes(), "its contents");

    var crc = zip.Archive.open(data.join("crc.zip")).value();
    check_error(crc.read(crc.entries()[0]), "crc.zip: entry 'data.txt': CRC mismatch", "CRC");

    var encrypted = zip.Archive.open(data.join("encrypted.zip")).value();
    check(encrypted.entries()[0].is_encrypted, "the encrypted flag");
    check_error(
        encrypted.read(encrypted.entries()[0]),
        "entry 'secret.txt': is encrypted (ZipCrypto); encrypted entries are not supported",
        "ZipCrypto"
    );

    var slip = zip.Archive.open(data.join("slip.zip")).value();
    var target = scratch.join("slip");
    check_error(
        slip.extract_all(target),
        "entry '../evil.txt': unsafe path, which could write outside the target directory",
        "zip slip"
    );
    check(!target.join("ok.txt").exists(), "nothing is written");
    check(!scratch.join("evil.txt").exists(), "nothing escapes");

    for (var name in ["zip64.zip", "prefixed.zip"]) {
        var archive = zip.Archive.open(data.join(name)).value();
        var entry = archive.find("forced.txt").value();
        check(archive.read(entry).value() == "forced zip64 entry".bytes(), $"{name}: ZIP64 fields");
    }
}

main(args: String[]): int {
    if (args.count < 2) {
        print("usage: zip_test path/to/tests/data");
        return 2;
    }
    var scratch = io.Directory.temp().join($"pepper-zip-test-{os.SystemTime.now().unix_nanoseconds()}");
    io.Directory.create_all(scratch).value();
    round_trip();
    files(scratch);
    many_entries();
    fixtures(io.Path(args[1]), scratch);
    io.Directory.remove_all(scratch).value();
    print("zip tests passed");
    return 0;
}
