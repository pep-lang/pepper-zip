## `Entry` and `Method`: what the central directory says about each file in
## an archive, and the helpers the reader and writer share.

import io;
import os;
import text;

## How an entry's contents are stored.
export enum Method {
    ## Stored as they are, uncompressed (method 0).
    Stored,
    ## Compressed with DEFLATE (method 8), as nearly every zip tool writes.
    Deflate,
    ## Any other method, such as bzip2, LZMA or zstd: the entry is listed,
    ## but reading it is an error naming the method. `Entry.method_code`
    ## holds the number.
    Other,
}

## One entry of a zip archive: a file or directory, as the central
## directory describes it, without its contents.
##
## @example
##     import zip;
##
##     var entry = zip.Entry("bin/run.sh");
##     entry.mode = 493;   # octal 755: rwxr-xr-x
##     entry.method = zip.Method.Stored;
export struct Entry {
    ## The path in the archive, with `/` between components; a directory's
    ## ends with `/`.
    var name: String;
    ## Whether the entry is a directory.
    var is_directory: bool;
    ## Whether the entry is a Unix symbolic link, whose contents are the
    ## path it points to. Extracting skips it.
    var is_symlink: bool;
    ## The length of the contents in bytes, uncompressed.
    var size: ulong;
    ## The length of the stored contents in bytes, compressed.
    var compressed_size: ulong;
    ## The CRC-32 of the uncompressed contents.
    var crc32: uint;
    ## How the contents are stored.
    var method: Method;
    ## The method's number from the zip format: 0 stored, 8 DEFLATE, 12
    ## bzip2, 14 LZMA, 93 zstd, and so on.
    var method_code: uint;
    ## The modification time. Archives record it in local time to two
    ## seconds, with no time zone, unless they also carry the Unix extended
    ## timestamp, which this package reads and writes; without it the
    ## local time is taken as UTC.
    var modified: os.SystemTime;
    ## Whether the contents are encrypted (ZipCrypto or AES). Reading an
    ## encrypted entry is an error.
    var is_encrypted: bool;
    ## The entry's comment; usually empty.
    var comment: String;
    ## The Unix permission bits, such as 420 (octal 644, `rw-r--r--`); 0
    ## when the archive was not made on Unix.
    var mode: uint;
    # Where the entry's local header starts, and its general purpose flags.
    var _offset: ulong;
    var _flags: uint;

    ## Makes an entry with the given name and method, modified now, with
    ## mode 420 (octal 644) for a file and 493 (octal 755) for a directory
    ## (a name ending with `/`).
    ##
    ## @param name the path in the archive
    ## @param method how to store the contents
    construct(name: String = "", method: Method = Method.Deflate) {
        this.name = name;
        this.method = method;
        method_code = _zip_method_code(method);
        is_directory = name.ends_with("/");
        modified = os.SystemTime.now();
        comment = "";
        if (is_directory) {
            mode = 493;
        } else {
            mode = 420;
        }
    }
}

# Signatures of the records of a zip archive.
export const _ZIP_LOCAL_HEADER: ulong = 0x04034b50;
export const _ZIP_CENTRAL_HEADER: ulong = 0x02014b50;
export const _ZIP_END: ulong = 0x06054b50;
export const _ZIP64_END: ulong = 0x06064b50;
export const _ZIP64_LOCATOR: ulong = 0x07064b50;
export const _ZIP_DATA_DESCRIPTOR: ulong = 0x08074b50;
# The value a 32-bit field holds when the real one is in the ZIP64 extra
# field.
export const _ZIP_MAX32: ulong = 0xFFFFFFFF;
export const _ZIP_MAX16: ulong = 0xFFFF;

# The number of `method`.
export _zip_method_code(method: Method): uint {
    if (method == Method.Stored) {
        return 0;
    }
    return 8;
}

# The method of number `code`.
export _zip_method(code: uint): Method {
    if (code == 0) {
        return Method.Stored;
    }
    if (code == 8) {
        return Method.Deflate;
    }
    return Method.Other;
}

# The name of method number `code`, for messages.
export _zip_method_name(code: uint): String {
    if (code == 0) {
        return "stored";
    }
    if (code == 1) {
        return "shrink";
    }
    if (code == 6) {
        return "implode";
    }
    if (code == 8) {
        return "deflate";
    }
    if (code == 9) {
        return "deflate64";
    }
    if (code == 12) {
        return "bzip2";
    }
    if (code == 14) {
        return "LZMA";
    }
    if (code == 93) {
        return "zstd";
    }
    if (code == 95) {
        return "xz";
    }
    if (code == 98) {
        return "PPMd";
    }
    if (code == 99) {
        return "AES";
    }
    return "unknown";
}

