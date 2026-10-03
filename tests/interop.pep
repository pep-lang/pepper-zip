# Writes an archive with every kind of entry this package writes, for
# tests/run.sh to check with Python's zipfile and Info-ZIP's unzip: more
# than 65,535 entries (ZIP64 end records), streamed entries (data
# descriptors, one with ZIP64 sizes), UTF-8 names and comments.
#
# Usage: interop out.zip

import io;
import zip;

main(args: String[]): int {
    var writer = zip.Writer.create(args[1]).value();
    var index = 0;
    while (index < 70000) {
        writer.add($"many/{index}", Array<u8>()).value();
        index += 1;
    }
    writer.add("deflated.txt", "zip zip zip zip zip zip zip zip".bytes()).value();
    writer.add("stored.txt", "stored".bytes(), zip.Method.Stored).value();
    writer.add_directory("ünïcode").value();
    writer.add("ünïcode/naïve.txt", "ü".bytes()).value();
    writer.add_stream(zip.Entry("streamed.txt"), io.ByteReader("streamed streamed streamed".bytes())).value();
    writer.add_stream(zip.Entry("streamed-stored.txt", zip.Method.Stored), io.ByteReader("plain".bytes())).value();
    # A size hint of 5 GB puts ZIP64 sizes in the local header.
    var hinted = zip.Entry("hinted.bin");
    hinted.size = 5000000000;
    writer.add_stream(hinted, io.ByteReader("hinted".bytes())).value();
    writer.comment = "written by pepper-zip";
    writer.finish().value();
    return 0;
}