# An error about the archive `archive`.
export _zip_error(archive: String, message: String): io.IoError {
    return io.IoError.invalid_input($"{archive}: {message}");
}

# An error about entry `entry` of the archive `archive`.
export _zip_entry_error(archive: String, entry: String, message: String): io.IoError {
    return io.IoError.invalid_input($"{archive}: entry '{entry}': {message}");
}

# The little-endian number of `size` bytes at `data[at]`.
export _zip_number(data: u8[], at: ulong, size: ulong): ulong {
    ulong value = 0;
    var index = size;
    while (index > 0) {
        index -= 1;
        value = (value << 8) | (data[at + index] as ulong);
    }
    return value;
}

# Appends `value` as a little-endian number of `size` bytes.
export _zip_put(out: u8[], value: ulong, size: ulong) {
    var left = value;
    ulong index = 0;
    while (index < size) {
        out.append((left & 255) as u8);
        left = left >> 8;
        index += 1;
    }
}

# The bytes `data[start..start + count]`.
export _zip_slice(data: u8[], start: ulong, count: ulong): u8[] {
    var out = Array<u8>(count);
    ulong index = 0;
    while (index < count) {
        out.append(data[start + index]);
        index += 1;
    }
    return out;
}

# A name or comment: UTF-8 when the entry's flag says so (`utf8`), and code
# page 437 otherwise, as the zip format specifies (ASCII is the same in
# both).
export _zip_decode_text(bytes: u8[], utf8: bool): String {
    if (utf8) {
        return text.Utf8.decode_lossy(bytes);
    }
    return text.CodePage437.decode(bytes);
}

# Days from 1970-01-01 to the given date (proleptic Gregorian).
export _zip_days_from_civil(year: long, month: long, day: long): long {
    var y = year;
    if (month <= 2) {
        y -= 1;
    }
    var era = y / 400;
    if (y < 0) {
        era = (y - 399) / 400;
    }
    var year_of_era = y - era * 400;
    var shifted = month - 3;
    if (month <= 2) {
        shifted = month + 9;
    }
    var day_of_year = (153 * shifted + 2) / 5 + day - 1;
    var day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

# The time of a DOS date and time, as UTC.
export _zip_from_dos(date: ulong, time: ulong): os.SystemTime {
    var year = ((date >> 9) & 127) as long + 1980;
    var month = ((date >> 5) & 15) as long;
    var day = (date & 31) as long;
    if (month < 1 || month > 12 || day < 1) {
        return os.SystemTime.from_unix_seconds(_zip_days_from_civil(1980, 1, 1) * 86400);
    }
    var hours = ((time >> 11) & 31) as long;
    var minutes = ((time >> 5) & 63) as long;
    var seconds = ((time & 31) * 2) as long;
    var days = _zip_days_from_civil(year, month, day);
    return os.SystemTime.from_unix_seconds(days * 86400 + hours * 3600 + minutes * 60 + seconds);
}

# The DOS date and time of `time`, as UTC, clamped to the years 1980
# through 2107 the format can hold.
export _zip_to_dos(time: os.SystemTime): (ulong, ulong) {
    var seconds = time.unix_seconds();
    var first = _zip_days_from_civil(1980, 1, 1) * 86400;
    var last = _zip_days_from_civil(2108, 1, 1) * 86400 - 2;
    if (seconds < first) {
        seconds = first;
    }
    if (seconds > last) {
        seconds = last;
    }
    var days = seconds / 86400;
    var rest = seconds - days * 86400;
    # The civil date of `days` (all after 1980, so no negative eras).
    var z = days + 719468;
    var era = z / 146097;
    var day_of_era = z - era * 146097;
    var year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
    var day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    var shifted = (5 * day_of_year + 2) / 153;
    var day = day_of_year - (153 * shifted + 2) / 5 + 1;
    var month = shifted + 3;
    if (shifted >= 10) {
        month = shifted - 9;
    }
    var year = year_of_era + era * 400;
    if (month <= 2) {
        year += 1;
    }
    var date = (((year - 1980) << 9) | (month << 5) | day) as ulong;
    var clock = (((rest / 3600) << 11) | (((rest / 60) % 60) << 5) | ((rest % 60) / 2)) as ulong;
    return (date, clock);
}
